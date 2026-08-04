/// devfs built-in nodes — kernel-backed device implementations registered
/// into the pure devfs table (fs/devfs.zig) at kernel init.
///
/// Node inventory (registration order = getdents enumeration order):
///   null    — read: EOF, write: discard (pure, devfs.zig)
///   zero    — read: zero-filled buffer, write: discard (pure, devfs.zig)
///   full    — read: EOF, write: -ENOSPC (pure, devfs.zig)
///   random  — PRNG stream (drivers/random.zig), read-only, no pread
///   urandom — same ops as random
///   kmsg    — kernel log ring (klog.zig); read blocks until a log append
///             unless O_NONBLOCK, cursor lives in the fd offset (J3)
///   pci     — read-only PCI enumeration snapshot (drivers/userdrv.zig);
///             open requires CAP_SYS_RAWIO (L1 user driver framework)
///   tty     — console: write → serial out; read → PS/2 keyboard input
///             queue on x86_64, -ENOTTY elsewhere (no serial RX path)
///   devfs-watch — read-only devfs change counter (u64 LE); read blocks
///             until the counter moves past the fd's last-read cursor
///             (devfs register/unregister, e.g. devfs_proxy nodes)
const builtin = @import("builtin");
const devfs = @import("devfs.zig");

var registered: bool = false;
/// Slot index of the kmsg node (epollNotify matching + epoll cursor
/// recovery). DIR_IDX = not registered yet.
var kmsg_idx: u32 = devfs.DIR_IDX;
/// Slot index of the devfs-watch node (epollNotify on change events).
var watch_idx: u32 = devfs.DIR_IDX;

pub fn init() void {
    if (registered) return;
    registered = true;

    // Install the change hook before any registration that could matter
    // (init-time bumps have no waiters yet, but the counter must be live
    // before userspace can open the watch node).
    devfs.change_hook = onDevfsChanged;

    _ = devfs.register("null", devfs.null_node_ops);
    _ = devfs.register("zero", devfs.zero_node_ops);
    _ = devfs.register("full", devfs.full_node_ops);
    _ = devfs.register("random", random_node_ops);
    _ = devfs.register("urandom", random_node_ops);
    kmsg_idx = devfs.register("kmsg", kmsg_node_ops) orelse devfs.DIR_IDX;
    _ = devfs.register("pci", pci_node_ops);
    _ = devfs.register("tty", tty_node_ops);
    watch_idx = devfs.register("devfs-watch", watch_node_ops) orelse devfs.DIR_IDX;
}

/// devfs slot of /dev/kmsg — klog's ring append notifies epoll with this
/// (fd_type .devfs, resource_idx kmsgNodeIdx()).
pub fn kmsgNodeIdx() u32 {
    return kmsg_idx;
}

// ---- random / urandom ----

fn randomRead(ctx: *devfs.IoCtx, buf: [*]u8, count: usize) i64 {
    _ = ctx;
    const random_mod = @import("../drivers/random.zig");
    const to_read: u32 = @intCast(@min(count, 256));
    var kbuf: [256]u8 = undefined;
    random_mod.getRandomBytes(&kbuf, to_read);
    @memcpy(buf[0..to_read], kbuf[0..to_read]);
    return @intCast(to_read);
}

fn pollReadable(ctx: *const devfs.IoCtx) u32 {
    _ = ctx;
    return devfs.POLL_IN;
}

const random_node_ops: devfs.NodeOps = .{
    .read = randomRead,
    .poll = pollReadable,
    .flags = .{ .no_pread = true },
};

// ---- kmsg ----
// The blocking protocol (wait queue, signal dance) is unchanged from the
// old vfs .kmsg case — only the cursor moved from desc.offset to
// ctx.offset, which the vfs writes back after a successful call.

fn kmsgRead(ctx: *devfs.IoCtx, buf: [*]u8, count: usize) i64 {
    const klog = @import("../klog.zig");
    if (count == 0 or ctx.nonBlocking()) {
        const res = klog.kmsgRead(ctx.offset, buf[0..count]);
        ctx.offset = res.new_pos;
        return @intCast(res.n);
    }
    const sched = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const sig_mod = @import("../proc/signal.zig");
    while (true) {
        var node: task_mod.WaitNode = .{ .task_idx = 0 };
        switch (klog.kmsgReadOrBlock(ctx.offset, buf[0..count], &node)) {
            .ready => |res| {
                ctx.offset = res.new_pos;
                return @intCast(res.n);
            },
            .blocked => {
                sched.forceReschedule();
                klog.kmsgUnlinkWaiter(&node);
                const cur_idx = sched.currentTaskIndex() orelse return 0;
                const cur = task_mod.getTask(cur_idx) orelse return 0;
                if (sig_mod.pendingFatal(cur)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
                if (sig_mod.pendingActionable(cur)) return -4; // -EINTR
            },
        }
    }
}

fn kmsgPoll(ctx: *const devfs.IoCtx) u32 {
    const klog = @import("../klog.zig");
    return if (klog.kmsgHasUnread(ctx.offset)) devfs.POLL_IN else 0;
}

const kmsg_node_ops: devfs.NodeOps = .{
    .read = kmsgRead,
    .poll = kmsgPoll,
};

// ---- pci ----

fn pciOpen() i64 {
    const sched = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const cap_check = @import("../proc/cap_check.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    if (!cap_check.capable(cur, "cap_sys_rawio")) return -1; // EPERM
    return 0;
}

fn pciRead(ctx: *devfs.IoCtx, buf: [*]u8, count: usize) i64 {
    const userdrv = @import("../drivers/userdrv.zig");
    var scratch: [8192]u8 = undefined;
    const generated = userdrv.pciGenerate(&scratch);
    if (ctx.offset >= generated) return 0;
    const avail = generated - @as(u32, @intCast(ctx.offset));
    const to_copy = @min(@as(u32, @intCast(count)), avail);
    @memcpy(buf[0..to_copy], scratch[@as(u32, @intCast(ctx.offset))..@as(u32, @intCast(ctx.offset)) + to_copy]);
    ctx.offset += to_copy;
    return @intCast(to_copy);
}

const pci_node_ops: devfs.NodeOps = .{
    .open = pciOpen,
    .read = pciRead,
    .poll = pollReadable,
};

// ---- tty ----
// Console output goes to the serial port on every arch. Console input:
// x86_64 has the PS/2 keyboard ring (drivers/keyboard.zig, the same queue
// fd 0 reads from); there is no serial RX path anywhere, so non-x86
// reads report -ENOTTY.

fn ttyRead(ctx: *devfs.IoCtx, buf: [*]u8, count: usize) i64 {
    _ = ctx;
    if (comptime builtin.cpu.arch == .x86_64) {
        const keyboard = @import("../drivers/keyboard.zig");
        const n = keyboard.read(buf[0..count]);
        return @intCast(n);
    }
    return -25; // ENOTTY — no console input queue on this arch
}

fn ttyWrite(ctx: *devfs.IoCtx, buf: [*]const u8, count: usize) i64 {
    _ = ctx;
    const serial = @import("../arch/arch.zig").serial;
    serial.writeString(buf[0..count]);
    return @intCast(count);
}

fn ttyPoll(ctx: *const devfs.IoCtx) u32 {
    var mask: u32 = devfs.POLL_OUT;
    if (comptime builtin.cpu.arch == .x86_64) {
        const keyboard = @import("../drivers/keyboard.zig");
        if (keyboard.hasData()) mask |= devfs.POLL_IN;
    }
    _ = ctx;
    return mask;
}

const tty_node_ops: devfs.NodeOps = .{
    .read = ttyRead,
    .write = ttyWrite,
    .poll = ttyPoll,
    .flags = .{ .no_pread = true },
};

// ---- devfs-watch ----
// Change-event stream for devfs itself. devfs.zig bumps a monotonic
// counter on every register/unregister (seq-cst atomic) and fires
// change_hook; the hook wakes blocked readers under watch_lock. A reader
// holds watch_lock across its counter check + wait-queue link, and the
// hook takes watch_lock before waking, so a change can never slip between
// the check and the block (the kmsg J3 pattern). Lock order: watch_lock →
// task/runqueue locks; nothing in proc/ calls back into devfs_nodes.

const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const WatchNode = @import("../proc/task.zig").WaitNode;

var watch_lock: IrqSpinlock = .{};
var watch_waiters: ?*WatchNode = null;

fn onDevfsChanged() void {
    const sched = @import("../proc/sched.zig");
    {
        const flags = watch_lock.acquire();
        defer watch_lock.release(flags);
        sched.wakeAll(&watch_waiters);
    }
    // Notify epoll outside watch_lock (same ordering rule as klog's
    // ringAppend): epoll's collectEvents may take watch_lock via the poll
    // op while holding its instance lock.
    if (watch_idx != devfs.DIR_IDX) {
        const epoll = @import("../net/epoll.zig");
        epoll.epollNotify(.devfs, watch_idx, epoll.EPOLLIN);
    }
}

/// Remove `node` from the watch wait queue if still linked (a signal kick
/// unblocks the task without touching the queue — kmsgUnlinkWaiter twin).
fn watchUnlinkWaiter(node: *WatchNode) void {
    const flags = watch_lock.acquire();
    defer watch_lock.release(flags);
    var prev: ?*WatchNode = null;
    var cur = watch_waiters;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                watch_waiters = n.next;
            }
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

fn watchRead(ctx: *devfs.IoCtx, buf: [*]u8, count: usize) i64 {
    if (count < 8) return -22; // EINVAL — a cursor is exactly one u64
    const sched = @import("../proc/sched.zig");
    const sig_mod = @import("../proc/signal.zig");
    const task_mod = @import("../proc/task.zig");
    const bo = @import("../lib/byte_order.zig");
    while (true) {
        var node: WatchNode = .{ .task_idx = 0 };
        {
            const flags = watch_lock.acquire();
            const cur = devfs.changeCounter();
            if (cur != ctx.offset) {
                // A fresh fd (offset 0) sees the current counter at once —
                // init-time registrations already bumped it past 0.
                bo.writeU64Le(buf[0..8], cur);
                ctx.offset = cur;
                watch_lock.release(flags);
                return 8;
            }
            if (ctx.nonBlocking()) {
                watch_lock.release(flags);
                return -11; // EAGAIN
            }
            if (!sched.blockOn(&watch_waiters, &node)) {
                watch_lock.release(flags);
                return -5; // EIO — no current task to block
            }
            watch_lock.release(flags);
        }
        sched.forceReschedule();
        watchUnlinkWaiter(&node);
        const cur_idx = sched.currentTaskIndex() orelse return 0;
        const cur_task = task_mod.getTask(cur_idx) orelse return 0;
        if (sig_mod.pendingFatal(cur_task)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(cur_task)) return -4; // -EINTR
    }
}

fn watchPoll(ctx: *const devfs.IoCtx) u32 {
    return if (devfs.changeCounter() != ctx.offset) devfs.POLL_IN else 0;
}

const watch_node_ops: devfs.NodeOps = .{
    .read = watchRead,
    .poll = watchPoll,
    .flags = .{ .no_pread = true },
};
