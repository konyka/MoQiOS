//! Host tests for kernel/sync/sleep_lock.zig. Real OS threads stand in for
//! tasks; the model scheduler below implements "block / wake oldest / sleep"
//! the way the kernel's wait queues do, including a mode where a sleeper
//! returns early without being granted the lock (the kernel's
//! signal-kick / no-switch path).

const std = @import("std");
const kt = @import("kernel_shared");

const MAX_THREADS = 8;

const Model = struct {
    blocked: [MAX_THREADS]u32 = @splat(0),
    /// How many enqueue() calls have happened (tests wait on this).
    queued_total: u32 = 0,
    /// When set, sleepAfterBlock() gives up after a short spin without a wake.
    spurious: bool = false,
    /// Number of times a granted node was found still linked (must stay 0).
    stale_links: u32 = 0,
};

var model: Model = .{};
threadlocal var my_tid: ?u32 = null;

const ModelGuard = struct {
    locked: u32 = 0,
    pub fn acquire(self: *ModelGuard) u64 {
        while (@cmpxchgWeak(u32, &self.locked, 0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        return 0;
    }
    pub fn release(self: *ModelGuard, _: u64) void {
        @atomicStore(u32, &self.locked, 0, .release);
    }
};

const ModelNode = struct {
    granted: bool = false,
    next: ?*ModelNode = null,
    tid: u32 = 0,
};

const Env = struct {
    pub const Guard = ModelGuard;
    pub const Node = ModelNode;
    pub fn newNode() ModelNode {
        return .{};
    }
    pub fn currentTask() ?u32 {
        return my_tid;
    }
    pub fn enqueue(queue: *?*ModelNode, node: *ModelNode) bool {
        node.tid = my_tid.?;
        node.granted = false;
        node.next = queue.*; // newest at the head, like sched.blockOn
        queue.* = node;
        @atomicStore(u32, &model.blocked[my_tid.?], 1, .release);
        _ = @atomicRmw(u32, &model.queued_total, .Add, 1, .seq_cst);
        return true;
    }
    pub fn wakeOne(queue: *?*ModelNode) ?u32 {
        // pop the OLDEST waiter (the tail), like sched.wakeOne
        var prev: ?*ModelNode = null;
        var cur = queue.*;
        while (cur) |n| {
            if (n.next == null) {
                n.granted = true;
                if (prev) |p| p.next = null else queue.* = null;
                @atomicStore(u32, &model.blocked[n.tid], 0, .release);
                return n.tid;
            }
            prev = n;
            cur = n.next;
        }
        return null;
    }
    pub fn sleepAfterBlock() void {
        const me = my_tid.?;
        var spins: u32 = 0;
        while (@atomicLoad(u32, &model.blocked[me], .acquire) != 0) {
            std.Thread.yield() catch {};
            spins += 1;
            if (model.spurious and spins > 20) {
                // repairCurrentAfterBlock: still blocked but running again
                @atomicStore(u32, &model.blocked[me], 0, .release);
                return;
            }
        }
    }
    pub fn relax() void {
        std.atomic.spinLoopHint();
    }
};

const Lock = kt.sleep_lock.SleepLock(Env);

fn resetModel() void {
    model = .{};
    my_tid = null;
}

fn waitQueued(n: u32) void {
    while (@atomicLoad(u32, &model.queued_total, .seq_cst) < n) std.Thread.yield() catch {};
}

test "sleep lock gives mutual exclusion under real thread contention" {
    resetModel();
    const THREADS = 6;
    const ROUNDS = 3000;
    const Shared = struct {
        lock: Lock = .{},
        counter: u64 = 0,
        in_section: u32 = 0,
        overlap: u32 = 0,
    };
    var shared: Shared = .{};
    const Worker = struct {
        fn run(sh: *Shared, tid: u32) void {
            my_tid = tid;
            var i: u32 = 0;
            while (i < ROUNDS) : (i += 1) {
                sh.lock.lock();
                if (@atomicRmw(u32, &sh.in_section, .Xchg, 1, .seq_cst) != 0)
                    @atomicStore(u32, &sh.overlap, 1, .seq_cst);
                const v = @as(*volatile u64, &sh.counter).*;
                @as(*volatile u64, &sh.counter).* = v + 1;
                @atomicStore(u32, &sh.in_section, 0, .seq_cst);
                sh.lock.unlock();
            }
        }
    };
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, Worker.run, .{ &shared, @as(u32, @intCast(i)) });
    for (&threads) |*th| th.join();
    try std.testing.expectEqual(@as(u32, 0), shared.overlap);
    try std.testing.expectEqual(@as(u64, THREADS * ROUNDS), shared.counter);
    try std.testing.expect(!shared.lock.held);
    try std.testing.expect(shared.lock.waiters == null);
}

test "sleepers are served in arrival order" {
    resetModel();
    const Shared = struct {
        lock: Lock = .{},
        order: [3]u8 = .{ 0, 0, 0 },
        pos: u32 = 0,
    };
    var shared: Shared = .{};
    const Waiter = struct {
        fn run(sh: *Shared, tid: u32, tag: u8) void {
            my_tid = tid;
            sh.lock.lock();
            const p = @atomicRmw(u32, &sh.pos, .Add, 1, .seq_cst);
            sh.order[p] = tag;
            sh.lock.unlock();
        }
    };
    var round: u32 = 0;
    while (round < 40) : (round += 1) {
        model.queued_total = 0;
        shared = .{};
        my_tid = 7;
        shared.lock.lock();
        var a = try std.Thread.spawn(.{}, Waiter.run, .{ &shared, @as(u32, 0), @as(u8, 'A') });
        waitQueued(1);
        var b = try std.Thread.spawn(.{}, Waiter.run, .{ &shared, @as(u32, 1), @as(u8, 'B') });
        waitQueued(2);
        var c = try std.Thread.spawn(.{}, Waiter.run, .{ &shared, @as(u32, 2), @as(u8, 'C') });
        waitQueued(3);
        shared.lock.unlock();
        a.join();
        b.join();
        c.join();
        try std.testing.expectEqualStrings("ABC", &shared.order);
    }
}

test "unlock hands ownership to the oldest sleeper; a newcomer cannot barge in" {
    resetModel();
    var lock: Lock = .{};
    const Waiter = struct {
        fn run(l: *Lock, got: *u32, release: *u32) void {
            my_tid = 0;
            l.lock();
            @atomicStore(u32, got, 1, .seq_cst);
            while (@atomicLoad(u32, release, .seq_cst) == 0) std.Thread.yield() catch {};
            l.unlock();
        }
    };
    var got: u32 = 0;
    var release: u32 = 0;
    my_tid = 7;
    lock.lock();
    var t = try std.Thread.spawn(.{}, Waiter.run, .{ &lock, &got, &release });
    waitQueued(1);
    lock.unlock();
    // The lock was handed over: it must look held even before the sleeper runs,
    // so nobody else can slip in between the wake and the sleeper's resume.
    try std.testing.expect(!lock.tryLock());
    while (@atomicLoad(u32, &got, .seq_cst) == 0) std.Thread.yield() catch {};
    try std.testing.expect(!lock.tryLock());
    @atomicStore(u32, &release, 1, .seq_cst);
    t.join();
    try std.testing.expect(lock.tryLock());
    lock.unlock();
    try std.testing.expect(!lock.held);
}

test "a sleeper that wakes without being granted re-queues and still gets the lock exactly once" {
    resetModel();
    model.spurious = true;
    const THREADS = 4;
    const ROUNDS = 400;
    const Shared = struct {
        lock: Lock = .{},
        counter: u64 = 0,
        in_section: u32 = 0,
        overlap: u32 = 0,
        done: u32 = 0,
    };
    var shared: Shared = .{};
    const Worker = struct {
        fn run(sh: *Shared, tid: u32) void {
            my_tid = tid;
            var i: u32 = 0;
            while (i < ROUNDS) : (i += 1) {
                sh.lock.lock();
                if (@atomicRmw(u32, &sh.in_section, .Xchg, 1, .seq_cst) != 0)
                    @atomicStore(u32, &sh.overlap, 1, .seq_cst);
                const v = @as(*volatile u64, &sh.counter).*;
                @as(*volatile u64, &sh.counter).* = v + 1;
                // hold long enough that the others time out of their sleep
                var k: u32 = 0;
                while (k < 40) : (k += 1) std.Thread.yield() catch {};
                @atomicStore(u32, &sh.in_section, 0, .seq_cst);
                sh.lock.unlock();
            }
            _ = @atomicRmw(u32, &sh.done, .Add, 1, .seq_cst);
        }
    };
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, Worker.run, .{ &shared, @as(u32, @intCast(i)) });
    // A lock that leaves a dead node queued wedges everyone behind it; fail
    // after a deadline instead of hanging the test run.
    const deadline_ms: i64 = 20_000;
    const start = std.Io.Clock.now(.awake, std.testing.io);
    while (@atomicLoad(u32, &shared.done, .seq_cst) < THREADS) {
        std.Thread.yield() catch {};
        const now = std.Io.Clock.now(.awake, std.testing.io);
        if (start.durationTo(now).toMilliseconds() > deadline_ms) {
            // Leak the wedged threads: unblock nothing, just report.
            return error.LockWedged;
        }
    }
    for (&threads) |*th| th.join();
    try std.testing.expectEqual(@as(u32, 0), shared.overlap);
    try std.testing.expectEqual(@as(u64, THREADS * ROUNDS), shared.counter);
    // No stack node may stay linked after its owner returned.
    try std.testing.expect(shared.lock.waiters == null);
    try std.testing.expect(!shared.lock.held);
}

test "before the scheduler exists the lock spins instead of sleeping" {
    resetModel();
    my_tid = null; // currentTask() == null
    var lock: Lock = .{};
    lock.lock();
    try std.testing.expect(lock.held);
    try std.testing.expect(!lock.tryLock());
    lock.unlock();
    try std.testing.expect(!lock.held);
    lock.lock();
    lock.unlock();
}

test "tryLock takes a free lock and refuses a held one" {
    resetModel();
    my_tid = 0;
    var lock: Lock = .{};
    try std.testing.expect(lock.tryLock());
    try std.testing.expect(!lock.tryLock());
    lock.unlock();
    try std.testing.expect(lock.tryLock());
    lock.unlock();
}
