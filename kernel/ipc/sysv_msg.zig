/// SysV Message Queues (msgget/msgsnd/msgrcv/msgctl) implementation.
///
/// Completes the SysV IPC trilogy alongside sysv_shm.zig and sysv_sem.zig.
/// Used by legacy applications and some message-passing architectures.
const std = @import("std");
const serial = @import("../arch/arch.zig").serial;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");
const bo = @import("../lib/byte_order.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const sysv_policy = @import("sysv_policy.zig");
const select_policy = @import("sysv_msg_select_policy.zig");

const MAX_QUEUES: u32 = 16;
const MAX_MSGS_PER_Q: u32 = 8;
const MAX_MSG_SIZE: u32 = 512;

/// Single message in a queue
const MsgBuf = struct {
    data: [MAX_MSG_SIZE]u8 = @splat(0),
    len: u32 = 0,
    /// Message type (must be > 0)
    mtype: i64 = 0,
    /// Per-queue enqueue order; msgrcv selects by this, not ring position.
    seq: u64 = 0,
    used: bool = false,
};

/// SysV message queue descriptor
pub const MsgQueue = struct {
    active: bool = false,
    key: i32 = 0,
    msgid: u32 = 0,
    /// Permission mode
    mode: u32 = 0,
    /// Messages stored as ring buffer
    msgs: [MAX_MSGS_PER_Q]MsgBuf = @splat(.{}),
    head: u32 = 0,
    tail: u32 = 0,
    count: u32 = 0,
    /// Next seq stamped on an enqueued message (monotonic per queue)
    next_seq: u64 = 0,
    /// Total bytes in queue
    total_bytes: u32 = 0,
    /// Max bytes allowed
    max_bytes: u32 = MAX_MSGS_PER_Q * MAX_MSG_SIZE,
    /// Owner TID
    owner_tid: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    cuid: u32 = 0,
    cgid: u32 = 0,
    /// Marked for removal
    marked_removed: bool = false,
    /// Last send/receive time (approximate)
    stime: u64 = 0,
    rtime: u64 = 0,
    ctime: u64 = 0,
};

var queues: [MAX_QUEUES]MsgQueue = @splat(.{});
var next_msgid: u32 = 1;
var msg_lock: IrqSpinlock = .{};

// ── IPC constants ──
const IPC_CREAT: i32 = 0o1000;
const IPC_EXCL: i32 = 0o2000;
const IPC_NOWAIT: i32 = 0o4000;
const IPC_RMID: i32 = 0;
const IPC_STAT: i32 = 2;
const IPC_SET: i32 = 1;
const IPC_PRIVATE: i32 = 0;

// ── Error codes ──
const errno = @import("../lib/errno.zig");
const EINVAL = errno.EINVAL;
const ENOENT = errno.ENOENT;
const EEXIST = errno.EEXIST;
const ENOSPC = errno.ENOSPC;
const EAGAIN = errno.EAGAIN;
const EIDRM = errno.EIDRM;
const EFAULT = errno.EFAULT;
const ENOMEM = errno.ENOMEM;
const E2BIG = errno.E2BIG;

const MSGGET_FLAGS = IPC_CREAT | IPC_EXCL | IPC_NOWAIT | 0o777;
const MSG_FLAGS = IPC_NOWAIT | 0o10000;

fn credentials() sysv_policy.Credentials {
    if (sched.currentTaskIndex()) |idx| {
        if (task.getTask(idx)) |t| return .{ .euid = t.euid, .egid = t.egid, .cap_sys_admin = t.effective_caps.cap_sys_admin, .groups = t.groups[0..t.ngroups] };
    }
    return .{ .euid = 0, .egid = 0, .cap_sys_admin = true };
}

fn owner(q: *const MsgQueue) sysv_policy.Owner {
    return .{ .uid = q.uid, .gid = q.gid, .cuid = q.cuid, .cgid = q.cgid };
}

fn canAccess(q: *const MsgQueue, read: bool, write: bool) bool {
    return sysv_policy.modeAllows(q.mode, owner(q), credentials(), read, write);
}

fn canManage(q: *const MsgQueue) bool {
    return sysv_policy.canManage(owner(q), credentials());
}

fn allocateMsgId() ?u32 {
    var attempts: u32 = 0;
    while (attempts < std.math.maxInt(u32)) : (attempts += 1) {
        const candidate = next_msgid;
        next_msgid +%= 1;
        if (candidate == 0) continue;
        if (findById(candidate) == null) return candidate;
    }
    return null;
}

/// msgget(key, msgflg) -> msgid or -errno
pub fn msgget(key: i32, msgflg: i32) i64 {
    if (!sysv_policy.flagsValid(msgflg, MSGGET_FLAGS)) return EINVAL;
    const flags = msg_lock.acquire();
    defer msg_lock.release(flags);

    // Search for existing queue with this key
    if (key != IPC_PRIVATE) {
        for (&queues) |*q| {
            if (q.active and !q.marked_removed and q.key == key) {
                if (msgflg & IPC_CREAT != 0 and msgflg & IPC_EXCL != 0) {
                    return EEXIST;
                }
                const requested = @as(u32, @intCast(msgflg)) & 0o6;
                if (requested != 0 and !canAccess(q, (requested & 0o4) != 0, (requested & 0o2) != 0)) return errno.EACCES;
                return @intCast(q.msgid);
            }
        }
    }

    // Need to create
    if (msgflg & IPC_CREAT == 0 and key != IPC_PRIVATE) {
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
    const mid = allocateMsgId() orelse return ENOSPC;

    queues[idx] = .{
        .active = true,
        .key = key,
        .msgid = mid,
        .mode = @intCast(msgflg & 0o777),
        .owner_tid = if (sched.currentTaskIndex()) |tid| tid else 0,
        .uid = credentials().euid,
        .gid = credentials().egid,
        .cuid = credentials().euid,
        .cgid = credentials().egid,
    };

    serial.writeString("[sysv_msg] created msgid=");
    fmt.writeDecimal(mid);
    serial.writeString(" key=");
    fmt.writeDecimal64(@bitCast(@as(i64, key)));
    serial.writeString("\n");

    return @intCast(mid);
}

/// msgsnd(msqid, msgp, msgsz, msgflg) -> 0 or -errno
/// User msgp format: { mtype: i64 (8 bytes), mtext: [msgsz]u8 }
pub fn msgsnd(msqid: u32, msgp: u64, msgsz: u64, msgflg: i32) i64 {
    if (!sysv_policy.flagsValid(msgflg, MSG_FLAGS)) return EINVAL;
    if (msgsz > MAX_MSG_SIZE or msgsz > std.math.maxInt(u64) - 8) return E2BIG;
    const copy = @import("../mm/copy_from_user.zig");
    if (msgp > std.math.maxInt(u64) - 8 or !copy.validateUserBuffer(msgp, @intCast(msgsz + 8))) return EFAULT;

    var local_msg: MsgBuf = .{};
    var mtype_buf: [8]u8 = undefined;
    if (copy.copyFromUser(&mtype_buf, @ptrFromInt(msgp), 8) != 8) return EFAULT;
    local_msg.mtype = @bitCast(bo.readU64At(&mtype_buf, 0));
    if (local_msg.mtype <= 0) return EINVAL;
    if (msgsz > 0) {
        const copy_len: usize = @intCast(msgsz);
        if (copy.copyFromUser(local_msg.data[0..copy_len], @ptrFromInt(msgp + 8), copy_len) != copy_len) return EFAULT;
    }
    local_msg.len = @intCast(msgsz);
    local_msg.used = true;

    const flags = msg_lock.acquire();
    defer msg_lock.release(flags);
    const q = findById(msqid) orelse return EINVAL;
    if (q.marked_removed) return EIDRM;
    if (!canAccess(q, false, true)) return errno.EACCES;

    if (q.count >= MAX_MSGS_PER_Q) {
        if (msgflg & IPC_NOWAIT != 0) return EAGAIN;
        return EAGAIN; // simplified: no blocking
    }

    var insert_idx: ?u32 = null;
    var scan: u32 = 0;
    while (scan < MAX_MSGS_PER_Q) : (scan += 1) {
        const candidate = (q.tail + scan) % MAX_MSGS_PER_Q;
        if (!q.msgs[candidate].used) {
            insert_idx = candidate;
            break;
        }
    }
    const idx = insert_idx orelse return EAGAIN;
    local_msg.seq = q.next_seq;
    q.next_seq += 1;
    q.msgs[idx] = local_msg;
    q.tail = (idx + 1) % MAX_MSGS_PER_Q;
    q.count += 1;
    q.total_bytes += @intCast(msgsz);

    return 0;
}

/// msgrcv(msqid, msgp, msgsz, msgtyp, msgflg) -> bytes received or -errno
/// Writes to user: { mtype: i64 (8 bytes), mtext: [actual]u8 }
pub fn msgrcv(msqid: u32, msgp: u64, msgsz: u64, msgtyp: i64, msgflg: i32) i64 {
    if (!sysv_policy.flagsValid(msgflg, MSG_FLAGS)) return EINVAL;
    const copy = @import("../mm/copy_from_user.zig");
    var output_msg: MsgBuf = undefined;
    var result: i64 = undefined;
    var out_len: u32 = undefined;
    {
        const flags = msg_lock.acquire();
        defer msg_lock.release(flags);

        const q = findById(msqid) orelse return EINVAL;
        if (q.marked_removed) return EIDRM;
        if (!canAccess(q, true, false)) return errno.EACCES;

        if (q.count == 0) {
            if (msgflg & IPC_NOWAIT != 0) return EAGAIN;
            return EAGAIN; // simplified: no blocking
        }

        // Find matching message by type, oldest (smallest seq) first:
        // msgtyp == 0: oldest message
        // msgtyp > 0: oldest message with that type
        // msgtyp < 0: LOWEST type <= |msgtyp|, oldest within that type
        // Typed receives free middle slots that msgsnd may back-fill, so ring
        // position is not age order — select by seq over all slots.
        var candidates: [MAX_MSGS_PER_Q]select_policy.Slot = undefined;
        for (&q.msgs, 0..) |*m, i| {
            candidates[i] = .{ .used = m.used, .mtype = m.mtype, .seq = m.seq };
        }
        const found_idx: ?u32 = if (select_policy.select(&candidates, msgtyp)) |i| @intCast(i) else null;

        if (found_idx == null) {
            if (msgflg & IPC_NOWAIT != 0) return EAGAIN;
            return EAGAIN;
        }

        const idx = found_idx.?;
        const msg = &q.msgs[idx];

        if (msg.len > msgsz) {
            if (msgflg & 0o10000 == 0) {
                // MSG_NOERROR not set
                return E2BIG;
            }
        }

        out_len = if (msg.len > msgsz) @intCast(msgsz) else msg.len;
        if (msgsz > std.math.maxInt(u64) - 8) return EINVAL;
        if (!copy.validateUserBufferWritable(msgp, @intCast(out_len + 8))) return EFAULT;

        output_msg = msg.*;
        result = @intCast(out_len);
        // Dequeue before touching user memory; the destination was prevalidated above.
        const freed_bytes = msg.len;
        msg.* = .{};
        q.total_bytes -= freed_bytes;
        q.count -= 1;
        if (idx == q.head) {
            while (q.count > 0 and !q.msgs[q.head].used) {
                q.head = (q.head + 1) % MAX_MSGS_PER_Q;
            }
        }
        const remove_queue = q.marked_removed and q.count == 0;
        if (remove_queue) q.* = .{};
    }

    // Write mtype to user space after releasing the IRQ spinlock.
    var mtype_buf: [8]u8 = undefined;
    const mtype_u: u64 = @bitCast(output_msg.mtype);
    mtype_buf[0] = @intCast(mtype_u & 0xFF);
    mtype_buf[1] = @intCast((mtype_u >> 8) & 0xFF);
    mtype_buf[2] = @intCast((mtype_u >> 16) & 0xFF);
    mtype_buf[3] = @intCast((mtype_u >> 24) & 0xFF);
    mtype_buf[4] = @intCast((mtype_u >> 32) & 0xFF);
    mtype_buf[5] = @intCast((mtype_u >> 40) & 0xFF);
    mtype_buf[6] = @intCast((mtype_u >> 48) & 0xFF);
    mtype_buf[7] = @intCast((mtype_u >> 56) & 0xFF);
    if (copy.copyToUser(@ptrFromInt(msgp), &mtype_buf, 8) != 8) return EFAULT;

    // Write message text to user space
    if (out_len > 0) {
        const written = copy.copyToUser(
            @ptrFromInt(msgp + 8),
            output_msg.data[0..out_len],
            out_len,
        );
        if (written != out_len) return EFAULT;
    }

    return result;
}

/// msgctl(msqid, cmd, buf) -> 0 or -errno
pub fn msgctl(msqid: u32, cmd: i32, buf: u64) i64 {
    if (cmd != IPC_STAT and cmd != IPC_RMID and cmd != IPC_SET) return EINVAL;
    if (cmd == IPC_RMID) {
        const flags = msg_lock.acquire();
        defer msg_lock.release(flags);
        const q = findById(msqid) orelse return EINVAL;
        if (q.marked_removed) return EIDRM;
        if (!canManage(q)) return errno.EPERM;
        // Linux deletes the queue and its messages at once. No sysv_msg call
        // blocks, so no task can be holding the slot; leaving it "marked" made
        // every later msgsnd/msgrcv/msgctl fail with EIDRM and the slot was
        // never reclaimed (16 leaks exhaust msgget for everyone).
        serial.writeString("[sysv_msg] removed msgid=");
        fmt.writeDecimal(msqid);
        serial.writeString("\n");
        q.* = .{};
        return 0;
    }

    if (buf == 0 or buf >= 0x0000_8000_0000_0000) return EFAULT;
    const copy = @import("../mm/copy_from_user.zig");
    if (cmd == IPC_SET) {
        if (!copy.validateUserBuffer(buf, @sizeOf(u64))) return EFAULT;
        var mode_buf: u64 = 0;
        if (copy.copyFromUser(@as([*]u8, @ptrCast(&mode_buf))[0..@sizeOf(u64)], @ptrFromInt(buf), @sizeOf(u64)) != @sizeOf(u64)) return EFAULT;
        const flags = msg_lock.acquire();
        defer msg_lock.release(flags);
        const q = findById(msqid) orelse return EINVAL;
        if (q.marked_removed) return EIDRM;
        if (!canManage(q)) return errno.EPERM;
        q.mode = @intCast(mode_buf & 0o777);
        return 0;
    }

    var info: [6]u64 = undefined;
    const flags = msg_lock.acquire();
    const q = findById(msqid) orelse {
        msg_lock.release(flags);
        return EINVAL;
    };
    if (q.marked_removed) {
        msg_lock.release(flags);
        return EIDRM;
    }
    if (!canAccess(q, true, false)) {
        msg_lock.release(flags);
        return errno.EACCES;
    }
    info = .{ @bitCast(@as(i64, q.key)), @intCast(q.msgid), @intCast(q.count), @intCast(q.total_bytes), @intCast(q.mode), 0 };
    msg_lock.release(flags);
    const info_size = @sizeOf([6]u64);
    if (!copy.validateUserBufferWritable(buf, info_size)) return EFAULT;
    if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&info))[0..info_size], info_size) != info_size) return EFAULT;
    return 0;
}

// ── Internal helpers ──

fn findById(msgid: u32) ?*MsgQueue {
    for (&queues) |*q| {
        if (q.active and q.msgid == msgid) return q;
    }
    return null;
}
