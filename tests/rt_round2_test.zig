//! Host tests for the second real-time / performance / security round
//! (docs/realtime-security-hardening-plan.md §8).

const std = @import("std");
const kt = @import("kernel_shared");

// ── R2-1: fair FIFO ticket lock ─────────────────────────────────────────

const ticket_lock = kt.ticket_lock;

fn spinRelax() void {
    std.atomic.spinLoopHint();
}

test "ticket lock hands the lock over in strict ticket (FIFO) order" {
    var l: ticket_lock.Ticket = .{};
    try std.testing.expect(!l.isLocked());
    const a = l.take();
    try std.testing.expect(l.isServing(a));
    const b = l.take();
    const c = l.take();
    try std.testing.expect(l.isLocked());
    try std.testing.expectEqual(@as(u32, 2), l.waiters());
    try std.testing.expect(!l.isServing(b));
    try std.testing.expect(!l.isServing(c));
    l.unlock();
    // The NEXT ticket gets the lock, never a later one.
    try std.testing.expect(l.isServing(b));
    try std.testing.expect(!l.isServing(c));
    try std.testing.expectEqual(@as(u32, 1), l.waiters());
    l.unlock();
    try std.testing.expect(l.isServing(c));
    try std.testing.expectEqual(@as(u32, 0), l.waiters());
    l.unlock();
    try std.testing.expect(!l.isLocked());
}

test "ticket lock tryLock never jumps the queue" {
    var l: ticket_lock.Ticket = .{};
    try std.testing.expect(l.tryLock());
    try std.testing.expect(!l.tryLock());
    _ = l.take(); // a waiter queues behind the holder
    l.unlock(); // ...and now owns the lock
    try std.testing.expect(!l.tryLock());
    l.unlock();
    try std.testing.expect(l.tryLock());
    l.unlock();
    try std.testing.expect(!l.isLocked());
}

test "ticket lock survives counter wrap-around" {
    const top = std.math.maxInt(u32);
    var l: ticket_lock.Ticket = .{ .next = top - 1, .serving = top - 1 };
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        l.lock(spinRelax);
        try std.testing.expect(l.isLocked());
        l.unlock();
        try std.testing.expect(!l.isLocked());
    }
    try std.testing.expect(l.tryLock());
    try std.testing.expect(!l.tryLock());
    l.unlock();
}

test "ticket lock gives mutual exclusion under real thread contention" {
    const THREADS = 4;
    const ROUNDS = 20_000;
    const Shared = struct {
        lock: ticket_lock.Ticket = .{},
        counter: u64 = 0,
        in_section: u32 = 0,
        overlap: u32 = 0,
    };
    var shared: Shared = .{};
    const Worker = struct {
        fn run(sh: *Shared) void {
            var i: u32 = 0;
            while (i < ROUNDS) : (i += 1) {
                if (i % 3 == 0) {
                    while (!sh.lock.tryLock()) std.atomic.spinLoopHint();
                } else {
                    sh.lock.lock(spinRelax);
                }
                if (@atomicRmw(u32, &sh.in_section, .Xchg, 1, .seq_cst) != 0)
                    @atomicStore(u32, &sh.overlap, 1, .seq_cst);
                // Deliberately non-atomic read-modify-write: only exclusion
                // keeps the total exact.
                const v = @as(*volatile u64, &sh.counter).*;
                @as(*volatile u64, &sh.counter).* = v + 1;
                @atomicStore(u32, &sh.in_section, 0, .seq_cst);
                sh.lock.unlock();
            }
        }
    };
    var threads: [THREADS]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{&shared});
    for (&threads) |*th| th.join();
    try std.testing.expectEqual(@as(u32, 0), shared.overlap);
    try std.testing.expectEqual(@as(u64, THREADS * ROUNDS), shared.counter);
    try std.testing.expect(!shared.lock.isLocked());
}

test "ticket lock serves real waiters in arrival order" {
    // Deterministic FIFO check with real threads: the holder waits until
    // waiter A has queued, then until waiter B has queued, then releases.
    // A test-and-set lock lets either waiter win; a ticket lock must hand
    // the lock to A first.
    const Shared = struct {
        lock: ticket_lock.Ticket = .{},
        order: [2]u8 = .{ 0, 0 },
        pos: u32 = 0,
    };
    var shared: Shared = .{};
    const Waiter = struct {
        fn run(sh: *Shared, tag: u8) void {
            sh.lock.lock(spinRelax);
            const p = @atomicRmw(u32, &sh.pos, .Add, 1, .seq_cst);
            sh.order[p] = tag;
            sh.lock.unlock();
        }
    };
    var round: u32 = 0;
    while (round < 50) : (round += 1) {
        shared = .{};
        shared.lock.lock(spinRelax);
        const ta = try std.Thread.spawn(.{}, Waiter.run, .{ &shared, 'A' });
        while (shared.lock.waiters() < 1) std.atomic.spinLoopHint();
        const tb = try std.Thread.spawn(.{}, Waiter.run, .{ &shared, 'B' });
        while (shared.lock.waiters() < 2) std.atomic.spinLoopHint();
        shared.lock.unlock();
        ta.join();
        tb.join();
        try std.testing.expectEqualSlices(u8, "AB", &shared.order);
    }
}
