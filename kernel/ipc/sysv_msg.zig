/// SysV Message Queues (msgget/msgsnd/msgrcv/msgctl) implementation.
///
/// Completes the SysV IPC trilogy alongside sysv_shm.zig and sysv_sem.zig.
/// Used by legacy applications and some message-passing architectures.
const serial = @import("../arch/arch.zig").serial;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");
const bo = @import("../lib/byte_order.zig");

const MAX_QUEUES: u32 = 16;
const MAX_MSGS_PER_Q: u32 = 8;
const MAX_MSG_SIZE: u32 = 512;

/// Single message in a queue
const MsgBuf = struct {
    data: [MAX_MSG_SIZE]u8 = @splat(0),
    len: u32 = 0,
    /// Message type (must be > 0)
    mtype: i64 = 0,
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
    /// Total bytes in queue
    total_bytes: u32 = 0,
    /// Max bytes allowed
    max_bytes: u32 = MAX_MSGS_PER_Q * MAX_MSG_SIZE,
    /// Owner TID
    owner_tid: u32 = 0,
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

/// msgget(key, msgflg) -> msgid or -errno
pub fn msgget(key: i32, msgflg: i32) i64 {
    const flags = msg_lock.acquire();
    defer msg_lock.release(flags);

    // Search for existing queue with this key
    if (key != IPC_PRIVATE) {
        for (&queues) |*q| {
            if (q.active and q.key == key) {
                if (msgflg & IPC_CREAT != 0 and msgflg & IPC_EXCL != 0) {
                    return EEXIST;
                }
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
    const mid = next_msgid;
    next_msgid += 1;

    queues[idx] = .{
        .active = true,
        .key = key,
        .msgid = mid,
        .mode = @intCast(msgflg & 0o777),
    };

    serial.writeString("[sysv_msg] created msgid=");
    fmt.writeDecimal(mid);
    serial.writeString(" key=");
    fmt.writeDecimal64(@intCast(key));
    serial.writeString("\n");

    return @intCast(mid);
}

/// msgsnd(msqid, msgp, msgsz, msgflg) -> 0 or -errno
/// User msgp format: { mtype: i64 (8 bytes), mtext: [msgsz]u8 }
pub fn msgsnd(msqid: u32, msgp: u64, msgsz: u64, msgflg: i32) i64 {
    const flags = msg_lock.acquire();
    defer msg_lock.release(flags);

    const q = findById(msqid) orelse return EINVAL;
    if (q.marked_removed) return EIDRM;

    if (msgsz > MAX_MSG_SIZE) return E2BIG;
    if (q.count >= MAX_MSGS_PER_Q) {
        if (msgflg & IPC_NOWAIT != 0) return EAGAIN;
        return EAGAIN; // simplified: no blocking
    }

    // Read message from user space
    const copy = @import("../mm/copy_from_user.zig");

    // Read mtype (first 8 bytes of user buffer)
    var mtype_buf: [8]u8 = undefined;
    if (copy.copyFromUser(&mtype_buf, @ptrFromInt(msgp), 8) != 8) return EFAULT;
    const mtype: i64 = @bitCast(bo.readU64At(&mtype_buf, 0));
    if (mtype <= 0) return EINVAL;

    // Read message text
    var msg = &q.msgs[q.tail];
    if (msgsz > 0) {
        const copy_len: usize = @intCast(msgsz);
        const copied = copy.copyFromUser(
            msg.data[0..copy_len],
            @ptrFromInt(msgp + 8),
            copy_len,
        );
        if (copied != copy_len) return EFAULT;
    }

    msg.len = @intCast(msgsz);
    msg.mtype = mtype;
    msg.used = true;
    q.tail = (q.tail + 1) % MAX_MSGS_PER_Q;
    q.count += 1;
    q.total_bytes += @intCast(msgsz);

    return 0;
}

/// msgrcv(msqid, msgp, msgsz, msgtyp, msgflg) -> bytes received or -errno
/// Writes to user: { mtype: i64 (8 bytes), mtext: [actual]u8 }
pub fn msgrcv(msqid: u32, msgp: u64, msgsz: u64, msgtyp: i64, msgflg: i32) i64 {
    const flags = msg_lock.acquire();
    defer msg_lock.release(flags);

    const q = findById(msqid) orelse return EINVAL;
    if (q.marked_removed) return EIDRM;

    if (q.count == 0) {
        if (msgflg & IPC_NOWAIT != 0) return EAGAIN;
        return EAGAIN; // simplified: no blocking
    }

    // Find matching message by type
    // msgtyp == 0: first message
    // msgtyp > 0: first message with that type
    // msgtyp < 0: first message with lowest type <= |msgtyp|
    var found_idx: ?u32 = null;

    if (msgtyp == 0) {
        // First available message
        found_idx = q.head;
    } else {
        var i: u32 = 0;
        while (i < q.count) : (i += 1) {
            const idx = (q.head + i) % MAX_MSGS_PER_Q;
            const msg = &q.msgs[idx];
            if (!msg.used) continue;
            if (msgtyp > 0 and msg.mtype == msgtyp) {
                found_idx = idx;
                break;
            }
            if (msgtyp < 0 and msg.mtype <= @as(i64, @intCast(@as(u64, @bitCast(-msgtyp))))) {
                found_idx = idx;
                break;
            }
        }
    }

    if (found_idx == null) {
        if (msgflg & IPC_NOWAIT != 0) return EAGAIN;
        return EAGAIN;
    }

    const idx = found_idx.?;
    var msg = &q.msgs[idx];

    if (msg.len > msgsz) {
        if (msgflg & 0o10000 == 0) {
            // MSG_NOERROR not set
            return E2BIG;
        }
    }

    const out_len: u32 = if (msg.len > msgsz) @intCast(msgsz) else msg.len;

    // Write mtype to user space
    const copy = @import("../mm/copy_from_user.zig");
    var mtype_buf: [8]u8 = undefined;
    const mtype_u: u64 = @bitCast(msg.mtype);
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
            msg.data[0..out_len],
            out_len,
        );
        if (written != out_len) return EFAULT;
    }

    const result: i64 = @intCast(out_len);

    // Free the slot
    const freed_bytes = msg.len;
    msg.used = false;
    msg.len = 0;
    msg.mtype = 0;
    q.total_bytes -= freed_bytes;
    q.count -= 1;

    // Compact: if we removed a non-head message, we need to handle it
    // Simplified: just advance head if we removed the head
    if (idx == q.head) {
        q.head = (q.head + 1) % MAX_MSGS_PER_Q;
    }

    // If marked for removal and now empty, free
    if (q.marked_removed and q.count == 0) {
        q.* = .{};
    }

    return result;
}

/// msgctl(msqid, cmd, buf) -> 0 or -errno
pub fn msgctl(msqid: u32, cmd: i32, buf: u64) i64 {
    const flags = msg_lock.acquire();
    defer msg_lock.release(flags);

    const q = findById(msqid) orelse return EINVAL;

    switch (cmd) {
        IPC_STAT => {
            if (buf == 0 or buf >= 0x0000_8000_0000_0000) return EFAULT;
            const copy = @import("../mm/copy_from_user.zig");
            // Write basic info: key, msgid, count, total_bytes, mode
            var info: [6]u64 = .{
                @intCast(q.key),
                @intCast(q.msgid),
                @intCast(q.count),
                @intCast(q.total_bytes),
                @intCast(q.mode),
                if (q.marked_removed) @as(u64, 1) else 0,
            };
            if (copy.copyToUser(
                @ptrFromInt(buf),
                @as([*]const u8, @ptrCast(&info))[0..@sizeOf([6]u64)],
                @sizeOf([6]u64),
            ) != @sizeOf([6]u64)) return EFAULT;
            return 0;
        },
        IPC_RMID => {
            q.marked_removed = true;
            serial.writeString("[sysv_msg] marked msgid=");
            fmt.writeDecimal(msqid);
            serial.writeString(" for removal\n");
            if (q.count == 0) {
                q.* = .{};
            }
            return 0;
        },
        IPC_SET => {
            // Update permission mode bits from buf (simplified: accept mode as u64)
            if (buf == 0 or buf >= 0x0000_8000_0000_0000) return EFAULT;
            const copy = @import("../mm/copy_from_user.zig");
            var mode_buf: [1]u64 = .{0};
            _ = copy.copyFromUser(@ptrCast(&mode_buf), @as([*]const u8, @ptrFromInt(buf)), @sizeOf(u64));
            q.mode = @intCast(mode_buf[0] & 0o777);
            return 0;
        },
        else => return EINVAL,
    }
}

// ── Internal helpers ──

fn findById(msgid: u32) ?*MsgQueue {
    for (&queues) |*q| {
        if (q.active and q.msgid == msgid) return q;
    }
    return null;
}
