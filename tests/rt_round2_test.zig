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

// ── R2-2: deferred reaping ──────────────────────────────────────────────

const reap_policy = kt.reap_policy;

fn zombie(over: anytype) reap_policy.ZombieView {
    var v: reap_policy.ZombieView = .{
        .is_zombie = true,
        .reap_pending = false,
        .operation_refs = 0,
        .current_somewhere = false,
        .exit_cpu = 0,
        .exit_epoch = 10,
        .exit_cpu_entries = 13,
    };
    inline for (std.meta.fields(@TypeOf(over))) |f| @field(v, f.name) = @field(over, f.name);
    return v;
}

test "reap verdict keeps the old quiesce gate and never detaches twice" {
    const p = reap_policy;
    try std.testing.expectEqual(p.Verdict.detach, p.verdict(zombie(.{})));
    try std.testing.expectEqual(p.Verdict.skip, p.verdict(zombie(.{ .is_zombie = false })));
    // Already handed to the reaper: invisible to every later scan.
    try std.testing.expectEqual(p.Verdict.skip, p.verdict(zombie(.{ .reap_pending = true })));
    try std.testing.expectEqual(p.Verdict.busy, p.verdict(zombie(.{ .operation_refs = 1 })));
    try std.testing.expectEqual(p.Verdict.busy, p.verdict(zombie(.{ .current_somewhere = true })));
    // Exit-time switch epilogue may still run on the kernel stack until three
    // scheduler passes have happened on the exit CPU.
    try std.testing.expectEqual(p.Verdict.busy, p.verdict(zombie(.{ .exit_cpu_entries = 12 })));
    try std.testing.expectEqual(p.Verdict.detach, p.verdict(zombie(.{ .exit_cpu_entries = 13 })));
    try std.testing.expectEqual(p.Verdict.detach, p.verdict(zombie(.{ .exit_cpu = 255, .exit_cpu_entries = 0 })));
    // An epoch near the counter limit must not overflow into "quiesced".
    try std.testing.expectEqual(p.Verdict.busy, p.verdict(zombie(.{
        .exit_epoch = std.math.maxInt(u64) - 1,
        .exit_cpu_entries = std.math.maxInt(u64) - 1,
    })));
}

test "reap set hands each detached slot to the reaper exactly once" {
    var s: reap_policy.PendingSet(64) = .{};
    try std.testing.expect(!s.hasUnstarted());
    s.add(5, reap_policy.NO_WAITER);
    s.add(63, 7);
    s.add(0, reap_policy.NO_WAITER);
    try std.testing.expect(s.isPending(5) and s.isPending(63) and s.isPending(0));
    try std.testing.expect(!s.isPending(6));

    // Lowest slot first; a started slot stays pending (its waiter keeps
    // sleeping) until complete() but is never handed out again.
    try std.testing.expectEqual(@as(?u32, 0), s.takeUnstarted());
    try std.testing.expect(s.isPending(0));
    try std.testing.expectEqual(@as(?u32, 5), s.takeUnstarted());
    try std.testing.expectEqual(@as(?u32, 63), s.takeUnstarted());
    try std.testing.expectEqual(@as(?u32, null), s.takeUnstarted());
    try std.testing.expect(!s.hasUnstarted());

    try std.testing.expectEqual(reap_policy.NO_WAITER, s.complete(0));
    try std.testing.expect(!s.isPending(0));
    try std.testing.expectEqual(@as(u32, 7), s.complete(63));
    try std.testing.expectEqual(reap_policy.NO_WAITER, s.complete(5));
    try std.testing.expect(!s.isPending(5) and !s.isPending(63));
}

test "reap set records the waiter that arrives after detach" {
    var s: reap_policy.PendingSet(64) = .{};
    s.add(9, reap_policy.NO_WAITER);
    try std.testing.expect(s.setWaiter(9, 3));
    try std.testing.expectEqual(@as(?u32, 9), s.takeUnstarted());
    try std.testing.expectEqual(@as(u32, 3), s.complete(9));
    // Completed: a late waiter must not block (nothing left to wait for).
    try std.testing.expect(!s.setWaiter(9, 4));
    // A re-detached slot starts clean.
    s.add(9, reap_policy.NO_WAITER);
    try std.testing.expect(s.hasUnstarted());
    try std.testing.expectEqual(reap_policy.NO_WAITER, s.complete(9));
}

test "autoreap takes orphans and dead threads but leaves children for waitpid" {
    const p = reap_policy;
    // A process zombie with a live parent belongs to that parent's waitpid.
    try std.testing.expectEqual(p.Verdict.skip, p.autoReap(zombie(.{}), .{ .is_thread = false, .parent_alive = true, .maps_objects = false }));
    try std.testing.expectEqual(p.Verdict.detach, p.autoReap(zombie(.{}), .{ .is_thread = false, .parent_alive = false, .maps_objects = false }));
    // Threads are joined through clear_tid, never through waitpid: their
    // slots must not wait for the group leader to exit.
    try std.testing.expectEqual(p.Verdict.detach, p.autoReap(zombie(.{}), .{ .is_thread = true, .parent_alive = true, .maps_objects = false }));
    // The quiesce gate still applies.
    try std.testing.expectEqual(p.Verdict.busy, p.autoReap(zombie(.{ .current_somewhere = true }), .{ .is_thread = true, .parent_alive = true, .maps_objects = false }));
    // A thread's region table is an unreferenced copy of the leader's: if it
    // names file-backed or device mappings, tearing it down while the group
    // lives would close the leader's files / unmap shared MMIO. Such threads
    // wait for the group, as before.
    try std.testing.expectEqual(p.Verdict.skip, p.autoReap(zombie(.{}), .{ .is_thread = true, .parent_alive = true, .maps_objects = true }));
    try std.testing.expectEqual(p.Verdict.detach, p.autoReap(zombie(.{}), .{ .is_thread = true, .parent_alive = false, .maps_objects = true }));
    try std.testing.expectEqual(p.Verdict.skip, p.autoReap(zombie(.{ .reap_pending = true }), .{ .is_thread = true, .parent_alive = false, .maps_objects = false }));
}

// ── R2-2b: round-robin slot scan (pickReadyForCpu) ──────────────────────

fn collectCursor(bitmap: u64, start: u32, out: []u32) usize {
    var it = kt.sched_policy.SlotCursor.init(bitmap, start);
    var n: usize = 0;
    while (it.next()) |idx| : (n += 1) out[n] = idx;
    return n;
}

test "slot cursor visits every set slot once, from start, wrapping" {
    var buf: [64]u32 = undefined;
    // Slot 63 occupied and a non-zero start: the old scan advanced its
    // position to 64 and overflowed the u6 shift (kernel panic once the task
    // table filled up).
    const bm: u64 = (@as(u64, 1) << 63) | 0b10_0110;
    var n = collectCursor(bm, 5, &buf);
    try std.testing.expectEqualSlices(u32, &.{ 5, 63, 1, 2 }, buf[0..n]);
    n = collectCursor(bm, 0, &buf);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 5, 63 }, buf[0..n]);
    n = collectCursor(bm, 63, &buf);
    try std.testing.expectEqualSlices(u32, &.{ 63, 1, 2, 5 }, buf[0..n]);
    n = collectCursor(~@as(u64, 0), 64, &buf); // start past the end == 0
    try std.testing.expectEqual(@as(usize, 64), n);
    try std.testing.expectEqual(@as(u32, 0), buf[0]);
    try std.testing.expectEqual(@as(u32, 63), buf[63]);
    n = collectCursor(~@as(u64, 0), 40, &buf);
    try std.testing.expectEqual(@as(usize, 64), n);
    try std.testing.expectEqual(@as(u32, 40), buf[0]);
    try std.testing.expectEqual(@as(u32, 39), buf[63]);
    try std.testing.expectEqual(@as(usize, 0), collectCursor(0, 17, &buf));
}

// ── R2-3: late reschedule-IPI dedup ─────────────────────────────────────

const ipi_kick_policy = kt.ipi_kick_policy;

test "a second kick while a reschedule IPI is already pending is dropped" {
    const p = ipi_kick_policy;
    try std.testing.expect(p.shouldSend(false));
    try std.testing.expect(!p.shouldSend(true));
    // Marking pending is a one-way trip until the IPI pass clears it.
    try std.testing.expectEqual(@as(u8, 1), p.mark(0));
    try std.testing.expectEqual(@as(u8, 1), p.mark(1));
    try std.testing.expectEqual(@as(u8, 0), p.clear());
}

// ── R2-4: RT bandwidth + strict RR ──────────────────────────────────────

const rt_bw = kt.rt_bandwidth_policy;

test "RT bandwidth throttles after the runtime budget and resets each period" {
    var b: rt_bw.Bucket = .{};
    try std.testing.expect(!b.throttled(0));
    var t: u64 = 0;
    while (t < rt_bw.RUNTIME_TICKS) : (t += 1) {
        b.onRtTick(t);
        try std.testing.expect(!b.throttled(t) or t + 1 >= rt_bw.RUNTIME_TICKS);
    }
    try std.testing.expect(b.throttled(rt_bw.RUNTIME_TICKS - 1));
    // OTHER ticks in the same period do not refill the RT budget.
    b.roll(rt_bw.RUNTIME_TICKS + 2);
    try std.testing.expect(b.throttled(rt_bw.RUNTIME_TICKS + 2));
    // A new period clears the throttle.
    b.roll(rt_bw.PERIOD_TICKS);
    try std.testing.expect(!b.throttled(rt_bw.PERIOD_TICKS));
    try std.testing.expectEqual(@as(u32, 0), b.used);
}

test "strict RR keeps the CPU over lower-ranked work unless RT is throttled" {
    const p = rt_bw;
    // Equal RR peer: rotate (do not keep).
    try std.testing.expect(!p.rrKeepsOver(49, 49, false));
    // Better RT ready: yield.
    try std.testing.expect(!p.rrKeepsOver(49, 10, false));
    // Only OTHER is queued: keep, unless the RT band is throttled.
    try std.testing.expect(p.rrKeepsOver(49, 120, false));
    try std.testing.expect(!p.rrKeepsOver(49, 120, true));
    // FIFO follows the same throttle rule: a spinning FIFO must not lock the
    // CPU past the runtime budget.
    try std.testing.expect(p.mayKeep(false, true));
    try std.testing.expect(!p.mayKeep(true, true));
    try std.testing.expect(!p.mayKeep(false, false));
}

// ── R2-5: SMAP is enabled together with SMEP/UMIP ───────────────────────

test "CR4 includes SMAP once the copy path is stac/clac bracketed" {
    const p = kt.cpu_protect_policy;
    const all = p.features(7, p.CPUID7_EBX_SMEP | p.CPUID7_EBX_SMAP, p.CPUID7_ECX_UMIP);
    try std.testing.expect(all.smap);
    try std.testing.expectEqual(p.CR4_SMEP | p.CR4_UMIP | p.CR4_SMAP, p.cr4Bits(all));
    try std.testing.expectEqual(@as(u64, 0), p.cr4Bits(p.features(7, 0, 0)));
}

// ── R2-6: one-shot deadline is the earlier of slice and wait ────────────

const deadline_timer = kt.deadline_timer_policy;

test "LAPIC deadline is the earlier of the remaining slice and the next wait" {
    const p = deadline_timer;
    // No wait: fire at the end of the remaining slice (at least one tick).
    try std.testing.expectEqual(@as(u64, 1_000 + 3 * 100), p.nextDeadlineTsc(1_000, 100, 3, null));
    try std.testing.expectEqual(@as(u64, 1_000 + 100), p.nextDeadlineTsc(1_000, 100, 0, null));
    // A wait sooner than the slice wins.
    try std.testing.expectEqual(@as(u64, 1_050), p.nextDeadlineTsc(1_000, 100, 3, 1_050));
    // A wait in the past still arms "now" (saturation), never a wrap.
    try std.testing.expectEqual(@as(u64, 1_000), p.nextDeadlineTsc(1_000, 100, 3, 10));
    // A wait later than the slice is ignored.
    try std.testing.expectEqual(@as(u64, 1_300), p.nextDeadlineTsc(1_000, 100, 3, 9_000));
}
