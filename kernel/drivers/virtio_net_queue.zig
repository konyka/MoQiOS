//! Virtio-net virtqueue accounting — pure, host-testable.
//!
//! The synchronous transmit path in virtio_net.zig mutates the TX
//! virtqueue's free list, available ring, and used-ring completion
//! counters. On SMP the driver may enter that path from multiple CPUs
//! concurrently (user task TX vs. writeback/timer TX), so the driver
//! serializes each TX transaction with an IrqSpinlock (see
//! virtio_net.zig). The queue *accounting* rules are kept here so the
//! driver's lock invariant can be exercised on the host without booting
//! a kernel or touching DMA memory.
//!
//! Contract (the single-flight ownership invariant):
//!   1. `allocDescriptor` hands out each descriptor at most once until
//!      it is returned by `freeDescriptor`.
//!   2. `publishAvail` writes exactly one ring slot and advances
//!      `avail_idx` exactly once per submission.
//!   3. `recordCompletion` advances `last_used_idx` exactly once per
//!      completed chain, freeing exactly the chain the device consumed.
//!   4. Every failing path leaves the queue state byte-for-byte
//!      unchanged (no partial mutation before success).

const std = @import("std");

/// Queue geometry constants shared with the driver.
pub const VQ_DESC_NEXT: u16 = 1;

/// Maximum descriptors in one virtqueue.
pub const MAX_QUEUE_SIZE: usize = 128;

/// Descriptor table entry tracked by the accounting layer. `next` is the
/// free-list/chain successor, `used` is true while the descriptor is
/// owned by the device or in use by a submitter.
pub const Desc = struct {
    next: u16 = 0,
    used: bool = false,
};

/// Queue accounting state. The driver owns the backing descriptor table
/// (DMA memory); this struct only carries the free list, ring indices and
/// the per-slot usage bits that make the single-flight invariant checkable.
pub const QueueState = struct {
    num: u16 = 0,
    free_head: u16 = 0,
    free_count: u16 = 0,
    avail_idx: u16 = 0,
    last_used_idx: u16 = 0,
    descs: [MAX_QUEUE_SIZE]Desc = [_]Desc{.{}} ** MAX_QUEUE_SIZE,
    // Mirrors of the available-ring slots (what the device will consume).
    avail_ring: [MAX_QUEUE_SIZE]u16 = [_]u16{0} ** MAX_QUEUE_SIZE,
    // Mirrors of the used-ring completions (device → driver).
    used_ring: [MAX_QUEUE_SIZE]u16 = [_]u16{0} ** MAX_QUEUE_SIZE,
};

/// Initialize an empty queue with `size` descriptors linked in a free list.
pub fn init(state: *QueueState, size: u16) void {
    state.num = size;
    state.free_head = 0;
    state.free_count = size;
    state.avail_idx = 0;
    state.last_used_idx = 0;
    for (0..size) |i| {
        state.descs[i] = .{
            .next = @intCast((i + 1) % size),
            .used = false,
        };
    }
    for (size..MAX_QUEUE_SIZE) |i| {
        state.descs[i] = .{ .next = 0, .used = true };
    }
    @memset(state.avail_ring[0..MAX_QUEUE_SIZE], 0);
    @memset(state.used_ring[0..MAX_QUEUE_SIZE], 0);
}

/// Allocate the head of the free list, or null when the queue is full.
/// On success the descriptor is marked in use.
pub fn allocDescriptor(state: *QueueState) ?u16 {
    if (state.free_count == 0) return null;
    const idx = state.free_head;
    state.descs[idx].used = true;
    state.free_head = state.descs[idx].next;
    state.free_count -= 1;
    return idx;
}

/// Return a descriptor to the free list. The caller guarantees it was
/// previously handed out by `allocDescriptor` and is no longer owned by
/// the device. Returns false (and mutates nothing) if `idx` is already free
/// or out of range — double-free protection is part of the single-flight
/// contract, because a duplicated reclaim under a lost-lock race would
/// re-add the same descriptor twice and corrupt the free list.
pub fn freeDescriptor(state: *QueueState, idx: u16) bool {
    if (idx >= state.num) return false;
    if (!state.descs[idx].used) return false;
    state.descs[idx].used = false;
    state.descs[idx].next = state.free_head;
    state.free_head = idx;
    state.free_count += 1;
    return true;
}

/// Publish one submission: write `head` into the available ring at the
/// current `avail_idx` and advance the index by exactly one.
pub fn publishAvail(state: *QueueState, head: u16) void {
    if (state.num == 0 or head >= state.num) return;
    const slot = state.avail_idx % state.num;
    state.avail_ring[slot] = head;
    state.avail_idx +%= 1;
}

/// Record one completed chain from the used ring: advance `last_used_idx`
/// by exactly one and return the chain head descriptor id that the device
/// consumed (so the caller can reclaim buffers). `used_ring_idx` is the
/// caller-tracked used-ring slot to read; wrap-safe via modulo `num`.
pub fn recordCompletion(state: *QueueState, used_ring_idx: u16) u16 {
    if (state.num == 0) return 0;
    const head = state.used_ring[used_ring_idx % state.num];
    state.last_used_idx +%= 1;
    return head;
}

/// Recycle one RX descriptor: consume one used entry, then republish the
/// same descriptor head back to the available ring exactly once.
pub fn recycleRx(state: *QueueState, used_ring_idx: u16) void {
    if (state.num == 0) return;
    const head = recordCompletion(state, used_ring_idx);
    publishAvail(state, head);
}

/// Snapshot equality helper for rollback assertions.
pub fn eql(a: *const QueueState, b: *const QueueState) bool {
    if (a.num != b.num or a.free_head != b.free_head or a.free_count != b.free_count or
        a.avail_idx != b.avail_idx or a.last_used_idx != b.last_used_idx)
    {
        return false;
    }
    for (0..MAX_QUEUE_SIZE) |i| {
        if (a.descs[i].next != b.descs[i].next or a.descs[i].used != b.descs[i].used) return false;
    }
    for (0..MAX_QUEUE_SIZE) |i| {
        if (a.avail_ring[i] != b.avail_ring[i] or a.used_ring[i] != b.used_ring[i]) return false;
    }
    return true;
}

// Host tests live here so the module is self-contained under `zig build test`.
test "virtio-net queue: alloc-until-full hands out unique descriptors" {
    var q: QueueState = .{};
    init(&q, 8);
    var seen = [_]bool{false} ** MAX_QUEUE_SIZE;
    var allocated: usize = 0;
    while (allocated < 8) : (allocated += 1) {
        const idx = allocDescriptor(&q) orelse unreachable;
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
    try std.testing.expectEqual(@as(u16, 0), q.free_count);
    try std.testing.expect(allocDescriptor(&q) == null);
}

test "virtio-net queue: free restores capacity and reuses the head" {
    var q: QueueState = .{};
    init(&q, 8);
    const a = allocDescriptor(&q).?;
    const b = allocDescriptor(&q).?;
    freeDescriptor(&q, a);
    try std.testing.expectEqual(@as(u16, 7), q.free_count);
    try std.testing.expect(allocDescriptor(&q) == a);
    _ = b;
}

test "virtio-net queue: free of an already-free descriptor is a no-op" {
    var q: QueueState = .{};
    init(&q, 8);
    const snap = q;
    // A free descriptor (0) that was never handed out: the reclaim must not
    // mutate the free list (double-free protection).
    try std.testing.expect(!freeDescriptor(&q, 0));
    try std.testing.expectEqual(@as(u16, 8), q.free_count);
    try std.testing.expect(eql(&snap, &q));
    // Out-of-range index is likewise a no-op.
    try std.testing.expect(!freeDescriptor(&q, 8));
    try std.testing.expect(!freeDescriptor(&q, 255));
    try std.testing.expectEqual(@as(u16, 8), q.free_count);
    try std.testing.expect(eql(&snap, &q));
}

test "virtio-net queue: zero-size queue never allocates and bounds-safe" {
    var q: QueueState = .{};
    init(&q, 0);
    try std.testing.expect(allocDescriptor(&q) == null);
    // publish/record on a zero-size queue must not divide by zero; the
    // driver never drives a zero-size queue, but the pure model stays safe.
    publishAvail(&q, 3);
    try std.testing.expect(!freeDescriptor(&q, 0));
    _ = recordCompletion(&q, 0);
    try std.testing.expectEqual(@as(u16, 0), q.avail_idx);
}

test "virtio-net queue: publishAvail writes one slot and advances once" {
    var q: QueueState = .{};
    init(&q, 8);
    const before = q.avail_idx;
    publishAvail(&q, 3);
    try std.testing.expectEqual(before +% 1, q.avail_idx);
    try std.testing.expectEqual(@as(u16, 3), q.avail_ring[before % 8]);
}

test "virtio-net queue: recordCompletion advances exactly once" {
    var q: QueueState = .{};
    init(&q, 8);
    q.used_ring[0] = 5;
    const before = q.last_used_idx;
    const head = recordCompletion(&q, 0);
    try std.testing.expectEqual(before +% 1, q.last_used_idx);
    try std.testing.expectEqual(@as(u16, 5), head);
}

test "virtio-net queue: second-descriptor allocation failure rolls back" {
    var q: QueueState = .{};
    init(&q, 8);
    const snap = q;
    const first = allocDescriptor(&q).?; // first desc claimed
    try std.testing.expect(!eql(&snap, &q));
    // Simulate a failure after the first descriptor was taken: return it,
    // and the state must be byte-for-byte identical to the snapshot.
    try std.testing.expect(freeDescriptor(&q, first));
    try std.testing.expect(eql(&snap, &q));
}

test "virtio-net queue: RX recycle consumes once and republishes once" {
    var q: QueueState = .{};
    init(&q, 8);
    q.used_ring[0] = 2;
    const avail_before = q.avail_idx;
    recycleRx(&q, 0);
    try std.testing.expectEqual(avail_before +% 1, q.avail_idx);
    try std.testing.expectEqual(@as(u16, 2), q.avail_ring[avail_before % 8]);
}
