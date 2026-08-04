/// Kernel log system — outputs to serial with level prefixes, and mirrors
/// every emitted line into a fixed-size ring buffer backing /dev/kmsg (G4).
const serial = @import("arch/arch.zig").serial;
const fmt = @import("lib/fmt.zig");
const kmsg_ring = @import("lib/kmsg_ring.zig");
const IrqSpinlock = @import("sync/irq_spinlock.zig").IrqSpinlock;
const task = @import("proc/task.zig");
const sched = @import("proc/sched.zig");
const epoll = @import("net/epoll.zig");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
};

/// Capacity of the /dev/kmsg backing ring. On overflow the oldest complete
/// lines are dropped (see lib/kmsg_ring.zig).
pub const KMSG_CAP: usize = 64 * 1024;

var ring: kmsg_ring.KmsgRing(KMSG_CAP) = .{};
/// ISR-safe: same pattern as serial.zig — IrqSpinlock masks IRQs while the
/// ring is mutated, so log() from interrupt context cannot tear state.
/// No allocation anywhere on this path.
var ring_lock: IrqSpinlock = .{};

/// Wait queue for blocking /dev/kmsg readers (J3). Guarded by `ring_lock`:
/// readers link their node and mark themselves blocked inside the same
/// critical section as the empty-check (kmsgReadOrBlock), and ringAppend
/// wakes one waiter under the same lock, so an append can never slip
/// between a reader's empty-check and its enqueue (no lost wakeup).
var kmsg_waiters: ?*task.WaitNode = null;

var min_level: Level = .debug;

pub fn setLevel(level: Level) void {
    min_level = level;
}

fn levelPrefix(comptime level: Level) []const u8 {
    return switch (level) {
        .err => "[ERR] ",
        .warn => "[WRN] ",
        .info => "[INF] ",
        .debug => "[DBG] ",
    };
}

/// Read from the kmsg ring at absolute cursor `read_pos` (0 = oldest
/// available byte; stale cursors clamp forward). Short reads at the
/// physical wrap are normal — callers loop on `new_pos`.
pub fn kmsgRead(read_pos: u64, buf: []u8) kmsg_ring.ReadResult {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    return ring.read(read_pos, buf);
}

/// Absolute cursor of the oldest byte still in the ring.
pub fn kmsgOldestPos() u64 {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    return ring.oldestPos();
}

/// Absolute cursor one past the newest byte in the ring.
pub fn kmsgNewestPos() u64 {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    return ring.newestPos();
}

/// True when a reader at absolute `cursor` still has unread ring bytes
/// (J3) — feeds the blocking-read empty check and epoll's EPOLLIN.
pub fn kmsgHasUnread(cursor: u64) bool {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    return kmsg_ring.bytesAvailable(ring.newestPos(), cursor) > 0;
}

/// Outcome of kmsgReadOrBlock.
pub const KmsgReadOrBlock = union(enum) {
    /// Data was copied (or there is no current task to block — early boot
    /// / kernel-thread callers get the old non-blocking EOF behaviour).
    ready: kmsg_ring.ReadResult,
    /// No data: `node` is linked on the kmsg wait queue and the current
    /// task is marked .blocked. The caller must forceReschedule(), then
    /// kmsgUnlinkWaiter() and re-check signals before retrying.
    blocked,
};

/// Attempt a read at absolute cursor `read_pos`; if no data is available,
/// atomically (under `ring_lock`) join the kmsg wait queue and mark the
/// current task blocked. Holding the lock across check + enqueue is what
/// closes the lost-wakeup race against ringAppend, which appends and wakes
/// under the same lock (the sysv_sem / posix_mq pattern).
pub fn kmsgReadOrBlock(read_pos: u64, buf: []u8, node: *task.WaitNode) KmsgReadOrBlock {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    const res = ring.read(read_pos, buf);
    if (res.n > 0) return .{ .ready = res };
    if (!sched.blockOn(&kmsg_waiters, node)) return .{ .ready = res };
    return .blocked;
}

/// Remove `node` from the kmsg wait queue if it is still linked. A granted
/// wakeOne already popped it (this is then a no-op); a signal kick
/// (sendSignal → kickIfBlocked) unblocks the task without touching the
/// queue, so an interrupted wait MUST unlink here before its stack frame
/// goes away (mirrors posix_mq's unlinkNode).
pub fn kmsgUnlinkWaiter(node: *task.WaitNode) void {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    var prev: ?*task.WaitNode = null;
    var cur = kmsg_waiters;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                kmsg_waiters = n.next;
            }
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

fn ringAppend(parts: []const []const u8) void {
    {
        const flags = ring_lock.acquire();
        defer ring_lock.release(flags);
        for (parts) |p| ring.appendLine(p);
        // J3: wake one blocked /dev/kmsg reader after the data is stored.
        // ISR-safe: log() runs from interrupt context, and wakeOne only
        // flips WaitNode/task state words and pushes onto a per-CPU
        // runqueue (IrqSpinlock, no allocation) — the same wake the
        // writeback thread tick already performs from the timer ISR
        // (fs/vfs.zig writebackTimerTick). Lock order is
        // ring_lock → task_lock/runqueue lock; nothing in proc/ ever calls
        // back into klog, so no cycle.
        _ = sched.wakeOne(&kmsg_waiters);
    }
    // J3: notify epoll AFTER releasing ring_lock. epollNotify walks
    // instances under pool_lock/inst.spin, and epoll's collectEvents
    // acquires ring_lock while holding inst.spin (kmsg cursor check) —
    // nesting ring_lock outside inst.spin here would close a lock-order
    // cycle. ISR-safety of epollNotify from interrupt context is already
    // established by timerfd, which notifies from the timer tick.
    // /dev/kmsg is a devfs node: match on fd_type .devfs + its slot index.
    epoll.epollNotify(.devfs, @import("fs/devfs_nodes.zig").kmsgNodeIdx(), epoll.EPOLLIN);
}

pub fn log(comptime level: Level, comptime msg: []const u8) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    const prefix = comptime levelPrefix(level);
    serial.writeString(prefix);
    serial.writeString(msg);
    serial.writeString("\n");
    ringAppend(&.{ prefix, msg, "\n" });
}

pub fn logHex(comptime level: Level, comptime prefix: []const u8, value: u64) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    const lp = comptime levelPrefix(level);
    serial.writeString(lp);
    serial.writeString(prefix);
    serial.writeString("0x");
    fmt.writeHex(value);
    serial.writeString("\n");
    var hexbuf: [16]u8 = undefined;
    ringAppend(&.{ lp, prefix, "0x", fmt.fmtHex16(&hexbuf, value), "\n" });
}
