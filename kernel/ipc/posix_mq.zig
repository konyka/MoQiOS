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
const wait_policy = @import("posix_mq_wait_policy.zig");
const descriptor_policy = @import("posix_mq_descriptor_policy.zig");
const vfs = @import("../fs/vfs.zig");

const MAX_QUEUES: u32 = 16;
const MAX_MSGS: u32 = 8;
const MAX_MSG_SIZE: u32 = 512;
const MAX_NAME_LEN: u32 = 64;
const MAX_OPEN_DESCRIPTIONS: u32 = 256;

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
    /// Owner and permission bits recorded at creation (like a file): mq_open
    /// checks them against the requested access, mq_unlink against the owner.
    uid: u32 = 0,
    gid: u32 = 0,
    mode: u32 = 0,
    /// Marked for removal (mq_unlink)
    marked_removed: bool = false,
    /// Open references (mq_open). The slot is freed only when an unlinked,
    /// drained queue's last reference is dropped via mq_close.
    open_count: u32 = 0,
    /// The process that registered mq_notify, by thread group id (0 = none), and the requested signal number (delivered once when a
    /// message arrives on an empty queue). Linux keeps task_tgid: the registration belongs to the process, not to the thread that
    /// made it. Tids are never reused, so the id names that process for as long as it lives.
    notify_tgid: u32 = 0,
    notify_signo: i32 = 0,
    /// sigev_value registered with mq_notify; delivered as si_value of the SI_MESGQ signal.
    notify_value: u64 = 0,
    /// sigev_notify (SIGEV_SIGNAL or SIGEV_NONE). SIGEV_NONE is a real registration that sends nothing.
    notify_kind: u32 = 0,
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
    /// O_CLOEXEC given at open: F_GETFL reports it (Linux keeps it in f_flags); close-on-exec itself is the fd's FD_CLOEXEC.
    cloexec: bool = false,
    /// One per file descriptor naming this description (open, dup, dup2, fork, SCM_RIGHTS); the last close drops it.
    refs: u32 = 0,
    /// read()/lseek() position into the status line (Linux f_pos): shared by every descriptor naming this description.
    offset: u64 = 0,
};

var descriptions: [MAX_OPEN_DESCRIPTIONS]OpenDescription = @splat(.{});
var description_generations: [MAX_OPEN_DESCRIPTIONS]u64 = @splat(0);
/// One sleeping lock per open description, held across the read-modify-write of its offset (read, lseek). A sleeping lock, not
/// mq_lock: the read copies into a user buffer, and a page fault there must not be taken while mq_lock is held. Linux takes
/// f_pos_lock for a shared mqueue file (it is S_IFREG).
var description_offset_locks: [MAX_OPEN_DESCRIPTIONS]@import("../sync/task_sleep_lock.zig").SleepLock = @splat(.{});
// An mqd_t is an ordinary file descriptor (Linux do_mq_open): a vfs .mqueue descriptor naming descriptions[mq_desc_idx] at
// generation mq_desc_gen. dup, fork and SCM_RIGHTS copies share the description; the fd table owns numbering and close-on-exec.

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
const dac = @import("../fs/dac.zig");

fn callerCreds() dac.Credentials {
    const cur = sched.currentTask() orelse return .{ .euid = 0, .egid = 0, .cap_dac_override = true };
    return .{ .euid = cur.fsuid, .egid = cur.fsgid, .cap_dac_override = cur.effective_caps.cap_dac_override, .groups = cur.groups[0..cur.ngroups] };
}

fn accessFor(oflag: u32) dac.Access {
    return switch (oflag & descriptor_policy.O_ACCMODE) {
        descriptor_policy.O_WRONLY => dac.Access.write,
        descriptor_policy.O_RDWR => dac.Access.read_write,
        else => dac.Access.read,
    };
}

pub fn mqOpen(name_ptr: u64, oflag: u32, mode: u32, attr_ptr: u64) i64 {
    const creds = callerCreds();
    const umask_val: u32 = if (sched.currentTask()) |cur| cur.fsctx().umask else 0;

    // Read name and attributes BEFORE taking mq_lock: user copies walk page
    // tables and must not run with IRQs off. Linux struct mq_attr is four
    // 8-byte longs: mq_flags@0, mq_maxmsg@8, mq_msgsize@16, mq_curmsgs@24.
    var name_buf: [MAX_NAME_LEN]u8 = @splat(0);
    const name_len: u32 = @intCast(readUserString(name_ptr, &name_buf));
    if (name_len == 0) return EINVAL;
    if (!descriptor_policy.flagsValid(oflag)) return EINVAL;

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

    // Linux do_mq_open takes the descriptor first (lowest free number), so a full table is EMFILE before any queue is made.
    const cur = sched.currentTask() orelse return EBADF;
    const fd_slot = cur.fd_table.allocFd() orelse return EMFILE;
    const flags = mq_lock.acquire();
    const opened = openLocked(name_buf[0..name_len], oflag, mode, umask_val, creds, create_requested and attr_ptr != 0, maxmsg, msgsize);
    const di: u32 = if (opened >= 0) @intCast(opened) else 0;
    const gen: u64 = if (opened >= 0) description_generations[di] else 0;
    mq_lock.release(flags);
    if (opened < 0) {
        cur.fd_table.freeFd(fd_slot);
        return opened;
    }
    const access = oflag & descriptor_policy.O_ACCMODE;
    cur.fd_table.fds[fd_slot] = .{
        .fd_type = .mqueue,
        .mq_desc_idx = di,
        .mq_desc_gen = gen,
        // Every mq descriptor is close-on-exec (Linux FD_ADD(O_CLOEXEC, ...)), whatever oflag says.
        .fd_flags = 1,
        .status_flags = access,
        .writable = access != O_RDONLY,
        .file_size = descriptor_policy.FILENT_SIZE,
    };
    cur.fd_table.publishFd(fd_slot);
    return @intCast(fd_slot);
}

/// Find or create queue `name` and open a description of it: its index, or -errno. Caller holds mq_lock.
fn openLocked(name: []const u8, oflag: u32, mode: u32, umask_val: u32, creds: dac.Credentials, apply_attr: bool, maxmsg: i64, msgsize: i64) i64 {
    const name_len: u32 = @intCast(name.len);
    // Search for existing queue with this name
    for (&queues, 0..) |*q, queue_idx| {
        if (q.active and !q.marked_removed and str.eql(q.name[0..q.name_len], name)) {
            if (oflag & O_CREAT != 0 and oflag & O_EXCL != 0) {
                return EEXIST;
            }
            if (!dac.allows(.{ .mode = q.mode, .uid = q.uid, .gid = q.gid }, creds, accessFor(oflag))) return -13; // EACCES
            return openDescription(@intCast(queue_idx), q, oflag);
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
    for (0..name_len) |j| q.name[j] = name[j];
    q.name_len = name_len;
    q.active = true;
    q.head = 0;
    q.tail = 0;
    q.count = 0;
    q.marked_removed = false;
    q.uid = creds.euid;
    q.gid = creds.egid;
    q.mode = (mode & 0o777) & ~(umask_val & 0o777);
    q.open_count = 0;
    q.notify_tgid = 0;
    q.notify_signo = 0;
    q.notify_value = 0;
    q.notify_kind = 0;

    // Apply optional attributes (only honored at creation)
    if (apply_attr) {
        q.max_msg = @intCast(maxmsg);
        q.msg_size = @intCast(msgsize);
    }

    serial.writeString("[posix_mq] created mq=");
    serial.writeString(q.name[0..q.name_len]);
    serial.writeString("\n");

    const opened = openDescription(idx, q, oflag);
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

    const creds = callerCreds();
    for (&queues) |*q| {
        if (q.active and str.eql(q.name[0..q.name_len], name_buf[0..name_len])) {
            // Like unlinking a file in a sticky directory: owner or privileged.
            if (!creds.cap_dac_override and creds.euid != q.uid) {
                mq_lock.release(flags);
                return -13; // EACCES
            }
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
    const ref = fdDescription(mqd) orelse return EBADF;
    // Read timeout before acquiring lock
    const abs_timeout_ns = readAbsTimeout(timeout_ptr) catch |err| return switch (err) {
        error.Fault => EFAULT,
        error.Invalid => EINVAL,
    };

    // Try to send, blocking on the send wait queue if the queue is full
    while (true) {
        const flags = mq_lock.acquire();

        const desc = liveDescription(ref) orelse {
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
            // A default stop pending now is taken instead of sleeping (the handshake pipeRead uses): the task is already .blocked
            // and queued, and the sender sets the pending bit before it looks at the state.
            _ = @atomicRmw(u64, &cur_pin.task.pending_signals, .Or, 0, .seq_cst);
            const stop_now = @import("../proc/signal.zig").pendingStop(cur_pin.task);
            mq_lock.release(flags);
            if (!(stop_now and @import("../proc/signal.zig").stopWhileWaiting(cur_pin.task))) {
                sched.forceReschedule();
                sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）
            }
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
        const commit_q = findQueueForDescription(ref);
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
        var notice: ?struct { tgid: u32, signo: u32, value: u64 } = null;
        if (commit_q.?.count == 1 and commit_q.?.recv_waiters == null and commit_q.?.notify_tgid != 0) {
            const notify_signo = commit_q.?.notify_signo;
            // SIGEV_NONE, and SIGEV_SIGNAL with signal 0, are consumed here without a signal (Linux __do_notify).
            if (descriptor_policy.notifySends(commit_q.?.notify_kind, notify_signo) and notify_signo <= 64)
                notice = .{ .tgid = commit_q.?.notify_tgid, .signo = @intCast(notify_signo), .value = commit_q.?.notify_value };
            clearNotify(commit_q.?);
        }

        // Wake a receiver blocked on the empty queue
        const wake = wakeHead(commit_q.?, 1);

        const commit_qi = queueIndex(commit_q.?);
        mq_lock.release(commit_flags);
        if (wake) |token| wakeTask(token);
        wakePollers(commit_qi);
        if (notice) |n| {
            // Linux __do_notify: SI_MESGQ, the sender's pid and uid, and the registered sigev_value, sent to the process
            // (PIDTYPE_TGID): a thread that does not block it takes it. An ignored, unblocked signal is still dropped
            // (signal.ignoredAtSend). Sent after mq_lock is released, as the process lookup takes task_lock.
            const sender = sched.currentTask();
            const pid: u32 = if (sender) |st| groupId(st) else 0;
            const uid: u32 = if (sender) |st| st.uid else 0;
            const info = @import("../proc/siginfo_policy.zig").mesgqInfo(pid, uid, n.value);
            _ = @import("../proc/signal_syscall.zig").sendToProcessInfo(n.tgid, n.signo, info);
        }
        return 0;
    }
}

/// mq_timedreceive(mqd, msg_ptr, msg_len, msg_prio, abs_timeout) -> bytes or -errno
/// rdi=mqd, rsi=msg_ptr, rdx=msg_len, r10=msg_prio, r8=abs_timeout
pub fn mqTimedReceive(mqd: u32, msg_ptr: u64, msg_len: u64, prio_ptr: u64, timeout_ptr: u64) i64 {
    const ref = fdDescription(mqd) orelse return EBADF;
    if (prio_ptr != 0 and !copy.validateUserBufferWritable(prio_ptr, 4)) return EFAULT;
    // Read timeout before acquiring lock
    const abs_timeout_ns = readAbsTimeout(timeout_ptr) catch |err| return switch (err) {
        error.Fault => EFAULT,
        error.Invalid => EINVAL,
    };

    // Try to receive, blocking on the receive wait queue if the queue is empty
    while (true) {
        const flags = mq_lock.acquire();

        const desc = liveDescription(ref) orelse {
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
            // A default stop pending now is taken instead of sleeping (the handshake pipeRead uses): the task is already .blocked
            // and queued, and the sender sets the pending bit before it looks at the state.
            _ = @atomicRmw(u64, &cur_pin.task.pending_signals, .Or, 0, .seq_cst);
            const stop_now = @import("../proc/signal.zig").pendingStop(cur_pin.task);
            mq_lock.release(flags);
            if (!(stop_now and @import("../proc/signal.zig").stopWhileWaiting(cur_pin.task))) {
                sched.forceReschedule();
                sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）
            }
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
        const commit_q = findQueueForDescription(ref);
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
        const commit_qi = queueIndex(commit_q.?);

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
        wakePollers(commit_qi);
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
    var value: u64 = 0;
    var notify_kind: u32 = 0;
    if (notif_ptr != 0) {
        if (notif_ptr >= 0x0000_8000_0000_0000) return EFAULT;
        var buf: [16]u8 = undefined;
        if (copy.copyFromUser(&buf, @ptrFromInt(notif_ptr), 16) != 16) return EFAULT;
        value = bo.readU64Le(buf[0..8]);
        signo = @bitCast(bo.readU32Le(buf[8..12]));
        notify_kind = bo.readU32Le(buf[12..16]);
        // Linux valid_signal accepts 0; __do_notify then skips the send. SIGEV_NONE sends nothing either.
        if (!descriptor_policy.sigevNotifyValid(notify_kind)) return EINVAL;
        if (notify_kind == descriptor_policy.SIGEV_SIGNAL and (signo < 0 or signo > 64)) return EINVAL;
    }
    const ref = fdDescription(mqd) orelse return EBADF;

    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);

    const q = findQueueForDescription(ref) orelse return EBADF;

    if (notif_ptr == 0) {
        // Linux do_mq_notify: NULL removes the registration only when the caller owns it, and succeeds either way.
        if (notifyOwnedBy(q, owner_idx)) clearNotify(q);
        return 0;
    }

    if (q.notify_tgid != 0) return -16; // EBUSY

    // Register: one-shot, re-armed by another mq_notify after delivery. The owner is the caller's process.
    const caller = task.getTask(owner_idx) orelse return EBADF;
    q.notify_tgid = groupId(caller);
    q.notify_signo = signo;
    q.notify_value = value;
    q.notify_kind = notify_kind;
    return 0;
}

/// The thread group id of `t`: its own tid for a process, the creator's for a thread.
fn groupId(t: *const task.Task) u32 {
    return if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid;
}

/// The registration belongs to the caller's process: the registering task, or one that shares its thread group (Linux compares
/// task_tgid). A forked child is its own process and does not qualify.
fn notifyOwnedBy(q: *MqQueue, caller_idx: u32) bool {
    if (q.notify_tgid == 0) return false;
    const caller = task.getTask(caller_idx) orelse return false;
    return descriptor_policy.notifyOwner(q.notify_tgid, groupId(caller));
}

fn clearNotify(q: *MqQueue) void {
    q.notify_tgid = 0;
    q.notify_signo = 0;
    q.notify_value = 0;
    q.notify_kind = 0;
}

/// Task `task_idx` is exiting: a process (not one of its threads) drops every mq_notify registration it holds, wherever it was
/// made. A thread's exit leaves the process's registrations (Linux: the owner is the tgid, which outlives the thread).
pub fn clearNotifyForTask(task_idx: u32) void {
    const t = task.getTask(task_idx) orelse return;
    if (!descriptor_policy.exitDropsNotify(t.is_thread)) return;
    clearNotifyForProcess(t.tid);
}

/// Drop every mq_notify registration owned by process `tgid` (its exit, or its exec: Linux checks self_exec_id at delivery, so a
/// registration from the old image never fires into the new one).
pub fn clearNotifyForProcess(tgid: u32) void {
    if (tgid == 0) return;
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    for (&queues) |*q| {
        if (q.active and q.notify_tgid == tgid) clearNotify(q);
    }
}

/// Exec of task `task_idx`: its process's registrations go.
pub fn clearNotifyForExec(task_idx: u32) void {
    const t = task.getTask(task_idx) orelse return;
    clearNotifyForProcess(groupId(t));
}

/// mq_getsetattr(mqd, newattr, oldattr) -> 0 or -errno
/// rdi=mqd, rsi=newattr, rdx=oldattr
/// Linux struct mq_attr is four 8-byte longs (32 bytes):
/// mq_flags@0, mq_maxmsg@8, mq_msgsize@16, mq_curmsgs@24.
pub fn mqGetSetAttr(mqd: u32, newattr_ptr: u64, oldattr_ptr: u64) i64 {
    const ref = fdDescription(mqd) orelse return EBADF;
    if (oldattr_ptr != 0 and !copy.validateUserBufferWritable(oldattr_ptr, 32)) return EFAULT;
    if (newattr_ptr != 0 and newattr_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    var requested_flags: ?u32 = null;
    if (newattr_ptr != 0) {
        var new_buf: [32]u8 = undefined;
        if (copy.copyFromUser(&new_buf, @ptrFromInt(newattr_ptr), 32) != 32) return EFAULT;
        requested_flags = @truncate(@as(u64, @bitCast(bo.readI64Le(new_buf[0..8]))));
    }
    const flags = mq_lock.acquire();
    const desc = liveDescription(ref) orelse {
        mq_lock.release(flags);
        return EBADF;
    };
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

/// The description an mq file descriptor names (index and generation, as stored in the fd); checked under mq_lock before use.
const DescRef = struct { idx: u32, gen: u64 };

/// File descriptor `mqd` of the caller when it is an mq descriptor; anything else (another kind, a closed number) is EBADF.
/// Read without mq_lock: the generation is checked under the lock before the description is used.
fn fdDescription(mqd: u32) ?DescRef {
    if (mqd >= vfs.MAX_FDS) return null;
    const cur = sched.currentTask() orelse return null;
    const d = &cur.fd_table.fds[mqd];
    if (d.fd_type != .mqueue) return null;
    return .{ .idx = d.mq_desc_idx, .gen = d.mq_desc_gen };
}

fn liveDescription(ref: DescRef) ?*OpenDescription {
    if (ref.idx >= MAX_OPEN_DESCRIPTIONS) return null;
    const desc = &descriptions[ref.idx];
    if (!desc.active or description_generations[ref.idx] != ref.gen) return null;
    return desc;
}

fn findQueueForDescription(ref: DescRef) ?*MqQueue {
    const desc = liveDescription(ref) orelse return null;
    if (desc.queue_idx >= MAX_QUEUES) return null;
    const q = &queues[desc.queue_idx];
    if (!q.active or queue_generations[desc.queue_idx] != desc.queue_generation) return null;
    return q;
}

/// Open a new description of queue `queue_idx` with one reference (the descriptor mq_open installs): its index, or EMFILE when
/// the description pool is full. Caller holds mq_lock.
fn openDescription(queue_idx: u32, q: *MqQueue, oflag: u32) i64 {
    const desc_idx = for (0..MAX_OPEN_DESCRIPTIONS) |i| {
        if (!descriptions[i].active) break @as(?u32, @intCast(i));
    } else null;
    const di = desc_idx orelse return EMFILE;
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
    q.open_count += 1;
    return @intCast(di);
}

/// One more file descriptor names description `idx` (dup, dup2, fork, SCM_RIGHTS). False when the description is gone.
pub fn retainDescription(idx: u32, gen: u64) bool {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const desc = liveDescription(.{ .idx = idx, .gen = gen }) orelse return false;
    desc.refs += 1;
    return true;
}

/// A file descriptor naming description `idx` is closing (close, dup2 over it, exec's close-on-exec, the table's last close).
/// The closer is the current task; the last reference closes the description.
pub fn closeDescription(idx: u32, gen: u64) void {
    var wakes = WakeBatch{};
    const flags = mq_lock.acquire();
    if (liveDescription(.{ .idx = idx, .gen = gen })) |desc| {
        // Linux mqueue_flush_file: any close of a descriptor of the queue by the process that owns the registration removes it,
        // whichever descriptor it was made through (a dup, another open). A forked child is another process and leaves it.
        if (desc.queue_idx < MAX_QUEUES) {
            const fq = &queues[desc.queue_idx];
            const closer = if (sched.currentTaskIndex()) |ci| task.getTask(ci) else null;
            if (fq.active and closer != null and descriptor_policy.notifyOwner(fq.notify_tgid, groupId(closer.?))) clearNotify(fq);
        }
        if (desc.refs > 0) desc.refs -= 1;
        if (desc.refs == 0) {
            const q = &queues[desc.queue_idx];
            q.open_count -|= 1;
            if (q.marked_removed and q.open_count == 0) freeQueue(q, &wakes);
            desc.* = .{};
            // The offset lock is not dropped here. A reader of a descriptor another thread just closed still holds it, and
            // stealing it would let that reader unlock twice. The index cannot be reused until that reader re-checks under
            // mq_lock, finds the description gone and unlocks; a new opener of the same index waits on the lock meanwhile.
        }
    }
    mq_lock.release(flags);
    wakes.wake();
}

/// read() of an mq descriptor at `offset`: the queue's status line from there (Linux mqueue_read_file), 0 past its end, EBADF for
/// a description that is gone. `buf` is filled after mq_lock is released.
pub fn statusRead(idx: u32, gen: u64, offset: u64, buf: [*]u8, count: usize) i64 {
    var line: [descriptor_policy.FILENT_SIZE]u8 = undefined;
    var len: usize = 0;
    {
        const flags = mq_lock.acquire();
        defer mq_lock.release(flags);
        const q = findQueueForDescription(.{ .idx = idx, .gen = gen }) orelse return EBADF;
        var qsize: u64 = 0;
        for (&q.msgs) |*m| {
            if (m.used) qsize += m.len;
        }
        const signo: u32 = if (q.notify_signo > 0) @intCast(q.notify_signo) else 0;
        len = descriptor_policy.statusLine(&line, qsize, q.notify_tgid != 0, q.notify_kind, signo, q.notify_tgid).len;
    }
    if (offset >= len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(count, len - start);
    @memcpy(buf[0..n], line[start..][0..n]);
    return @intCast(n);
}

/// Take the offset lock of open description `idx` when it is still the description `gen` names, so a read or lseek of a shared mq
/// description cannot race another one on its position (Linux f_pos_lock). Returns the token unlockDescriptionOffset takes back;
/// 0 when the description is already gone (nothing to lock, the read then fails with EBADF).
pub fn lockDescriptionOffset(idx: u32, gen: u64) u16 {
    if (idx >= MAX_OPEN_DESCRIPTIONS) return 0;
    {
        const flags = mq_lock.acquire();
        defer mq_lock.release(flags);
        if (liveDescription(.{ .idx = idx, .gen = gen }) == null) return 0;
    }
    description_offset_locks[idx].lock();
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    if (liveDescription(.{ .idx = idx, .gen = gen }) == null) {
        description_offset_locks[idx].unlock();
        return 0;
    }
    return @intCast(idx + 1);
}

/// Drop the offset lock lockDescriptionOffset took; `token` 0 means nothing was locked.
pub fn unlockDescriptionOffset(token: u16) void {
    if (token == 0 or token > MAX_OPEN_DESCRIPTIONS) return;
    description_offset_locks[token - 1].unlock();
}

/// The read position of description `idx` (Linux f_pos of the mqueue file); null once the description is gone.
pub fn descriptionOffset(idx: u32, gen: u64) ?u64 {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const desc = liveDescription(.{ .idx = idx, .gen = gen }) orelse return null;
    return desc.offset;
}

/// Move the read position of description `idx` for every descriptor that names it.
pub fn setDescriptionOffset(idx: u32, gen: u64, offset: u64) void {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const desc = liveDescription(.{ .idx = idx, .gen = gen }) orelse return;
    desc.offset = offset;
}

/// poll/epoll readiness of description `idx` (Linux mqueue_poll_file); POLLERR once it is gone.
pub fn pollEvents(idx: u32) u32 {
    if (idx >= MAX_OPEN_DESCRIPTIONS) return 0x8;
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const desc = &descriptions[idx];
    if (!desc.active) return 0x8;
    const q = findQueueForDescription(.{ .idx = idx, .gen = description_generations[idx] }) orelse return 0x8;
    return descriptor_policy.pollEvents(q.count, q.max_msg);
}

/// A send or receive changed queue `queue_idx`: wake poll/select sleepers and tell epoll about every description of the queue.
/// Runs after mq_lock is released (epollNotify takes the epoll pool lock).
fn wakePollers(queue_idx: u32) void {
    var hits: [MAX_OPEN_DESCRIPTIONS / 64]u64 = @splat(0);
    var events: u32 = 0;
    const flags = mq_lock.acquire();
    if (queue_idx < MAX_QUEUES and queues[queue_idx].active) {
        events = descriptor_policy.pollEvents(queues[queue_idx].count, queues[queue_idx].max_msg);
        for (&descriptions, 0..) |*d, i| {
            if (d.active and d.queue_idx == queue_idx) hits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        }
    }
    mq_lock.release(flags);
    @import("../fs/poll_wake.zig").notify();
    if (events == 0) return;
    const epoll = @import("../net/epoll.zig");
    for (hits, 0..) |word, w| {
        var bits = word;
        while (bits != 0) {
            const b: u32 = @ctz(bits);
            bits &= bits - 1;
            epoll.epollNotify(.mqueue, @intCast(w * 64 + b), events);
        }
    }
}

/// F_GETFL of description `idx`: access mode, O_NONBLOCK and the O_CLOEXEC given at open (null: gone).
pub fn statusFlagsOf(idx: u32, gen: u64) ?u32 {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const desc = liveDescription(.{ .idx = idx, .gen = gen }) orelse return null;
    return descriptor_policy.reportedFlags(desc.access, desc.status_flags, desc.cloexec);
}

/// F_SETFL of description `idx`: only O_NONBLOCK changes (the bit mq_setattr changes). False when it is gone.
pub fn setStatusFlags(idx: u32, gen: u64, requested: u32) bool {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const desc = liveDescription(.{ .idx = idx, .gen = gen }) orelse return false;
    desc.status_flags = (desc.status_flags & ~@as(u32, O_NONBLOCK)) | (requested & O_NONBLOCK);
    return true;
}

pub const StatInfo = struct { mode: u32, uid: u32, gid: u32 };

/// fstat of description `idx`: the queue's permission bits and owner (null: gone).
pub fn statInfo(idx: u32, gen: u64) ?StatInfo {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const q = findQueueForDescription(.{ .idx = idx, .gen = gen }) orelse return null;
    return .{ .mode = q.mode, .uid = q.uid, .gid = q.gid };
}

/// /proc/self/fd/N of description `idx`: "/name" into `out`, its length, or null (gone, or too long).
pub fn nameOf(idx: u32, gen: u64, out: []u8) ?usize {
    const flags = mq_lock.acquire();
    defer mq_lock.release(flags);
    const q = findQueueForDescription(.{ .idx = idx, .gen = gen }) orelse return null;
    return descriptor_policy.linkName(q.name[0..q.name_len], out);
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
