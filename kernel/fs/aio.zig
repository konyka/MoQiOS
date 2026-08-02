/// Linux AIO (Asynchronous I/O) implementation.
///
/// Provides io_setup/io_destroy/io_submit/io_getevents/io_cancel.
/// Used by MySQL/InnoDB, PostgreSQL (aio_mode), and other databases.
///
/// Simplified approach: io_submit executes I/O synchronously and
/// immediately marks events as completed. This satisfies the API
/// contract while avoiding the complexity of true async dispatch.
const serial = @import("../arch/arch.zig").serial;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const bo = @import("../lib/byte_order.zig");
const fmt = @import("../lib/fmt.zig");

const MAX_CONTEXTS: u32 = 8;
const MAX_EVENTS: u32 = 32;

/// Linux io_event structure (matches kernel struct)
pub const IoEvent = extern struct {
    data: u64 = 0,
    obj: u64 = 0,
    res: i64 = 0,
    res2: i64 = 0,
};

/// Linux iocb structure (user-submitted I/O control block)
pub const IoCb = extern struct {
    aio_data: u64 = 0,
    aio_key: u32 = 0,
    aio_reserved1: i16 = 0,
    aio_reserved2: i16 = 0,
    aio_lio_opcode: u16 = 0,
    aio_reqprio: i16 = 0,
    aio_fildes: u32 = 0,
    aio_buf: u64 = 0,
    aio_nbytes: u64 = 0,
    aio_offset: i64 = 0,
};

/// AIO operation codes
const IOCB_CMD_PREAD: u16 = 0;
const IOCB_CMD_PWRITE: u16 = 1;
const IOCB_CMD_FSYNC: u16 = 2;
const IOCB_CMD_FDSYNC: u16 = 3;
const IOCB_CMD_NOOP: u16 = 4;

/// AIO context
pub const AioContext = struct {
    active: bool = false,
    id: u64 = 0,
    max_events: u32 = 0,
    /// Completed events ring buffer
    events: [MAX_EVENTS]IoEvent = @splat(.{}),
    event_head: u32 = 0, // next to read
    event_tail: u32 = 0, // next to write
    event_count: u32 = 0,
};

var contexts: [MAX_CONTEXTS]AioContext = @splat(.{});
var next_ctx_id: u64 = 1;
var aio_lock: IrqSpinlock = .{};

// ── Error codes ──
const errno = @import("../lib/errno.zig");
const EINVAL = errno.EINVAL;
const ENOMEM = errno.ENOMEM;
const EFAULT = errno.EFAULT;
const EIO = errno.EIO;

/// io_setup(nr_events, ctx_id_ptr) -> 0 or -errno
/// Creates an AIO context and writes its ID to user space.
pub fn ioSetup(nr_events: u64, ctx_id_ptr: u64) i64 {
    const flags = aio_lock.acquire();
    defer aio_lock.release(flags);

    if (nr_events == 0 or nr_events > MAX_EVENTS) return EINVAL;
    if (ctx_id_ptr == 0 or ctx_id_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    // Find free slot
    var slot: ?u32 = null;
    for (0..MAX_CONTEXTS) |i| {
        if (!contexts[i].active) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot == null) return ENOMEM;

    const idx = slot.?;
    const cid = next_ctx_id;
    next_ctx_id += 1;

    contexts[idx] = .{
        .active = true,
        .id = cid,
        .max_events = @intCast(nr_events),
    };

    // Write context ID to user space (8 bytes)
    const copy = @import("../mm/copy_from_user.zig");
    var id_buf: [8]u8 = undefined;
    writeU64Le(&id_buf, cid);
    if (copy.copyToUser(@ptrFromInt(ctx_id_ptr), &id_buf, 8) != 8) {
        contexts[idx] = .{};
        return EFAULT;
    }

    serial.writeString("[aio] setup ctx_id=");
    fmt.writeDecimal64(cid);
    serial.writeString(" max_events=");
    fmt.writeDecimal64(nr_events);
    serial.writeString("\n");

    return 0;
}

/// io_destroy(ctx_id) -> 0 or -errno
pub fn ioDestroy(ctx_id: u64) i64 {
    const flags = aio_lock.acquire();
    defer aio_lock.release(flags);

    const ctx = findByCtxId(ctx_id) orelse return EINVAL;
    ctx.* = .{};
    return 0;
}

/// io_submit(ctx_id, nr, iocbpp) -> number submitted or -errno
/// Simplified: executes I/O synchronously, queues completion events.
pub fn ioSubmit(ctx_id: u64, nr: u64, iocbpp: u64) i64 {
    const flags = aio_lock.acquire();
    defer aio_lock.release(flags);

    const ctx = findByCtxId(ctx_id) orelse return EINVAL;
    if (nr == 0) return 0;
    if (iocbpp == 0 or iocbpp >= 0x0000_8000_0000_0000) return EFAULT;

    const copy = @import("../mm/copy_from_user.zig");
    var submitted: u64 = 0;

    while (submitted < nr) : (submitted += 1) {
        // Read iocb pointer from iocbpp[submitted]
        var ptr_buf: [8]u8 = undefined;
        const ptr_addr = iocbpp + submitted * 8;
        if (copy.copyFromUser(&ptr_buf, @ptrFromInt(ptr_addr), 8) != 8) break;
        const iocb_ptr: u64 = bo.readU64Le(&ptr_buf);

        // Read iocb structure
        var iocb_buf: [@sizeOf(IoCb)]u8 = undefined;
        if (copy.copyFromUser(&iocb_buf, @ptrFromInt(iocb_ptr), @sizeOf(IoCb)) != @sizeOf(IoCb)) break;
        const iocb: *const IoCb = @ptrCast(@alignCast(&iocb_buf));

        // Execute I/O synchronously
        var result: i64 = 0;
        if (iocb.aio_lio_opcode == IOCB_CMD_PREAD) {
            result = executePread(iocb);
        } else if (iocb.aio_lio_opcode == IOCB_CMD_PWRITE) {
            result = executePwrite(iocb);
        } else if (iocb.aio_lio_opcode == IOCB_CMD_FSYNC or iocb.aio_lio_opcode == IOCB_CMD_FDSYNC) {
            result = executeFsync(iocb);
        } else if (iocb.aio_lio_opcode == IOCB_CMD_NOOP) {
            result = 0; // No-op: immediate success
        } else {
            result = EINVAL; // Unknown opcode
        }

        // Queue completion event
        if (ctx.event_count < MAX_EVENTS) {
            const ev = &ctx.events[ctx.event_tail];
            ev.* = .{
                .data = iocb.aio_data,
                .obj = iocb_ptr,
                .res = result,
                .res2 = 0,
            };
            ctx.event_tail = (ctx.event_tail + 1) % MAX_EVENTS;
            ctx.event_count += 1;
        }
    }

    return @intCast(submitted);
}

/// io_getevents(ctx_id, min_nr, nr, events, timeout) -> events read or -errno
pub fn ioGetevents(ctx_id: u64, min_nr: u64, nr: u64, events_ptr: u64, timeout_ptr: u64) i64 {
    _ = timeout_ptr; // simplified: no blocking
    _ = min_nr;
    const flags = aio_lock.acquire();
    defer aio_lock.release(flags);

    const ctx = findByCtxId(ctx_id) orelse return EINVAL;
    if (events_ptr == 0 or events_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    const copy = @import("../mm/copy_from_user.zig");
    const event_size = @sizeOf(IoEvent);
    var count: u64 = 0;
    const max_out: u64 = if (nr > ctx.event_count) ctx.event_count else nr;

    while (count < max_out) {
        const ev = &ctx.events[ctx.event_head];
        const dst = events_ptr + count * event_size;
        const ev_bytes: [*]const u8 = @ptrCast(ev);
        if (copy.copyToUser(@ptrFromInt(dst), ev_bytes[0..event_size], event_size) != event_size) {
            return if (count == 0) EFAULT else @intCast(count);
        }
        ctx.event_head = (ctx.event_head + 1) % MAX_EVENTS;
        ctx.event_count -= 1;
        count += 1;
    }

    // If min_nr not met and no blocking, still return what we have
    return @intCast(count);
}

/// io_cancel(ctx_id, iocb, result) -> 0 or -errno
pub fn ioCancel(ctx_id: u64, iocb: u64, result: u64) i64 {
    _ = iocb;
    _ = result;
    const flags = aio_lock.acquire();
    defer aio_lock.release(flags);

    _ = findByCtxId(ctx_id) orelse return EINVAL;
    // Cannot cancel already-completed synchronous operations
    return EINVAL;
}

// ── I/O execution helpers ──

fn executePread(iocb: *const IoCb) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const copy_mod = @import("../mm/copy_from_user.zig");

    const cur_idx = sched_mod.currentTaskIndex() orelse return EINVAL;
    const cur = task_mod.getTask(cur_idx) orelse return EINVAL;

    const fd: u32 = @intCast(iocb.aio_fildes);
    if (fd >= cur.fd_table.fds.len) return EINVAL;
    if (iocb.aio_buf == 0 or iocb.aio_buf >= 0x0000_8000_0000_0000) return EFAULT;
    if (iocb.aio_nbytes == 0) return 0;
    // A negative offset would trap the @intCast below; reject it up front.
    if (iocb.aio_offset < 0) return EINVAL;

    // Save offset, set to requested position, read via VFS, restore
    const saved_offset = cur.fd_table.fds[fd].offset;
    cur.fd_table.fds[fd].offset = @intCast(iocb.aio_offset);

    var remaining: usize = @intCast(@min(iocb.aio_nbytes, 0x7FFFFFFF));
    var total: usize = 0;
    var dst: u64 = iocb.aio_buf;

    while (remaining > 0) {
        const chunk = @min(remaining, 4096);
        var kbuf: [4096]u8 = undefined;
        const n = cur.fd_table.read(fd, &kbuf, chunk);
        if (n <= 0) break;
        // Credit what copyToUser delivered, not what the file produced —
        // bytes that never reached the user buffer were never read as far
        // as the caller is concerned (same rule as file_io.zig read).
        const written = copy_mod.copyToUser(@ptrFromInt(dst), kbuf[0..@intCast(n)], @intCast(n));
        total += written;
        dst += @as(u64, @intCast(written));
        remaining -= written;
        if (n < @as(i64, @intCast(chunk)) or written < @as(usize, @intCast(n))) break;
    }

    cur.fd_table.fds[fd].offset = saved_offset;
    return @intCast(total);
}

fn executePwrite(iocb: *const IoCb) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const copy_mod = @import("../mm/copy_from_user.zig");

    const cur_idx = sched_mod.currentTaskIndex() orelse return EINVAL;
    const cur = task_mod.getTask(cur_idx) orelse return EINVAL;

    const fd: u32 = @intCast(iocb.aio_fildes);
    if (fd >= cur.fd_table.fds.len) return EINVAL;
    if (iocb.aio_buf == 0 or iocb.aio_buf >= 0x0000_8000_0000_0000) return EFAULT;
    if (iocb.aio_nbytes == 0) return 0;
    // A negative offset would trap the @intCast below; reject it up front.
    if (iocb.aio_offset < 0) return EINVAL;

    // Save offset, set to requested position, write via VFS, restore
    const saved_offset = cur.fd_table.fds[fd].offset;
    cur.fd_table.fds[fd].offset = @intCast(iocb.aio_offset);

    var remaining: usize = @intCast(@min(iocb.aio_nbytes, 0x7FFFFFFF));
    var total: usize = 0;
    var src: u64 = iocb.aio_buf;

    while (remaining > 0) {
        const chunk = @min(remaining, 4096);
        var kbuf: [4096]u8 = undefined;
        const copied = copy_mod.copyFromUser(kbuf[0..chunk], @ptrFromInt(src), chunk);
        if (copied == 0) break;
        const n = cur.fd_table.write(fd, &kbuf, copied);
        if (n <= 0) break;
        total += @intCast(n);
        src += @as(u64, @intCast(n));
        remaining -= @intCast(n);
        if (n < @as(i64, @intCast(copied))) break;
    }

    cur.fd_table.fds[fd].offset = saved_offset;
    return @intCast(total);
}

/// Execute AIO fsync — sync file data to disk
fn executeFsync(iocb: *const IoCb) i64 {
    const sched_mod = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const writeback = @import("writeback.zig");
    const vfs_mod = @import("vfs.zig");

    const cur_idx = sched_mod.currentTaskIndex() orelse return EINVAL;
    const cur = task_mod.getTask(cur_idx) orelse return EINVAL;

    const fd: u32 = @intCast(iocb.aio_fildes);
    if (fd >= cur.fd_table.fds.len) return EINVAL;
    const desc = &cur.fd_table.fds[fd];

    // Determine filesystem type and flush writeback cache
    if (desc.fd_type == .ext2_file) {
        if (!writeback.invalidateFile(desc.inode_id, .ext2, ext2WriteFlush)) return EIO;
    } else if (desc.fd_type == .fat32_file) {
        if (!writeback.invalidateFile(desc.inode_id, .fat32, fat32WriteFlush)) return EIO;
    } else {
        _ = vfs_mod;
    }
    return 0;
}

// Returning true unconditionally would clear the dirty bit on a failed write,
// so the buffer is only considered flushed once every byte was accepted.
fn ext2WriteFlush(idx: u32, offset: u64, buf: [*]const u8, len: u32) bool {
    const ext2 = @import("ext2.zig");
    return ext2.writeFile(idx, @intCast(offset), buf, @intCast(len)) == len;
}

fn fat32WriteFlush(idx: u32, offset: u64, buf: [*]const u8, len: u32) bool {
    const fat32 = @import("fat32.zig");
    return fat32.writeFile(idx, @intCast(offset), buf, @intCast(len)) == len;
}

// ── Internal helpers ──

fn findByCtxId(ctx_id: u64) ?*AioContext {
    for (&contexts) |*ctx| {
        if (ctx.active and ctx.id == ctx_id) return ctx;
    }
    return null;
}

fn writeU64Le(dst: []u8, val: u64) void {
    for (0..8) |i| {
        dst[i] = @intCast((val >> @intCast(i * 8)) & 0xFF);
    }
}
