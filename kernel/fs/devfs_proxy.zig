/// devfs proxy — userspace-owned /dev nodes.
///
/// A CAP_SYS_RAWIO task registers a device name via syscall 484
/// (devfs_register) and gets back a control fd. The kernel creates a
/// devfs node whose read/write ops forward to the owner over that fd:
///
///   client read/write on /dev/<name>
///     → enqueue Request{seq, op, offset, len[, payload]} on the node
///     → block on the node-private client wait queue
///   owner read(ctrl_fd)
///     → dequeue the oldest queued request as wire bytes (blocks when
///       the queue is empty, EINTR protocol)
///   owner write(ctrl_fd, Response{seq, ret[, data]})
///     → complete the matching in-flight request, wake the client
///
/// Wire layout (all integers little-endian):
///   Request  (read from ctrl_fd): u32 seq @0, u32 op @4 (1=read,
///             2=write), u64 offset @8, u32 len @16, u8 payload[len] @20
///             (write requests only; reads stop at offset 20).
///   Response (written to ctrl_fd): u32 seq @0, i32 ret @4, u8 data[ret]
///             @8 (read responses with ret > 0 only; write responses and
///             error responses are exactly 8 bytes, ret = byte count or
///             negative errno).
///
/// Owner death (ctrl_fd close or task exit, see cleanupTask wired into
/// the task reap path next to userdrv.cleanupTask): all queued/in-flight
/// requests complete with -EIO, the devfs node is tombstoned
/// (devfs.unregister) so new opens of the name get ENOENT, and client ops
/// on already-open fds get -EIO.
///
/// v1.1 semantics (documented in docs/kernel-subsystems.md §3.9):
///   - poll on proxy nodes reports EPOLLIN|EPOLLOUT only while a new
///     request can be enqueued without blocking (owner alive + a free
///     slot); a dead owner always reports both (ops fail fast with -EIO).
///   - O_NONBLOCK gates enqueue acceptance only: a saturated queue fails
///     with -EAGAIN instead of blocking the client. The round-trip wait
///     itself stays blocking either way (this kernel's pipes likewise
///     never block mid-operation — see vfs.pipeRead/pipeWrite).
///   - Tombstoned devfs slots and drained proxy slots are reused
///     (oldest-first). Reuse fully resets the slot (request queue, wait
///     queues, owner) and is guarded by the devfs slot generation, so
///     stale fds keep failing with -EIO instead of retargeting the new
///     node. pread/pwrite stay rejected via no_pread.
///
/// Pure core (Core, wire codec, limits) has no kernel imports and is
/// host-tested via tests/main.zig ("devfs proxy (P1)" block); the glue
/// below it follows the kmsg blocking protocol (kernel/klog.zig J3).
///
/// Lock order: alloc_lock (register/unregister serialization) →
/// node.lock → task/runqueue locks (via sched.wakeOne/wakeAll under
/// node.lock, same nesting as klog's ring_lock). node.lock is never held
/// across forceReschedule; check+enqueue and check+block happen in a
/// single node.lock critical section so a completion can never slip
/// between a waiter's check and its enqueue (no lost wakeup).

const builtin = @import("builtin");
const devfs = @import("devfs.zig");
const errno = @import("../lib/errno.zig");

const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const task_mod = @import("../proc/task.zig");


pub const SYS_DEVFS_REGISTER: u64 = 484;

/// Userspace-owned node limit (simultaneous — drained slots are reused,
/// see the file header).
pub const MAX_USER_NODES: u32 = 8;
/// Concurrently outstanding client requests per node.
pub const MAX_PENDING: u32 = 4;
/// Maximum write payload / read-response size per request.
pub const MAX_PAYLOAD: u32 = 4096;
/// Request wire header: seq(4) + op(4) + offset(8) + len(4).
pub const REQ_WIRE_LEN: usize = 20;
/// Response wire header: seq(4) + ret(4).
pub const RSP_WIRE_LEN: usize = 8;

pub const OP_READ: u32 = 1;
pub const OP_WRITE: u32 = 2;

// ---------------------------------------------------------------------------
// Pure core — request queue + wire codec (host-tested, no kernel imports)
// ---------------------------------------------------------------------------

const ReqState = enum(u8) { free, queued, inflight, done };

const Request = struct {
    state: ReqState = .free,
    seq: u32 = 0,
    op: u32 = 0,
    offset: u64 = 0,
    len: u32 = 0,
    /// Client returned -EINTR while the owner holds the request: the late
    /// response is accepted (the owner must not get spurious EINVAL) and
    /// the slot freed instead of completing.
    cancelled: bool = false,
    ret: i32 = 0,
    /// Write payload (queued) or staged read-response data (done).
    data: [MAX_PAYLOAD]u8 = @splat(0),
};

/// View of a completed request handed to the waiting client.
pub const DoneView = struct {
    ret: i32,
    data: []const u8,
};

/// Parsed owner response (write to ctrl_fd).
pub const Response = struct {
    seq: u32,
    ret: i32,
    data: []const u8,
};

/// Per-node request queue. All methods must be called under the owning
/// node's lock (the glue's IrqSpinlock); the core itself is lock-free.
pub const Core = struct {
    owner_alive: bool = true,
    next_seq: u32 = 1,
    reqs: [MAX_PENDING]Request = @splat(.{}),

    /// Queue a client request. `len` is the client's byte count (bytes
    /// wanted for reads, payload length for writes); `payload` is the
    /// write data and must be empty for reads. Returns the assigned seq,
    /// or null on bad shape, full queue, or dead owner.
    pub fn enqueue(self: *Core, op: u32, offset: u64, len: u32, payload: []const u8) ?u32 {
        if (!self.owner_alive) return null;
        if (op != OP_READ and op != OP_WRITE) return null;
        if (len > MAX_PAYLOAD) return null;
        if (op == OP_WRITE and payload.len != len) return null;
        if (op == OP_READ and payload.len != 0) return null;
        for (&self.reqs) |*r| {
            if (r.state != .free) continue;
            r.* = .{
                .state = .queued,
                .seq = self.next_seq,
                .op = op,
                .offset = offset,
                .len = len,
            };
            @memcpy(r.data[0..payload.len], payload);
            self.next_seq +%= 1;
            if (self.next_seq == 0) self.next_seq = 1;
            return r.seq;
        }
        return null;
    }

    fn oldestQueued(self: *Core) ?*Request {
        var best: ?*Request = null;
        for (&self.reqs) |*r| {
            if (r.state != .queued) continue;
            if (best == null or r.seq < best.?.seq) best = r;
        }
        return best;
    }

    /// Wire size of the oldest queued request, or null when the queue is
    /// empty. The owner needs this to size its read buffer.
    pub fn queuedWireLen(self: *Core) ?usize {
        const r = self.oldestQueued() orelse return null;
        return REQ_WIRE_LEN + if (r.op == OP_WRITE) @as(usize, r.len) else 0;
    }

    /// Serialize the oldest queued request into `out` and mark it
    /// in-flight (handed to the owner). Returns the wire length, or null
    /// when the queue is empty or `out` is too small.
    pub fn takeRequest(self: *Core, out: []u8) ?usize {
        const r = self.oldestQueued() orelse return null;
        const need = REQ_WIRE_LEN + if (r.op == OP_WRITE) @as(usize, r.len) else 0;
        if (out.len < need) return null;
        writeU32Le(out[0..4], r.seq);
        writeU32Le(out[4..8], r.op);
        writeU64Le(out[8..16], r.offset);
        writeU32Le(out[16..20], r.len);
        if (r.op == OP_WRITE) @memcpy(out[20..need], r.data[0..r.len]);
        r.state = .inflight;
        return need;
    }

    fn findInflight(self: *Core, seq: u32) ?*Request {
        for (&self.reqs) |*r| {
            if (r.state == .inflight and r.seq == seq) return r;
        }
        return null;
    }

    /// Complete an in-flight request with the owner's response. Read
    /// responses with ret > 0 must carry exactly ret data bytes (≤ the
    /// requested len); write responses carry no data and ret is the byte
    /// count (≤ the requested len); ret < 0 is an errno. Returns false
    /// for unknown/out-of-state seqs and malformed responses.
    pub fn complete(self: *Core, seq: u32, ret: i32, data: []const u8) bool {
        const r = self.findInflight(seq) orelse return false;
        if (ret > 0) {
            if (ret > r.len) return false;
            if (r.op == OP_READ and data.len != ret) return false;
            if (r.op == OP_WRITE and data.len != 0) return false;
        } else {
            if (data.len != 0) return false;
        }
        if (r.cancelled) {
            r.* = .{}; // client already gone (-EINTR): drop the late answer
            return true;
        }
        if (data.len != 0) @memcpy(r.data[0..data.len], data);
        r.ret = ret;
        r.state = .done;
        return true;
    }

    /// Client-side completion check: the finished request's result, or
    /// null while it is still queued/in-flight (or unknown). Staged data
    /// is reported for read completions only — a write completion's ret
    /// is a byte count, not a payload.
    pub fn pollDone(self: *Core, seq: u32) ?DoneView {
        for (&self.reqs) |*r| {
            if (r.state == .done and r.seq == seq) {
                const dlen: usize = if (r.ret > 0 and r.op == OP_READ) @intCast(r.ret) else 0;
                return .{ .ret = r.ret, .data = r.data[0..dlen] };
            }
        }
        return null;
    }

    /// Free a completed request's slot after the client picked the
    /// result up.
    pub fn collect(self: *Core, seq: u32) void {
        for (&self.reqs) |*r| {
            if (r.state == .done and r.seq == seq) {
                r.* = .{};
                return;
            }
        }
    }

    /// Client gave up (-EINTR): queued requests are freed before the
    /// owner ever sees them; in-flight ones are marked so the late
    /// response frees the slot instead of completing.
    pub fn cancel(self: *Core, seq: u32) void {
        for (&self.reqs) |*r| {
            if (r.seq != seq) continue;
            switch (r.state) {
                .queued => r.* = .{},
                .inflight => r.cancelled = true,
                else => {},
            }
            return;
        }
    }

    /// True while a new client request can be enqueued without waiting:
    /// the owner is alive and at least one request slot is free. Slots
    /// are freed by collect/cancel only — handing a request to the owner
    /// (queued → inflight) does not free one.
    pub fn canAccept(self: *const Core) bool {
        if (!self.owner_alive) return false;
        for (&self.reqs) |*r| {
            if (r.state == .free) return true;
        }
        return false;
    }

    /// Poll readiness mask (devfs.POLL_IN/POLL_OUT values). Proxy reads
    /// and writes are synchronous round-trips, so classic "data ready /
    /// buffer space" readiness does not exist; the honest v1.1 semantics
    /// (documented in docs/kernel-subsystems.md §3.9):
    ///   - owner dead → POLL_IN|POLL_OUT always. Client ops fail fast
    ///     with -EIO, so the fd must never be reported not-ready (a
    ///     poller would sleep forever on a dead node).
    ///   - owner alive → POLL_IN|POLL_OUT only while canAccept(): a new
    ///     request would be enqueued without blocking. A saturated queue
    ///     reports not-ready in both directions.
    pub fn pollMask(self: *const Core) u32 {
        if (!self.owner_alive) return devfs.POLL_IN | devfs.POLL_OUT;
        if (self.canAccept()) return devfs.POLL_IN | devfs.POLL_OUT;
        return 0;
    }

    /// Owner death: fail every outstanding request with -EIO and seal the
    /// queue (enqueue starts failing). Returns the number completed so
    /// the glue knows whether anyone needs waking. Idempotent.
    pub fn drain(self: *Core) u32 {
        var n: u32 = 0;
        self.owner_alive = false;
        for (&self.reqs) |*r| {
            switch (r.state) {
                .queued, .inflight => {
                    if (r.cancelled) {
                        r.* = .{};
                    } else {
                        r.ret = -5; // -EIO
                        r.state = .done;
                        n += 1;
                    }
                },
                else => {},
            }
        }
        return n;
    }
};

/// Parse an owner response written to a ctrl fd: u32 seq LE @0, i32 ret
/// LE @4, then any data bytes. The parser is op-agnostic: read responses
/// with ret > 0 carry exactly ret data bytes, write responses carry a
/// byte count in ret and NO data — telling those apart needs the
/// request, so the per-op data-length rule lives in Core.complete. Here
/// ret > 0 only caps at MAX_PAYLOAD and reports whatever bytes followed
/// the header; ret <= 0 responses must be exactly the 8-byte header.
/// Returns null on malformed input.
pub fn parseResponse(buf: []const u8) ?Response {
    if (buf.len < RSP_WIRE_LEN) return null;
    const seq = readU32Le(buf[0..4]);
    const ret: i32 = @bitCast(readU32Le(buf[4..8]));
    if (ret > 0) {
        if (ret > MAX_PAYLOAD) return null;
        return .{ .seq = seq, .ret = ret, .data = buf[RSP_WIRE_LEN..] };
    }
    if (buf.len != RSP_WIRE_LEN) return null;
    return .{ .seq = seq, .ret = ret, .data = &.{} };
}

fn writeU32Le(out: []u8, v: u32) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
    out[2] = @truncate(v >> 16);
    out[3] = @truncate(v >> 24);
}

fn writeU64Le(out: []u8, v: u64) void {
    for (0..8) |i| out[i] = @truncate(v >> @intCast(i * 8));
}

fn readU32Le(in: []const u8) u32 {
    return @as(u32, in[0]) |
        (@as(u32, in[1]) << 8) |
        (@as(u32, in[2]) << 16) |
        (@as(u32, in[3]) << 24);
}

// ---------------------------------------------------------------------------
// Kernel glue — proxy node table, node ops, ctrl fd, syscall 484
// ---------------------------------------------------------------------------

const ProxyNode = struct {
    /// Ever allocated. A used slot whose owner died (core.owner_alive ==
    /// false) is recyclable: reuse fully resets the slot so no stale
    /// request or waiter can cross into the new node.
    used: bool = false,
    devfs_idx: u32 = 0,
    owner_task_idx: u32 = 0,
    /// devfs slot generation of the current registration (captured from
    /// devfs.generationAt at register time). Client fds carry it in
    /// IoCtx.generation (seeded by the vfs at open), ctrl fds in
    /// FileDescriptor.devfs_generation; both op paths reject a mismatch
    /// with -EIO so stale fds of a recycled slot fail cleanly.
    generation: u32 = 0,
    lock: IrqSpinlock = .{},
    core: Core = .{},
    /// Blocked client tasks (one per outstanding request at most).
    client_wq: ?*task_mod.WaitNode = null,
    /// Blocked owner ctrl_fd readers.
    owner_wq: ?*task_mod.WaitNode = null,
    /// Blocking clients waiting for a free request slot (O_NONBLOCK
    /// clients get -EAGAIN instead, matching pipe semantics).
    space_wq: ?*task_mod.WaitNode = null,
};

var nodes: [MAX_USER_NODES]ProxyNode = @splat(.{});
/// Serializes devfs.register/unregister from syscall context (the devfs
/// table itself is lock-free and append-only).
var alloc_lock: IrqSpinlock = .{};

fn ProxyOps(comptime i: usize) type {
    return struct {
        fn readOp(ctx: *devfs.IoCtx, buf: [*]u8, count: usize) i64 {
            return clientRoundTrip(i, OP_READ, ctx, @ptrCast(buf), count);
        }
        fn writeOp(ctx: *devfs.IoCtx, buf: [*]const u8, count: usize) i64 {
            // @constCast: the write round-trip only ever reads the payload.
            return clientRoundTrip(i, OP_WRITE, ctx, @constCast(buf), count);
        }
        fn pollOp(ctx: *const devfs.IoCtx) u32 {
            _ = ctx;
            // Real v1.1 readiness (Core.pollMask): ready while a new
            // request can be enqueued without blocking; always ready once
            // the owner is dead (ops fail fast with -EIO). Deliberately
            // no generation check: a stale fd on a recycled slot sees the
            // new node's saturation state, and its ops still fail on the
            // generation mismatch in clientRoundTrip.
            const node = &nodes[i];
            const flags = node.lock.acquire();
            defer node.lock.release(flags);
            return node.core.pollMask();
        }
    };
}

fn nodeOps(comptime i: usize) devfs.NodeOps {
    return .{
        .read = ProxyOps(i).readOp,
        .write = ProxyOps(i).writeOp,
        .poll = ProxyOps(i).pollOp,
        // Clients always block; the vfs pread path forcing O_NONBLOCK
        // would silently change semantics, so reject explicit offsets.
        .flags = .{ .no_pread = true },
    };
}

fn opsFor(i: usize) devfs.NodeOps {
    return switch (i) {
        0 => nodeOps(0),
        1 => nodeOps(1),
        2 => nodeOps(2),
        3 => nodeOps(3),
        4 => nodeOps(4),
        5 => nodeOps(5),
        6 => nodeOps(6),
        7 => nodeOps(7),
        else => unreachable,
    };
}

/// Remove `wn` from `queue` if it is still linked (a granted wakeOne
/// already popped it; a signal kick unblocks the task without touching
/// the queue). Mirrors klog.kmsgUnlinkWaiter.
fn unlinkWaiter(queue: *?*task_mod.WaitNode, wn: *task_mod.WaitNode, lock: *IrqSpinlock) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    var prev: ?*task_mod.WaitNode = null;
    var cur = queue.*;
    while (cur) |n| {
        if (n == wn) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                queue.* = n.next;
            }
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

/// Signal protocol shared by client and owner waits (kmsg/waitpid
/// pattern): die on a fatal signal, report -EINTR on an actionable one.
/// Returns null when the wait may continue.
fn checkSignals() ?i64 {
    const sched = @import("../proc/sched.zig");
    const sig_mod = @import("../proc/signal.zig");
    const cur_idx = sched.currentTaskIndex() orelse return errno.EIO;
    const cur = task_mod.getTask(cur_idx) orelse return errno.EIO;
    if (sig_mod.pendingFatal(cur)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
    if (sig_mod.pendingActionable(cur)) return errno.EINTR;
    return null;
}

/// Client-side node op: enqueue a request, wake the owner, block until
/// the matching response arrives (or the owner dies → -EIO, or a signal
/// arrives → -EINTR and the request is cancelled). Runs in the client's
/// syscall context holding NO vfs/devfs lock — only node.lock in short
/// critical sections.
///
/// O_NONBLOCK gates ENQUEUE ACCEPTANCE ONLY (pipe-style, see vfs
/// pipeRead/pipeWrite which never block either): a saturated request
/// queue fails a nonblocking client with -EAGAIN, while a blocking
/// client sleeps on space_wq until a slot frees. Once enqueued, the
/// round-trip wait blocks either way — a half-delivered request must not
/// be abandoned silently.
fn clientRoundTrip(comptime i: usize, comptime op: u32, ctx: *devfs.IoCtx, buf: [*]u8, count: usize) i64 {
    const sched = @import("../proc/sched.zig");
    if (count == 0) return 0;
    const node = &nodes[i];
    const len: u32 = @intCast(@min(count, MAX_PAYLOAD));

    var seq: u32 = undefined;
    var gen: u32 = undefined;
    while (true) {
        var wn: task_mod.WaitNode = .{ .task_idx = 0 };
        {
            const flags = node.lock.acquire();
            // Stale fd on a recycled slot: never retarget the new node.
            if (ctx.generation != node.generation or !node.core.owner_alive) {
                node.lock.release(flags);
                return errno.EIO;
            }
            if (node.core.enqueue(op, ctx.offset, len, if (op == OP_WRITE) buf[0..len] else &.{})) |s| {
                seq = s;
                gen = node.generation;
                _ = sched.wakeOne(&node.owner_wq);
                node.lock.release(flags);
                break;
            }
            // Queue saturated: nonblocking clients fail immediately...
            if (ctx.nonBlocking()) {
                node.lock.release(flags);
                return errno.EAGAIN; // -11
            }
            // ...blocking clients wait for a slot to free (collect /
            // cancel / drain wake space_wq). Check + block in the same
            // critical section so no wakeup is lost.
            if (!sched.blockOn(&node.space_wq, &wn)) {
                node.lock.release(flags);
                return errno.EIO; // no current task (should not happen)
            }
            node.lock.release(flags);
        }
        sched.forceReschedule();
        unlinkWaiter(&node.space_wq, &wn, &node.lock);
        if (checkSignals()) |rc| return rc; // nothing enqueued yet
    }

    while (true) {
        var wn: task_mod.WaitNode = .{ .task_idx = 0 };
        {
            const flags = node.lock.acquire();
            // Check + block in one critical section: complete() wakes
            // under the same lock, so no response can be lost.
            if (node.generation != gen) {
                // Slot recycled while we waited (owner died, node
                // re-registered): the request is gone — fail cleanly.
                node.lock.release(flags);
                return errno.EIO;
            }
            if (node.core.pollDone(seq)) |res| {
                const out: i64 = res.ret;
                if (res.ret > 0 and op == OP_READ) @memcpy(buf[0..@intCast(res.ret)], res.data);
                node.core.collect(seq);
                // A freed slot may unblock a client waiting for space.
                _ = sched.wakeOne(&node.space_wq);
                node.lock.release(flags);
                return out;
            }
            if (!sched.blockOn(&node.client_wq, &wn)) {
                node.lock.release(flags);
                return errno.EIO; // no current task (should not happen)
            }
            node.lock.release(flags);
        }
        sched.forceReschedule();
        unlinkWaiter(&node.client_wq, &wn, &node.lock);
        if (checkSignals()) |rc| {
            const flags = node.lock.acquire();
            node.core.cancel(seq);
            // Cancelling a queued request frees its slot immediately.
            _ = sched.wakeOne(&node.space_wq);
            node.lock.release(flags);
            return rc;
        }
    }
}

/// vfs read on a ctrl fd: dequeue the next request as wire bytes. Blocks
/// while the queue is empty (EINTR protocol); -EIO once the owner is
/// dead; -EINVAL when the buffer cannot hold the oldest request.
/// `generation` is the fd's cached slot generation: after a slot recycle
/// a stale ctrl fd fails with -EIO instead of serving the new node.
pub fn ctrlRead(idx: u32, generation: u32, buf: [*]u8, count: usize) i64 {
    const sched = @import("../proc/sched.zig");
    if (idx >= MAX_USER_NODES) return errno.EBADF;
    const node = &nodes[idx];

    while (true) {
        var wn: task_mod.WaitNode = .{ .task_idx = 0 };
        {
            const flags = node.lock.acquire();
            if (generation != node.generation or !node.core.owner_alive) {
                node.lock.release(flags);
                return errno.EIO;
            }
            if (node.core.queuedWireLen()) |need| {
                if (count < need) {
                    node.lock.release(flags);
                    return errno.EINVAL;
                }
                const n = node.core.takeRequest(buf[0..count]).?;
                node.lock.release(flags);
                return @intCast(n);
            }
            if (!sched.blockOn(&node.owner_wq, &wn)) {
                node.lock.release(flags);
                return errno.EIO;
            }
            node.lock.release(flags);
        }
        sched.forceReschedule();
        unlinkWaiter(&node.owner_wq, &wn, &node.lock);
        if (checkSignals()) |rc| return rc;
    }
}

/// epoll support: true while a ctrl fd has a queued request to dequeue.
pub fn ctrlHasQueued(idx: u32) bool {
    if (idx >= MAX_USER_NODES) return false;
    const node = &nodes[idx];
    const flags = node.lock.acquire();
    defer node.lock.release(flags);
    return node.core.queuedWireLen() != null;
}

/// vfs write on a ctrl fd: complete the request matching the response's
/// seq and wake the blocked client. Unknown seq / malformed response is
/// -EINVAL; a stale fd (generation mismatch after a slot recycle) is -EIO.
pub fn ctrlWrite(idx: u32, generation: u32, buf: [*]const u8, count: usize) i64 {
    const sched = @import("../proc/sched.zig");
    if (idx >= MAX_USER_NODES) return errno.EBADF;
    const node = &nodes[idx];
    const rsp = parseResponse(buf[0..count]) orelse return errno.EINVAL;

    const flags = node.lock.acquire();
    defer node.lock.release(flags);
    if (generation != node.generation) return errno.EIO;
    if (!node.core.complete(rsp.seq, rsp.ret, rsp.data)) return errno.EINVAL;
    _ = sched.wakeOne(&node.client_wq);
    // Completing a cancelled in-flight request frees its slot.
    _ = sched.wakeOne(&node.space_wq);
    return @intCast(count);
}

/// Owner-death teardown (ctrl_fd close, or task reap via cleanupTask):
/// fail all outstanding requests with -EIO, wake everyone, tombstone the
/// devfs node. Idempotent.
pub fn ctrlClose(idx: u32) void {
    const sched = @import("../proc/sched.zig");
    if (idx >= MAX_USER_NODES) return;
    const node = &nodes[idx];
    var devfs_idx: u32 = devfs.DIR_IDX;
    {
        const flags = node.lock.acquire();
        defer node.lock.release(flags);
        if (!node.core.owner_alive) return;
        _ = node.core.drain();
        sched.wakeAll(&node.client_wq);
        sched.wakeAll(&node.owner_wq);
        sched.wakeAll(&node.space_wq);
        devfs_idx = node.devfs_idx;
    }
    // Outside node.lock: tombstone the node (lookup/getdents stop
    // resolving the name, new opens get ENOENT) and bump the change
    // counter, which wakes /dev/devfs-watch readers via the hook.
    if (devfs_idx != devfs.DIR_IDX) _ = devfs.unregister(devfs_idx);
}

/// Reap-path backstop (wired next to userdrv.cleanupTask): release every
/// proxy node owned by `t`. The common path is exitTask closing the ctrl
/// fd (vfs close → ctrlClose); this covers anything that outlives it.
pub fn cleanupTask(t: *task_mod.Task) void {
    for (&nodes, 0..) |*node, i| {
        if (!node.used) continue;
        if (node.owner_task_idx != t.self_idx) continue;
        ctrlClose(@intCast(i));
    }
}

/// Syscall #484: devfs_register(name_ptr, flags) → ctrl fd or -errno.
/// Creates a userspace-owned devfs node and returns the control fd that
/// serves it. Requires CAP_SYS_RAWIO; flags must be 0 (reserved).
pub fn syscallDevfsRegister(name_ptr: u64, flags: u64) i64 {
    // Only wired into the x86_64 syscall table today (hello54 runs on
    // x86); keep non-x86 builds compiling with an explicit stub.
    if (comptime builtin.cpu.arch != .x86_64) return errno.ENOSYS;

    const sched = @import("../proc/sched.zig");
    const cap_check = @import("../proc/cap_check.zig");
    const copy = @import("../mm/copy_from_user.zig");

    const cur_idx = sched.currentTaskIndex() orelse return errno.ESRCH;
    const cur = task_mod.getTask(cur_idx) orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;
    if (flags != 0) return errno.EINVAL;
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return errno.EFAULT;

    // Copy the NUL-terminated name (≤ MAX_NAME_LEN chars).
    var name_buf: [devfs.MAX_NAME_LEN + 1]u8 = @splat(0);
    const got = copy.copyFromUser(&name_buf, @ptrFromInt(name_ptr), devfs.MAX_NAME_LEN + 1);
    var name_len: usize = 0;
    while (name_len < got and name_buf[name_len] != 0) : (name_len += 1) {}
    if (name_len == got and got < name_buf.len) return errno.EFAULT; // truncated mid-name
    if (name_len == 0 or name_len > devfs.MAX_NAME_LEN) return errno.EINVAL;
    const name = name_buf[0..name_len];
    for (name) |c| {
        if (c == '/') return errno.EINVAL;
    }

    const alloc_flags = alloc_lock.acquire();
    defer alloc_lock.release(alloc_flags);

    if (devfs.lookup(name) != null) return errno.EEXIST;

    // Slot selection: never-used slots first; when all 8 have been used,
    // recycle the lowest-index slot whose owner died (drained by
    // ctrlClose). Mirrors devfs.register's oldest-tombstone-first reuse.
    var slot: ?usize = null;
    var dead_slot: ?usize = null;
    for (&nodes, 0..) |*n, i| {
        if (!n.used) {
            slot = i;
            break;
        }
        if (dead_slot == null and !n.core.owner_alive) dead_slot = i;
    }
    const i = slot orelse (dead_slot orelse return errno.ENFILE);

    const devfs_idx = devfs.register(name, opsFor(i)) orelse return errno.ENFILE;
    const generation = devfs.generationAt(devfs_idx) orelse {
        _ = devfs.unregister(devfs_idx);
        return errno.EIO;
    };

    const fd = cur.fd_table.allocFd() orelse {
        _ = devfs.unregister(devfs_idx);
        return errno.EMFILE;
    };

    // Publish the new registration under node.lock: a full reset on
    // recycle so no stale request, waiter, or owner crosses into the new
    // node (stale fds fail on the generation check instead).
    {
        const node = &nodes[i];
        const node_flags = node.lock.acquire();
        defer node.lock.release(node_flags);
        if (node.used and node.core.owner_alive) {
            // Lost a death race (owner died without ctrlClose yet —
            // cleanupTask fires at reap). Refuse rather than resetting a
            // live node; the caller can retry after the reap.
            cur.fd_table.freeFd(fd);
            _ = devfs.unregister(devfs_idx);
            return errno.ENFILE;
        }
        // Reset field by field — node.lock itself must NOT be touched
        // (we are holding it).
        node.used = true;
        node.devfs_idx = devfs_idx;
        node.owner_task_idx = cur.self_idx;
        node.generation = generation;
        node.core = .{};
        node.client_wq = null;
        node.owner_wq = null;
        node.space_wq = null;
    }
    cur.fd_table.fds[fd] = .{
        .fd_type = .devfs_ctrl,
        .devfs_ctrl_idx = @intCast(i),
        .devfs_generation = generation,
        .writable = true,
    };
    cur.fd_table.publishFd(fd);
    return @intCast(fd);
}
