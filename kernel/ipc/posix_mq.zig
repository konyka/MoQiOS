/// POSIX Message Queues implementation.
///
/// Provides mq_open, mq_unlink, mq_timedsend, mq_timedreceive, mq_notify, mq_getsetattr.
/// Messages are stored in a ring buffer per queue. Max 16 queues, 8 messages per queue.
const serial = @import("../arch/arch.zig").serial;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const str = @import("../lib/str.zig");
const bo = @import("../lib/byte_order.zig");
const copy = @import("../mm/copy_from_user.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const time_policy = @import("time_policy.zig");
const mq_timeout_policy = @import("posix_mq_policy.zig");
const attr_policy = @import("posix_mq_attr_policy.zig");
const receive_policy = @import("posix_mq_receive_policy.zig");
const priority_policy = @import("posix_mq_priority_policy.zig");
const owner_gen_policy = @import("owner_gen_policy.zig");
const wait_policy = @import("posix_mq_wait_policy.zig");
const descriptor_policy = @import("posix_mq_descriptor_policy.zig");

const MAX_QUEUES: u32 = 16;
const MAX_MSGS: u32 = 8;
const MAX_MSG_SIZE: u32 = 512;
const MAX_NAME_LEN: u32 = 64;
const MAX_OPEN_DESCRIPTIONS: u32 = 256;
const MAX_TASK_MQ_DESCRIPTORS: u32 = descriptor_policy.MAX_DESCRIPTORS;

/// POSIX message buffer
const MsgEntry = struct {
    data: [MAX_MSG_SIZE]u8 = @splat(0),
    len: u32 = 0,
    priority: u32 = 0,
    used: bool = false,
    reserved: bool = false,
};

/// POSIX message queue
pub const MqQueue = struct {
    active: bool = false,
    name: [MAX_NAME_LEN]u8 = @splat(0),
    name_len: u32 = 0,
    /// Ring buffer of messages
    msgs: [MAX_MSGS]MsgEntry = @splat(.{}),
    head: u32 = 0, // next read position
    tail: u32 = 0, // next write position
    count: u32 = 0,
    /// Queue attributes
    max_msg: u32 = MAX_MSGS,
    msg_size: u32 = MAX_MSG_SIZE,
    /// Marked for removal (mq_unlink)
    marked_removed: bool = false,
    /// Open references (mq_open). The slot is freed only when an unlinked,
    /// drained queue's last reference is dropped via mq_close.
    open_count: u32 = 0,
    /// Notification registered (pid of notifier, 0 = none)
    notify_pid: u32 = 0,
    /// Task that registered mq_notify, and the requested signal number
    /// (delivered once when a message arrives on an empty queue).
    notify_task_idx: ?u32 = null,
    /// Tid of the registering task — a slot INDEX alone aliases after the
    /// registrant exits and its slot is recycled; the tid match proves
    /// identity at delivery time.
    notify_tid: u32 = 0,
    notify_signo: i32 = 0,
    /// Senders blocked on a full queue (mq_timedsend without O_NONBLOCK)
    send_waiters: ?*task.MqWaiter = null,
    send_waiters_tail: ?*task.MqWaiter = null,
    /// Receivers blocked on an empty queue (mq_timedreceive without O_NONBLOCK)
    recv_waiters: ?*task.MqWaiter = null,
    recv_waiters_tail: ?*task.MqWaiter = null,
};

var queues: [MAX_QUEUES]MqQueue = @splat(.{});
var queue_generations: [MAX_QUEUES]u64 = @splat(0);
var mq_lock: IrqSpinlock = .{};

const OpenDescription = struct {
    active: bool = false,
    queue_idx: u32 = 0,
    queue_generation: u64 = 0,
    description_generation: u64 = 0,
    access: u32 = descriptor_policy.O_RDONLY,
    status_flags: u32 = 0,
    cloexec: bool = false,
    refs: u32 = 0,
};

const TaskHandle = struct {
    desc_idx: u32 = 0,
    desc_generation: u64 = 0,
    open: bool = false,
};

var descriptions: [MAX_OPEN_DESCRIPTIONS]OpenDescription = @splat(.{});
var description_generations: [MAX_OPEN_DESCRIPTIONS]u64 = @splat(0);
var task_handles: [task.MAX_TASKS][MAX_TASK_MQ_DESCRIPTORS]TaskHandle = @splat(@splat(.{}));

// ── O_* flags ──
const O_RDONLY = descriptor_policy.O_RDONLY;
const O_WRONLY = descriptor_policy.O_WRONLY;
const O_RDWR = descriptor_policy.O_RDWR;
const O_CREAT = descriptor_policy.O_CREAT;
const O_EXCL = descriptor_policy.O_EXCL;
const O_NONBLOCK = descriptor_policy.O_NONBLOCK;
const O_CLOEXEC = descriptor_policy.O_CLOEXEC;

// ── Error codes ──
const errno = @import("../lib/errno.zig");
const ENOENT = errno.ENOENT;
const EINVAL = errno.EINVAL;
const EEXIST = errno.EEXIST;
const ENOSPC = errno.ENOSPC;
const EAGAIN = errno.EAGAIN;
const EMFILE = errno.EMFILE;
const EBADF = errno.EBADF;
const EFAULT = errno.EFAULT;
const EACCES = errno.EACCES;
const EINTR = errno.EINTR;
const ETIMEDOUT = errno.ETIMEDOUT;
const EMSGSIZE = errno.EMSGSIZE;

/// Linux timespec for timeout reading.
const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Read absolute timeout from user space, return absolute time in nanoseconds.
/// Returns 0 if timeout_ptr is NULL or invalid (caller should treat as no timeout).
fn readAbsTimeout(timeout_ptr: u64) error{ Fault, Invalid }!mq_timeout_policy.Timeout {
    if (timeout_ptr == 0) return .none;
    if (timeout_ptr >= 0x0000_8000_0000_0000) return error.Fault;
    var ts_buf: [@sizeOf(Timespec)]u8 = undefined;
    if (copy.copyFromUser(&ts_buf, @ptrFromInt(timeout_ptr), @sizeOf(Timespec)) != @sizeOf(Timespec)) {
        return error.Fault;
    }
    const ts: *const Timespec = @ptrCast(@alignCast(&ts_buf));
    const deadline = time_policy.timespecToNs(ts.tv_sec, ts.tv_nsec) orelse return error.Invalid;
    return mq_timeout_policy.fromNanoseconds(true, deadline);
}

fn deadlineNs(timeout: mq_timeout_policy.Timeout) ?u64 {
    return switch (timeout) {
        .none => null,
        .deadline => |value| value,
    };
}

/// Check if the supplied absolute timeout has expired.
fn isTimedOut(abs_timeout_ns: mq_timeout_policy.Timeout) bool {
    const deadline = deadlineNs(abs_timeout_ns) orelse return false;
    const tsc = @import("../arch/arch.zig").tsc;
    return tsc.nanos() >= deadline;
}

// ── Timed waits (abs_timeout) ──
// A timed mq wait on an idle queue has no wake source, so the deadline was
// previously only observed on an unrelated wake — the task could sleep past
// it. Same fix as futex.zig: per-task deadline + bitmap, scanned by
// timerTick from the BSP maintenance tick (sched.zig).
var wait_deadlines: [task.MAX_TASKS]u64 = @splat(0);
var wait_incarnations: [task.MAX_TASKS]u64 = @splat(0);
var wait_queue_indices: [task.MAX_TASKS]u32 = @splat(0);
var wait_queue_generations: [task.MAX_TASKS]u64 = @splat(0);
var wait_directions: [task.MAX_TASKS]u8 = @splat(0);
var wait_generations: [task.MAX_TASKS]u64 = @splat(0);
pub var mq_wait_bm: u64 = 0;

/// Arm a timed-wait deadline. Called while enqueuing under mq_lock; the tick
/// only wakes (the waiter unlinks its own node on resume), so this is
/// race-free with the wait queues.
fn armWaitDeadline(task_idx: u32, deadline_ns: u64, incarnation: u64, queue_idx: u32, queue_generation: u64, direction: u8, waiter_generation: u64) void {
    wait_deadlines[task_idx] = deadline_ns;
    wait_incarnations[task_idx] = incarnation;
    wait_queue_indices[task_idx] = queue_idx;
    wait_queue_generations[task_idx] = queue_generation;
    wait_directions[task_idx] = direction;
    wait_generations[task_idx] = waiter_generation;
    _ = @atomicRmw(u64, &mq_wait_bm, .Or, @as(u64, 1) << @intCast(task_idx), .seq_cst);
}

/// Disarm a timed-wait deadline (woken, timed out, or wait abandoned).
fn disarmWaitDeadline(task_idx: u32) void {
    wait_deadlines[task_idx] = 0;
    wait_incarnations[task_idx] = 0;
    wait_queue_indices[task_idx] = 0;
    wait_queue_generations[task_idx] = 0;
    wait_directions[task_idx] = 0;
    wait_generations[task_idx] = 0;
    _ = @atomicRmw(u64, &mq_wait_bm, .And, ~(@as(u64, 1) << @intCast(task_idx)), .seq_cst);
}

fn disarmWaitDeadlineIfToken(task_idx: u32, deadline_ns: u64, incarnation: u64, queue_idx: u32, queue_generation: u64, direction: u8, waiter_generation: u64) bool {
    if (!@import("posix_mq_policy.zig").deadlineTokenMatches(
        deadline_ns,
        incarnation,
        wait_deadlines[task_idx],
        wait_incarnations[task_idx],
    )) return false;
    if (wait_queue_indices[task_idx] != queue_idx or wait_queue_generations[task_idx] != queue_generation or
        wait_directions[task_idx] != direction or wait_generations[task_idx] != waiter_generation) return false;
    disarmWaitDeadline(task_idx);
    return true;
}

/// Drive timed mq waits. Called from the BSP maintenance tick (sched.zig,
/// alongside futex.timerTick). Wakes expired waiters; the woken waiter
/// re-checks isTimedOut from the top of its loop and returns ETIMEDOUT.
pub fn timerTick(now_ns: u64) void {
    var bm = @atomicLoad(u64, &mq_wait_bm, .acquire);
    while (bm != 0) {
        const i: u6 = @truncate(@ctz(bm));
        bm &= bm - 1;
        const idx: u32 = i;
        const deadline = wait_deadlines[idx];
        const incarnation = wait_incarnations[idx];
        const queue_idx = wait_queue_indices[idx];
        const queue_generation = wait_queue_generations[idx];
        const direction = wait_directions[idx];
        const waiter_generation = wait_generations[idx];
        if (now_ns < deadline) continue;
        const flags = mq_lock.acquire();
        if (!disarmWaitDeadlineIfToken(idx, deadline, incarnation, queue_idx, queue_generation, direction, waiter_generation)) {
            mq_lock.release(flags);
            continue;
        }
        var wake: ?WakeToken = null;
        if (idx < task.MAX_TASKS) {
            const t = task.getTask(idx);
            if (t != null and t.?.mq_waiter.task_incarnation == incarnation and
                t.?.mq_waiter.waiter_generation == waiter_generation and
                t.?.mq_waiter.queue_idx == queue_idx and t.?.mq_waiter.queue_generation == queue_generation and
                t.?.mq_waiter.direction == direction)
            {
                const q = if (queue_idx < MAX_QUEUES) &queues[queue_idx] else null;
                if (q != null and q.?.active and queue_generations[queue_idx] == queue_generation) {
                    const w = &t.?.mq_waiter;
                    if (claimAndDetach(q.?, w, direction, .timed_out)) wake = .{ .idx = idx, .incarnation = incarnation };
                }
            }
        }
        mq_lock.release(flags);
        if (wake) |token| wakeTask(token);
    }
}

const WakeToken = struct { idx: u32, incarnation: u64 };
const WakeBatch = struct {
    tokens: [task.MAX_TASKS]WakeToken = undefined,
    count: u32 = 0,

    fn add(self: *WakeBatch, token: WakeToken) void {
        if (self.count < task.MAX_TASKS) {
            self.tokens[self.count] = token;
            self.count += 1;
        }
    }

    fn wake(self: *WakeBatch) void {
        for (self.tokens[0..self.count]) |token| wakeTask(token);
    }
};

fn wakeTask(token: WakeToken) void {
    if (task.pinTaskByIndex(token.idx, true)) |pin_value| {
        var pin = pin_value;
        defer pin.release();
        if (pin.incarnation == token.incarnation) task.unblockTaskIfIncarnation(token.idx, pin.tid, token.incarnation);
    }
}

fn cancelQueueWaiters(q: *MqQueue, wakes: *WakeBatch) void {
    while (q.send_waiters) |waiter| {
        if (claimAndDetach(q, waiter, 0, .cancelled))
            wakes.add(.{ .idx = waiter.task_idx, .incarnation = waiter.task_incarnation });
    }
    while (q.recv_waiters) |waiter| {
        if (claimAndDetach(q, waiter, 1, .cancelled))
            wakes.add(.{ .idx = waiter.task_idx, .incarnation = waiter.task_incarnation });
    }
}

fn waiterList(direction: u8, q: *MqQueue) struct { head: *?*task.MqWaiter, tail: *?*task.MqWaiter } {
    return if (direction == 0) .{ .head = &q.send_waiters, .tail = &q.send_waiters_tail } else .{ .head = &q.recv_waiters, .tail = &q.recv_waiters_tail };
}

fn enqueueWaiter(q: *MqQueue, waiter: *task.MqWaiter, direction: u8) void {
    const list = waiterList(direction, q);
    waiter.prev = list.tail.*;
    waiter.next = null;
    waiter.linked = true;
    if (list.tail.*) |tail| tail.next = waiter else list.head.* = waiter;
    list.tail.* = waiter;
}

fn claimAndDetach(q: *MqQueue, waiter: *task.MqWaiter, direction: u8, terminal: wait_policy.Terminal) bool {
    if (waiter.terminal != @intFromEnum(wait_policy.Terminal.queued)) return false;
    const list = waiterList(direction, q);
    if (waiter.prev) |prev| prev.next = waiter.next else list.head.* = waiter.next;
    if (waiter.next) |next| next.prev = waiter.prev else list.tail.* = waiter.prev;
    waiter.prev = null;
    waiter.next = null;
    waiter.linked = false;
    waiter.terminal = @intFromEnum(terminal);
    return true;
}

/// Free a queue slot, waking any blocked senders/receivers first so they
/// re-check and see the queue gone (EBADF) instead of sleeping forever.
/// Caller holds mq_lock.
fn freeQueue(q: *MqQueue, wakes: *WakeBatch) void {
    while (q.send_waiters) |waiter| {
        _ = claimAndDetach(q, waiter, 0, .cancelled);
        wakes.add(.{ .idx = waiter.task_idx, .incarnation = waiter.task_incarnation });
    }
    while (q.recv_waiters) |waiter| {
        _ = claimAndDetach(q, waiter, 1, .cancelled);
        wakes.add(.{ .idx = waiter.task_idx, .incarnation = waiter.task_incarnation });
    }
    q.send_waiters_tail = null;
    q.recv_waiters_tail = null;
    queue_generations[qIndex(q)] +%= 1;
    if (queue_generations[qIndex(q)] == 0) queue_generations[qIndex(q)] = 1;
    q.* = .{};
}

/// Detach the current task's MQ waiter before any close/reap operation.
/// This function deliberately owns only mq_lock; exitTask calls it after
/// releasing task_lock to avoid the task_lock -> mq_lock inversion.
pub fn detachWaiterForTask(task_idx: u32) void {
    if (task_idx >= task.MAX_TASKS) return;
    var wake: ?WakeToken = null;
    const flags = mq_lock.acquire();
    if (task.getTask(task_idx)) |t| {
        const waiter = &t.mq_waiter;
        if (waiter.linked and waiter.task_idx == task_idx) {
            const q_idx = waiter.queue_idx;
            const q_gen = waiter.queue_generation;
            const direction = waiter.direction;
            if (q_idx < MAX_QUEUES and queues[q_idx].active and queue_generations[q_idx] == q_gen) {
                if (claimAndDetach(&queues[q_idx], waiter, direction, .cancelled)) {
                    wake = .{ .idx = task_idx, .incarnation = waiter.task_incarnation };
                }
            } else {
                waiter.linked = false;
                waiter.prev = null;
                waiter.next = null;
                waiter.terminal = @intFromEnum(wait_policy.Terminal.cancelled);
            }
            disarmWaitDeadline(task_idx);
        }
    }
    mq_lock.release(flags);
    if (wake) |token| wakeTask(token);
}

fn qIndex(q: *MqQueue) u32 {
    return @intCast(@divExact(@intFromPtr(q) - @intFromPtr(&queues[0]), @sizeOf(MqQueue)));
}

fn queueIndex(q: *MqQueue) u32 {
    return qIndex(q);
}

fn wakeHead(q: *MqQueue, direction: u8) ?WakeToken {
    const list = waiterList(direction, q);
    while (list.head.*) |waiter| {
        const token = WakeToken{ .idx = waiter.task_idx, .incarnation = waiter.task_incarnation };
        if (claimAndDetach(q, waiter, direction, .woken)) return token;
        if (waiter.linked) _ = claimAndDetach(q, waiter, direction, .cancelled);
    }
    return null;
}

/// mq_open(name, oflag, mode, attr) -> fd or -errno
/// rdi=name, rsi=oflag, rdx=mode, r10=attr
pub fn mqOpen(name_ptr: u64, oflag: u32, mode: u32, attr_ptr: u64) i64 {
    _ = mode;

    // Read name and attributes BEFORE taking mq_lock: user copies walk page
    // tables and must not run with IRQs off. Linux struct mq_attr is four
    // 8-byte longs: mq_flags@0, mq_maxmsg@8, mq_msgsize@16, mq_curmsgs@24.
    var name_buf: [MAX_NAME_LEN]u8 = @splat(0);
    const name_len: u32 = @intCast(readUserString(name_ptr, &name_buf));
    if (name_len == 0) return EINVAL;
    if (!descriptor_policy.flagsValid(oflag)) return EINVAL;
    const owner_idx = sched.currentTaskIndex() orelse return EBADF;

    var maxmsg: i64 = 0;
    var msgsize: i64 = 0;
    const create_requested = oflag & O_CREAT != 0;
    if (create_requested and attr_ptr != 0) {
        if (attr_ptr >= 0x0000_8000_0000_0000) return EFAULT;
        var attr_buf: [32]u8 = undefined;
        if (copy.copyFromUser(&attr_buf, @ptrFromInt(attr_ptr), 32) != 32) return EFAULT;
        maxmsg = bo.readI64Le(attr_buf[8..16]);
        msgsize = bo.readI64Le(attr_buf[16..24]);
    }
    if (attr_policy.validate(create_requested, attr_ptr != 0, maxmsg, msgsize, MAX_MSGS, MAX_MSG_SIZE) == .invalid) {
        return EINVAL;
    }

    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    // Search for existing queue with this name
    for (&queues, 0..) |*q, queue_idx| {
        if (q.active and !q.marked_removed and str.eql(q.name[0..q.name_len], name_buf[0..name_len])) {
            if (oflag & O_CREAT != 0 and oflag & O_EXCL != 0) {
                return EEXIST;
            }
            return openDescription(@intCast(queue_idx), q, owner_idx, oflag);
        }
    }

    // Need to create
    if (oflag & O_CREAT == 0) {
        return ENOENT;
    }

    // Find free slot
    var slot: ?u32 = null;
    for (0..MAX_QUEUES) |i| {
        if (!queues[i].active) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot == null) return ENOSPC;

    const idx = slot.?;
    var q = &queues[idx];
    queue_generations[idx] +%= 1;
    if (queue_generations[idx] == 0) queue_generations[idx] = 1;

    @memset(&q.name, 0);
    for (0..name_len) |j| q.name[j] = name_buf[j];
    q.name_len = name_len;
    q.active = true;
    q.head = 0;
    q.tail = 0;
    q.count = 0;
    q.marked_removed = false;
    q.open_count = 0;
    q.notify_pid = 0;
    q.notify_task_idx = null;
    q.notify_tid = 0;
    q.notify_signo = 0;

    // Apply optional attributes (only honored at creation)
    if (create_requested and attr_ptr != 0) {
        q.max_msg = @intCast(maxmsg);
        q.msg_size = @intCast(msgsize);
    }

    serial.writeString("[posix_mq] created mq=");
    serial.writeString(q.name[0..q.name_len]);
    serial.writeString("\n");

    const opened = openDescription(idx, q, owner_idx, oflag);
    if (opened < 0) {
        var wakes = WakeBatch{};
        freeQueue(q, &wakes);
    }
    return opened;
}

/// mq_unlink(name) -> 0 or -errno
/// rdi=name
pub fn mqUnlink(name_ptr: u64) i64 {
    // Read name before taking mq_lock (see mqOpen).
    var name_buf: [MAX_NAME_LEN]u8 = @splat(0);
    const name_len: u32 = @intCast(readUserString(name_ptr, &name_buf));
    if (name_len == 0) return EINVAL;

    const flags = mq_lock.acquire();

    for (&queues) |*q| {
        if (q.active and str.eql(q.name[0..q.name_len], name_buf[0..name_len])) {
            serial.writeString("[posix_mq] unlink mq=");
            serial.writeString(q.name[0..q.name_len]);
            serial.writeString("\n");
            q.marked_removed = true;
            // Free only once the queue is drained AND the last open reference
            // is gone (mq_close) — an unlinked-but-open queue stays usable.
            if (q.count == 0 and q.open_count == 0) {
                var wakes = WakeBatch{};
                freeQueue(q, &wakes);
                mq_lock.release(flags);
                wakes.wake();
                return 0;
            }
            var wakes = WakeBatch{};
            cancelQueueWaiters(q, &wakes);
            mq_lock.release(flags);
            wakes.wake();
            return 0;
        }
    }
    mq_lock.release(flags);
    return ENOENT;
}

/// mq_timedsend(mqd, msg_ptr, msg_len, msg_prio, abs_timeout) -> 0 or -errno
/// rdi=mqd, rsi=msg_ptr, rdx=msg_len, r10=msg_prio, r8=abs_timeout
pub fn mqTimedSend(mqd: u32, msg_ptr: u64, msg_len: u64, msg_prio: u32, timeout_ptr: u64) i64 {
    const owner_idx = sched.currentTaskIndex() orelse return EBADF;
    // Read timeout before acquiring lock
    const abs_timeout_ns = readAbsTimeout(timeout_ptr) catch |err| return switch (err) {
        error.Fault => EFAULT,
        error.Invalid => EINVAL,
    };

    // Try to send, blocking on the send wait queue if the queue is full
    while (true) {
        const flags = mq_lock.acquire();

        const desc = findDescription(owner_idx, mqd) orelse {
            mq_lock.release(flags);
            return EBADF;
        };
        const q = &queues[desc.queue_idx];
        if (!descriptor_policy.accessAllows(desc.access, .send)) {
            mq_lock.release(flags);
            return EACCES;
        }

        if (msg_len > q.msg_size) {
            mq_lock.release(flags);
            return EMSGSIZE;
        }

        if (q.count >= q.max_msg) {
            if (desc.status_flags & O_NONBLOCK != 0) {
                mq_lock.release(flags);
                return EAGAIN;
            }
            // Check timeout before blocking
            if (isTimedOut(abs_timeout_ns)) {
                mq_lock.release(flags);
                return ETIMEDOUT;
            }
            // Block until a receiver frees a slot (or mq_unlink wakes us).
            // Enqueue while holding mq_lock so a concurrent mq_timedreceive
            // can't wakeOne before we join the queue (lost wakeup) — the
            // sysv_sem.semop pattern.
            const cur_idx = sched.currentTaskIndex() orelse {
                mq_lock.release(flags);
                return EAGAIN; // kernel thread: cannot block
            };
            var cur_pin = task.pinTaskByIndex(cur_idx, false) orelse {
                mq_lock.release(flags);
                return EAGAIN;
            };
            const waiter = &cur_pin.task.mq_waiter;
            if (waiter.linked) {
                mq_lock.release(flags);
                cur_pin.release();
                return EAGAIN;
            }
            cur_pin.task.mq_waiter_generation +%= 1;
            if (cur_pin.task.mq_waiter_generation == 0) cur_pin.task.mq_waiter_generation = 1;
            waiter.* = .{ .task_idx = cur_idx, .task_incarnation = cur_pin.incarnation, .queue_idx = queueIndex(q), .queue_generation = queue_generations[queueIndex(q)], .direction = 0, .waiter_generation = cur_pin.task.mq_waiter_generation };
            enqueueWaiter(q, waiter, 0);
            if (deadlineNs(abs_timeout_ns)) |deadline| armWaitDeadline(cur_idx, deadline, cur_pin.incarnation, waiter.queue_idx, waiter.queue_generation, waiter.direction, waiter.waiter_generation);
            cur_pin.task.state = .blocked;
            mq_lock.release(flags);
            sched.forceReschedule();
            sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）
            if (deadlineNs(abs_timeout_ns) != null) disarmWaitDeadline(cur_idx);
            const flags2 = mq_lock.acquire();
            if (waiter.linked) _ = claimAndDetach(&queues[waiter.queue_idx], waiter, 0, .cancelled);
            mq_lock.release(flags2);
            // Signal kick (sendSignal unblocks without granting): die on a
            // fatal signal, or EINTR so the handler can run on return.
            const sig_mod = @import("../proc/signal.zig");
            const fatal = sig_mod.pendingFatal(cur_pin.task);
            const actionable = sig_mod.pendingActionable(cur_pin.task);
            cur_pin.release();
            if (fatal) |sig| task.exitTask(128 + @as(i32, @intCast(sig)));
            if (actionable) return EINTR;
            continue;
        }

        // Space available — send message
        var send_slots: [MAX_MSGS]priority_policy.Slot = @splat(.{});
        for (&send_slots, 0..) |*slot, i| {
            slot.used = q.msgs[i].used and !q.msgs[i].reserved;
            slot.priority = q.msgs[i].priority;
        }
        const send_idx = priority_policy.nextFree(&send_slots, q.tail) orelse {
            mq_lock.release(flags);
            return EAGAIN;
        };
        const copy_len: usize = if (msg_len > MAX_MSG_SIZE) MAX_MSG_SIZE else @intCast(msg_len);
        q.msgs[send_idx].reserved = true;
        mq_lock.release(flags);

        var payload: [MAX_MSG_SIZE]u8 = undefined;
        const copied = copy.copyFromUser(payload[0..copy_len], @ptrFromInt(msg_ptr), copy_len);

        const commit_flags = mq_lock.acquire();
        const commit_q = findQueueForDescription(owner_idx, mqd);
        if (commit_q == null or !commit_q.?.msgs[send_idx].reserved) {
            mq_lock.release(commit_flags);
            return EAGAIN;
        }
        if (copied != copy_len) {
            commit_q.?.msgs[send_idx].reserved = false;
            mq_lock.release(commit_flags);
            return EFAULT;
        }

        @memcpy(commit_q.?.msgs[send_idx].data[0..copy_len], payload[0..copy_len]);
        commit_q.?.msgs[send_idx].len = @intCast(copy_len);
        commit_q.?.msgs[send_idx].priority = msg_prio;
        commit_q.?.msgs[send_idx].used = true;
        commit_q.?.msgs[send_idx].reserved = false;
        commit_q.?.tail = (send_idx + 1) % MAX_MSGS;
        commit_q.?.count += 1;

        // mq_notify: a message arriving on an empty queue (with no blocked
        // receiver about to consume it) delivers the registered signal once;
        // Linux requires re-arming via another mq_notify.
        if (commit_q.?.count == 1 and commit_q.?.recv_waiters == null and commit_q.?.notify_task_idx != null) {
            const notify_idx = commit_q.?.notify_task_idx.?;
            const notify_tid = commit_q.?.notify_tid;
            const notify_signo = commit_q.?.notify_signo;
            commit_q.?.notify_pid = 0;
            commit_q.?.notify_task_idx = null;
            commit_q.?.notify_tid = 0;
            commit_q.?.notify_signo = 0;
            if (notify_signo > 0 and notify_signo < 32) {
                if (task.getTask(notify_idx)) |nt| {
                    // The slot may have been recycled after the registrant
                    // exited — only signal if the tid still matches.
                    if (owner_gen_policy.ownerMatches(notify_tid, nt.tid)) {
                        _ = @atomicRmw(u32, &nt.pending_signals, .Or, @as(u32, 1) << @as(u5, @intCast(notify_signo - 1)), .seq_cst);
                        @import("../proc/signal.zig").kickIfBlocked(notify_idx);
                    }
                }
            }
        }

        // Wake a receiver blocked on the empty queue
        const wake = wakeHead(commit_q.?, 1);

        mq_lock.release(commit_flags);
        if (wake) |token| wakeTask(token);
        return 0;
    }
}

/// mq_timedreceive(mqd, msg_ptr, msg_len, msg_prio, abs_timeout) -> bytes or -errno
/// rdi=mqd, rsi=msg_ptr, rdx=msg_len, r10=msg_prio, r8=abs_timeout
pub fn mqTimedReceive(mqd: u32, msg_ptr: u64, msg_len: u64, prio_ptr: u64, timeout_ptr: u64) i64 {
    const owner_idx = sched.currentTaskIndex() orelse return EBADF;
    if (prio_ptr != 0 and !copy.validateUserBufferWritable(prio_ptr, 4)) return EFAULT;
    // Read timeout before acquiring lock
    const abs_timeout_ns = readAbsTimeout(timeout_ptr) catch |err| return switch (err) {
        error.Fault => EFAULT,
        error.Invalid => EINVAL,
    };

    // Try to receive, blocking on the receive wait queue if the queue is empty
    while (true) {
        const flags = mq_lock.acquire();

        const desc = findDescription(owner_idx, mqd) orelse {
            mq_lock.release(flags);
            return EBADF;
        };
        const q = &queues[desc.queue_idx];
        if (!descriptor_policy.accessAllows(desc.access, .receive)) {
            mq_lock.release(flags);
            return EACCES;
        }

        if (q.count == 0) {
            if (desc.status_flags & O_NONBLOCK != 0) {
                mq_lock.release(flags);
                return EAGAIN;
            }
            // Check timeout before blocking
            if (isTimedOut(abs_timeout_ns)) {
                mq_lock.release(flags);
                return ETIMEDOUT;
            }
            // Block until a sender posts a message (or mq_unlink wakes us).
            // Enqueue under mq_lock to avoid a lost wakeup (sysv_sem pattern).
            const cur_idx = sched.currentTaskIndex() orelse {
                mq_lock.release(flags);
                return EAGAIN; // kernel thread: cannot block
            };
            var cur_pin = task.pinTaskByIndex(cur_idx, false) orelse {
                mq_lock.release(flags);
                return EAGAIN;
            };
            const waiter = &cur_pin.task.mq_waiter;
            if (waiter.linked) {
                mq_lock.release(flags);
                cur_pin.release();
                return EAGAIN;
            }
            cur_pin.task.mq_waiter_generation +%= 1;
            if (cur_pin.task.mq_waiter_generation == 0) cur_pin.task.mq_waiter_generation = 1;
            waiter.* = .{ .task_idx = cur_idx, .task_incarnation = cur_pin.incarnation, .queue_idx = queueIndex(q), .queue_generation = queue_generations[queueIndex(q)], .direction = 1, .waiter_generation = cur_pin.task.mq_waiter_generation };
            enqueueWaiter(q, waiter, 1);
            if (deadlineNs(abs_timeout_ns)) |deadline| armWaitDeadline(cur_idx, deadline, cur_pin.incarnation, waiter.queue_idx, waiter.queue_generation, waiter.direction, waiter.waiter_generation);
            cur_pin.task.state = .blocked;
            mq_lock.release(flags);
            sched.forceReschedule();
            sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）
            if (deadlineNs(abs_timeout_ns) != null) disarmWaitDeadline(cur_idx);
            const flags2 = mq_lock.acquire();
            if (waiter.linked) _ = claimAndDetach(&queues[waiter.queue_idx], waiter, 1, .cancelled);
            mq_lock.release(flags2);
            // Signal kick: die on a fatal signal, or EINTR (see mqTimedSend).
            const sig_mod = @import("../proc/signal.zig");
            const fatal = sig_mod.pendingFatal(cur_pin.task);
            const actionable = sig_mod.pendingActionable(cur_pin.task);
            cur_pin.release();
            if (fatal) |sig| task.exitTask(128 + @as(i32, @intCast(sig)));
            if (actionable) return EINTR;
            continue;
        }

        // Message available — receive it
        var priority_slots: [MAX_MSGS]priority_policy.Slot = @splat(.{});
        for (&priority_slots, 0..) |*slot, i| {
            slot.used = q.msgs[i].used and !q.msgs[i].reserved;
            slot.priority = q.msgs[i].priority;
        }
        const selected_idx = priority_policy.selectHighest(&priority_slots, q.head) orelse {
            mq_lock.release(flags);
            return EAGAIN;
        };
        var msg = &q.msgs[selected_idx];
        if (!receive_policy.bufferAcceptsMessage(msg_len, msg.len)) {
            mq_lock.release(flags);
            return EMSGSIZE;
        }
        const out_len: usize = @intCast(msg.len);
        var payload: [MAX_MSG_SIZE]u8 = undefined;
        @memcpy(payload[0..out_len], msg.data[0..out_len]);
        const priority = msg.priority;
        msg.reserved = true;
        mq_lock.release(flags);

        const payload_written = copy.copyToUser(@ptrFromInt(msg_ptr), payload[0..out_len], out_len);
        var prio_written: usize = 4;
        if (payload_written == out_len and prio_ptr != 0) {
            var prio_buf: [4]u8 = undefined;
            prio_buf[0] = @intCast(priority & 0xFF);
            prio_buf[1] = @intCast((priority >> 8) & 0xFF);
            prio_buf[2] = @intCast((priority >> 16) & 0xFF);
            prio_buf[3] = @intCast((priority >> 24) & 0xFF);
            prio_written = copy.copyToUser(@ptrFromInt(prio_ptr), &prio_buf, 4);
        }
        const commit_flags = mq_lock.acquire();
        const commit_q = findQueueForDescription(owner_idx, mqd);
        if (commit_q == null or !commit_q.?.msgs[selected_idx].reserved) {
            mq_lock.release(commit_flags);
            return EAGAIN;
        }
        if (payload_written != out_len or prio_written != 4) {
            commit_q.?.msgs[selected_idx].reserved = false;
            mq_lock.release(commit_flags);
            return EFAULT;
        }
        const result_len: i64 = @intCast(out_len);

        // Free slot
        commit_q.?.msgs[selected_idx].used = false;
        commit_q.?.msgs[selected_idx].reserved = false;
        commit_q.?.msgs[selected_idx].len = 0;
        commit_q.?.count -= 1;
        commit_q.?.head = (selected_idx + 1) % MAX_MSGS;
        while (!commit_q.?.msgs[commit_q.?.head].used and commit_q.?.count > 0) {
            commit_q.?.head = (commit_q.?.head + 1) % MAX_MSGS;
        }

        // Wake a sender blocked on the full queue
        const wake = wakeHead(commit_q.?, 0);

        // If queue was marked for removal and now empty and fully closed,
        // free it
        if (commit_q.?.marked_removed and commit_q.?.count == 0 and commit_q.?.open_count == 0) {
            var wakes = WakeBatch{};
            freeQueue(commit_q.?, &wakes);
            mq_lock.release(commit_flags);
            if (wake) |token| wakeTask(token);
            wakes.wake();
            return result_len;
        }

        mq_lock.release(commit_flags);
        if (wake) |token| wakeTask(token);
        return result_len;
    }
}

/// mq_notify(mqd, notification) -> 0 or -errno
/// rdi=mqd, rsi=notification (sigevent struct pointer, or NULL to unregister)
/// Registers the calling task; the requested signal (sigev_signo @ offset 8)
/// is delivered once when a message arrives on an empty queue.
pub fn mqNotify(mqd: u32, notif_ptr: u64) i64 {
    const owner_idx = sched.currentTaskIndex() orelse return EBADF;
    // Read sigev_signo/sigev_notify before taking mq_lock (user copies walk
    // page tables). Layout matches posix_timer.Sigevent: value@0, signo@8,
    // notify@12.
    var signo: i32 = 0;
    if (notif_ptr != 0) {
        if (notif_ptr >= 0x0000_8000_0000_0000) return EFAULT;
        var buf: [16]u8 = undefined;
        if (copy.copyFromUser(&buf, @ptrFromInt(notif_ptr), 16) != 16) return EFAULT;
        signo = @bitCast(bo.readU32Le(buf[8..12]));
        const notify_kind = bo.readU32Le(buf[12..16]);
        if (!descriptor_policy.sigevNotifyValid(notify_kind)) return EINVAL;
        if (signo <= 0 or signo > 31) return EINVAL;
    }

    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    const q = findQueueForDescription(owner_idx, mqd) orelse return EBADF;

    if (notif_ptr == 0) {
        // Unregister notification
        q.notify_pid = 0;
        q.notify_task_idx = null;
        q.notify_tid = 0;
        q.notify_signo = 0;
        return 0;
    }

    if (q.notify_task_idx != null) return -16; // EBUSY

    // Register: one-shot, re-armed by another mq_notify after delivery.
    q.notify_pid = 1;
    q.notify_task_idx = sched.currentTaskIndex();
    q.notify_tid = if (sched.currentTaskIndex()) |ci|
        (if (task.getTask(ci)) |ct| ct.tid else 0)
    else
        0;
    q.notify_signo = signo;
    return 0;
}

/// Clear every mq_notify registration made by `task_idx`. Called from
/// task.exitTask so an exited task's registration can't signal an unrelated
/// task after its slot is recycled.
pub fn clearNotifyForTask(task_idx: u32) void {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    for (&queues) |*q| {
        if (q.active and q.notify_task_idx != null and q.notify_task_idx.? == task_idx) {
            q.notify_pid = 0;
            q.notify_task_idx = null;
            q.notify_tid = 0;
            q.notify_signo = 0;
        }
    }
}

/// mq_close(mqd) -> 0 or -errno.
/// mq descriptors live outside the per-task fd table (300+), so FdTable.close
/// routes fds >= MAX_FDS here. Drops the queue's open refcount; a
/// fully-closed, unlinked, drained queue frees its slot.
pub fn mqClose(mqd: u32) i64 {
    const flags = mq_lock.acquire();

    const owner_idx = sched.currentTaskIndex() orelse {
        mq_lock.release(flags);
        return EBADF;
    };
    const handle = descriptorHandle(owner_idx, mqd) orelse {
        mq_lock.release(flags);
        return EBADF;
    };
    const desc = &descriptions[handle.desc_idx];
    if (!desc.active or description_generations[handle.desc_idx] != handle.desc_generation) {
        mq_lock.release(flags);
        return EBADF;
    }
    var wakes = WakeBatch{};
    closeHandleLocked(owner_idx, handle.handle_idx, &wakes);
    mq_lock.release(flags);
    wakes.wake();
    return 0;
}

/// Release all MQ references held by an exiting task. Called before the task
/// becomes a zombie so unlinked queues cannot retain dead open references.
pub fn closeRefsForTask(task_idx: u32) void {
    if (task_idx >= task.MAX_TASKS) return;
    var wakes = WakeBatch{};
    const flags = mq_lock.acquire();
    for (0..MAX_TASK_MQ_DESCRIPTORS) |handle_idx| {
        if (task_handles[task_idx][handle_idx].open) closeHandleLocked(task_idx, @intCast(handle_idx), &wakes);
    }
    mq_lock.release(flags);
    wakes.wake();
}

/// Fork duplicates every MQ reference held by the parent task.
pub fn inheritRefs(parent_idx: u32, child_idx: u32) void {
    if (parent_idx >= task.MAX_TASKS or child_idx >= task.MAX_TASKS) return;
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    for (0..MAX_TASK_MQ_DESCRIPTORS) |handle_idx| {
        const parent_handle = task_handles[parent_idx][handle_idx];
        if (!parent_handle.open) continue;
        const child_handle = &task_handles[child_idx][handle_idx];
        if (child_handle.open) continue;
        const desc = &descriptions[parent_handle.desc_idx];
        if (!desc.active or description_generations[parent_handle.desc_idx] != parent_handle.desc_generation) continue;
        child_handle.* = parent_handle;
        desc.refs += 1;
        queues[desc.queue_idx].open_count += 1;
    }
}

/// mq_getsetattr(mqd, newattr, oldattr) -> 0 or -errno
/// rdi=mqd, rsi=newattr, rdx=oldattr
/// Linux struct mq_attr is four 8-byte longs (32 bytes):
/// mq_flags@0, mq_maxmsg@8, mq_msgsize@16, mq_curmsgs@24.
pub fn mqGetSetAttr(mqd: u32, newattr_ptr: u64, oldattr_ptr: u64) i64 {
    const owner_idx = sched.currentTaskIndex() orelse return EBADF;
    if (oldattr_ptr != 0 and !copy.validateUserBufferWritable(oldattr_ptr, 32)) return EFAULT;
    if (newattr_ptr != 0 and newattr_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    var requested_flags: ?u32 = null;
    if (newattr_ptr != 0) {
        var new_buf: [32]u8 = undefined;
        if (copy.copyFromUser(&new_buf, @ptrFromInt(newattr_ptr), 32) != 32) return EFAULT;
        requested_flags = @truncate(@as(u64, @bitCast(bo.readI64Le(new_buf[0..8]))));
    }
    const flags = mq_lock.acquire();
    const handle = descriptorHandle(owner_idx, mqd) orelse {
        mq_lock.release(flags);
        return EBADF;
    };
    const desc = &descriptions[handle.desc_idx];
    const q = &queues[desc.queue_idx];

    var old_buf: [32]u8 = undefined;
    if (oldattr_ptr != 0) {
        old_buf = @splat(0);
        bo.writeI64Le(old_buf[0..8], desc.status_flags);
        bo.writeI64Le(old_buf[8..16], q.max_msg);
        bo.writeI64Le(old_buf[16..24], q.msg_size);
        bo.writeI64Le(old_buf[24..32], q.count);
    }
    if (requested_flags) |new_flags| desc.status_flags = (desc.status_flags & ~@as(u32, O_NONBLOCK)) | (new_flags & O_NONBLOCK);
    const old_flags = flags;
    mq_lock.release(old_flags);
    if (oldattr_ptr != 0 and copy.copyToUser(@ptrFromInt(oldattr_ptr), &old_buf, 32) != 32) return EFAULT;
    return 0;
}

// ── Internal descriptor helpers ──

const HandleRef = struct { handle_idx: u32, desc_idx: u32, desc_generation: u64 };
const Resolved = struct { queue: *MqQueue, description: *OpenDescription };

fn descriptorHandle(task_idx: u32, mqd: u32) ?HandleRef {
    const handle_idx = descriptor_policy.decodeToken(mqd) orelse return null;
    if (handle_idx >= MAX_TASK_MQ_DESCRIPTORS) return null;
    const handle = task_handles[task_idx][handle_idx];
    if (!handle.open or handle.desc_idx >= MAX_OPEN_DESCRIPTIONS) return null;
    const desc = descriptions[handle.desc_idx];
    if (!desc.active or description_generations[handle.desc_idx] != handle.desc_generation) return null;
    return .{ .handle_idx = handle_idx, .desc_idx = handle.desc_idx, .desc_generation = handle.desc_generation };
}

fn findDescription(task_idx: u32, mqd: u32) ?*OpenDescription {
    const ref = descriptorHandle(task_idx, mqd) orelse return null;
    return &descriptions[ref.desc_idx];
}

fn findQueueForDescription(task_idx: u32, mqd: u32) ?*MqQueue {
    const desc = findDescription(task_idx, mqd) orelse return null;
    if (desc.queue_idx >= MAX_QUEUES) return null;
    const q = &queues[desc.queue_idx];
    if (!q.active or queue_generations[desc.queue_idx] != desc.queue_generation) return null;
    return q;
}

fn openDescription(queue_idx: u32, q: *MqQueue, owner_idx: u32, oflag: u32) i64 {
    var handle_idx: ?u32 = null;
    for (0..MAX_TASK_MQ_DESCRIPTORS) |i| {
        if (!task_handles[owner_idx][i].open) {
            handle_idx = @intCast(i);
            break;
        }
    }
    const desc_idx = for (0..MAX_OPEN_DESCRIPTIONS) |i| {
        if (!descriptions[i].active) break @as(?u32, @intCast(i));
    } else null;
    if (handle_idx == null or desc_idx == null) return EMFILE;
    const di = desc_idx.?;
    description_generations[di] +%= 1;
    if (description_generations[di] == 0) description_generations[di] = 1;
    descriptions[di] = .{
        .active = true,
        .queue_idx = queue_idx,
        .queue_generation = queue_generations[queue_idx],
        .description_generation = description_generations[di],
        .access = oflag & descriptor_policy.O_ACCMODE,
        .status_flags = descriptor_policy.statusFlags(oflag),
        .cloexec = oflag & O_CLOEXEC != 0,
        .refs = 1,
    };
    task_handles[owner_idx][handle_idx.?] = .{ .desc_idx = di, .desc_generation = description_generations[di], .open = true };
    q.open_count += 1;
    return @intCast(descriptor_policy.tokenValue(handle_idx.?));
}

fn closeHandleLocked(task_idx: u32, handle_idx: u32, wakes: *WakeBatch) void {
    const handle = &task_handles[task_idx][handle_idx];
    if (!handle.open) return;
    const desc_idx = handle.desc_idx;
    const desc = &descriptions[desc_idx];
    handle.* = .{};
    if (desc.refs > 0) desc.refs -= 1;
    if (desc.refs == 0) {
        const q = &queues[desc.queue_idx];
        q.open_count -|= 1;
        if (q.marked_removed and q.open_count == 0) freeQueue(q, wakes);
        desc.* = .{};
    }
}

/// Close current-task MQ descriptions marked O_CLOEXEC before a new image runs.
pub fn closeCloexecForTask(task_idx: u32) void {
    if (task_idx >= task.MAX_TASKS) return;
    var wakes = WakeBatch{};
    const flags = mq_lock.acquire();
    for (0..MAX_TASK_MQ_DESCRIPTORS) |i| {
        const h = task_handles[task_idx][i];
        if (h.open and descriptions[h.desc_idx].cloexec) closeHandleLocked(task_idx, @intCast(i), &wakes);
    }
    mq_lock.release(flags);
    wakes.wake();
}

fn readUserString(user_ptr: u64, buf: []u8) usize {
    if (user_ptr == 0 or user_ptr >= 0x0000_8000_0000_0000) return 0;
    const max_len = buf.len;
    // Fast path: one bulk copy — a single page-table walk for the whole
    // range instead of one per byte.
    if (copy.copyFromUser(buf, @ptrFromInt(user_ptr), max_len) == max_len) {
        for (buf, 0..) |c, i| {
            if (c == 0) return i;
        }
        return max_len;
    }
    // The 64-byte range may run past the string into an unmapped page;
    // fall back to per-byte copies.
    var len: usize = 0;
    while (len < max_len) : (len += 1) {
        var byte: [1]u8 = .{0};
        if (copy.copyFromUser(&byte, @ptrFromInt(user_ptr + len), 1) != 1) return 0;
        if (byte[0] == 0) break;
        buf[len] = byte[0];
    }
    return len;
}
