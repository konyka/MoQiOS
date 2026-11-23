/// readv / writev / preadv / pwritev — vectored I/O operations.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const bo = @import("../lib/byte_order.zig");
const vfs_mod = @import("vfs.zig");

const iov_policy = @import("iovec_policy.zig");

const EBADF: i64 = -9;
const EFAULT: i64 = 14;

/// The iovec array as Linux's import_iovec sees it before any data moves: its total length, and for a source the readable bytes
/// from its start up to the first hole. `err` is the call's result when the array itself is unreadable (EFAULT), or an entry has a
/// negative length (EINVAL) or leaves user space (EFAULT).
const Scan = struct { err: ?i64 = null, total: usize = 0, readable: usize = 0 };

fn scanIovecs(iov_ptr: u64, iovcnt: u32, want_readable: bool) Scan {
    var s: Scan = .{};
    var hole = false;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        if (copy.copyFromUser(&iov_buf, @ptrFromInt(iov_ptr +% @as(u64, @intCast(i)) * 16), 16) < 16) return .{ .err = -EFAULT };
        const base: u64 = bo.readU64At(&iov_buf, 0);
        const len: u64 = bo.readU64At(&iov_buf, 8);
        if (iov_policy.entryError(base, len)) |e| return .{ .err = e };
        const n: usize = @intCast(@min(len, 0x7FFFFFFF));
        s.total +|= n;
        if (want_readable and !hole and n != 0) {
            const r = copy.readablePrefix(base, n);
            s.readable += r;
            hole = r < n;
        }
    }
    return s;
}

/// The checks every vectored call makes first, in Linux's order: a bad descriptor (EBADF), too many iovecs (EINVAL), none at all
/// (0, nothing moves), an unreadable array or bad entry (scanIovecs). null means go ahead with `scan`.
fn precheck(fd: u32, iov_ptr: u64, iovcnt: u32, want_readable: bool, scan: *Scan) ?i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    if (fd >= cur.fd_table.fds.len or cur.fd_table.fds[fd].fd_type == .none) return EBADF;
    if (iovcnt > 1024) return -22;
    if (iovcnt == 0) return 0;
    scan.* = scanIovecs(iov_ptr, iovcnt, want_readable);
    return scan.err;
}

/// readv(fd, iov_ptr, iovcnt) -> bytes read or -errno.
pub fn readv(fd: u32, iov_ptr: u64, iovcnt: u32) i64 {
    var scan: Scan = .{};
    if (precheck(fd, iov_ptr, iovcnt, false, &scan)) |r| return r;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    // One readv() covers one contiguous range of a shared description: its offset lock is held across every iovec.
    const held = if (fd < vfs_mod.MAX_FDS) vfs_mod.lockOffset(&cur.fd_table.fds[fd]) else 0;
    defer vfs_mod.unlockOffset(held);
    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        // A NULL base is not skipped: it faults when reached (precheck already refused bases outside user space).
        if (iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            // Refuse before consuming: whatever comes off a pipe or socket
            // cannot be put back if the destination turns out to be unwritable.
            if (!copy.validateUserBufferWritable(iov_base + pos, chunk)) {
                if (total == 0 and pos == 0) return -EFAULT;
                break;
            }
            const result = cur.fd_table.readHeld(fd, &kbuf, chunk, held);
            if (result <= 0) {
                if (total == 0 and pos == 0) return @bitCast(result);
                break;
            }
            const got: usize = @intCast(result);
            const written = copy.copyToUser(@ptrFromInt(iov_base + pos), kbuf[0..got], got);
            pos += written;
            if (written < got) break;
            if (got < chunk) break;
        }
        total += pos;
        if (pos < n) break;
    }
    return @intCast(total);
}

/// writev(fd, iov_ptr, iovcnt) -> bytes written or -errno.
pub fn writev(fd: u32, iov_ptr: u64, iovcnt: u32) i64 {
    var scan: Scan = .{};
    if (precheck(fd, iov_ptr, iovcnt, true, &scan)) |r| return r;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const append_call = cur.fd_table.isAppendFile(fd);
    if (append_call) cur.fd_table.lockAppendCall(fd);
    defer if (append_call) cur.fd_table.unlockAppendCall(fd);
    // One writev() covers one contiguous range of a shared description: its offset lock is held across every iovec.
    const held = if (fd < vfs_mod.MAX_FDS) vfs_mod.lockOffset(&cur.fd_table.fds[fd]) else 0;
    defer vfs_mod.unlockOffset(held);
    // A pipe accounts for the whole writev() as one write (anon_pipe_write sees one iov_iter). It copies the source a page at a time
    // and drops a page whose copy faults, so a source that runs into a hole goes in only as whole pages before the hole (EFAULT when
    // there are none; with a partly filled last buffer the remainder merges first, vfs.pipeFaultedTakes), however the iovecs split it:
    // the amount is settled before any of it goes in.
    const to_pipe = fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .pipe_write and cur.fd_table.fds[fd].writable;
    const whole: usize = if (to_pipe and scan.readable < scan.total) vfs_mod.pipeFaultedTakes(cur.fd_table.fds[fd].pipe_idx, scan.total, scan.readable) else scan.total;
    if (to_pipe and whole == 0 and scan.total != 0) return -EFAULT;
    var pipe_part: vfs_mod.PipeWritePart = .{ .total = whole };
    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        // A NULL base is not skipped: it faults when reached (precheck already refused bases outside user space).
        if (iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const left = if (to_pipe) whole - total - pos else n - pos;
            if (left == 0) break;
            const chunk = @min(n - pos, left, 4096);
            var kbuf: [4096]u8 = undefined;
            // The readable part of the piece: a source that runs into a hole is a short write of the bytes before it, and nothing
            // readable at all is EFAULT (not 0).
            const from_user = copy.copyFromUserPrefix(kbuf[0..chunk], iov_base + pos, chunk);
            if (from_user == 0) return if (total == 0 and pos == 0) -EFAULT else @intCast(total + pos);
            const result = if (to_pipe)
                vfs_mod.pipeWritePart(cur.fd_table.fds[fd].pipe_idx, &kbuf, from_user, cur.fd_table.fds[fd].status_flags, &pipe_part)
            else
                cur.fd_table.writeHeld(fd, &kbuf, from_user, held);
            if (result <= 0) {
                if (total == 0 and pos == 0) return @bitCast(result);
                break;
            }
            pos += @intCast(result);
            if (result < @as(i64, @intCast(from_user))) break;
            if (from_user < chunk) break;
        }
        total += pos;
        if (pos < n) break;
    }
    return @intCast(total);
}

/// preadv(fd, iov_ptr, iovcnt, pos_l) -> bytes read or -errno.
pub fn preadv(fd: u32, iov_ptr: u64, iovcnt: u32, pos_l: u64) i64 {
    var scan: Scan = .{};
    if (precheck(fd, iov_ptr, iovcnt, false, &scan)) |r| return r;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var current_offset = pos_l;
    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        // A NULL base is not skipped: it faults when reached (precheck already refused bases outside user space).
        if (iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            if (!copy.validateUserBufferWritable(iov_base + pos, chunk)) {
                if (total == 0 and pos == 0) return -EFAULT;
                break;
            }
            const result = cur.fd_table.readAtOffset(fd, &kbuf, chunk, current_offset);
            if (result <= 0) {
                if (total == 0 and pos == 0) return @bitCast(result);
                break;
            }
            const got: usize = @intCast(result);
            const written = copy.copyToUser(@ptrFromInt(iov_base + pos), kbuf[0..got], got);
            pos += written;
            current_offset += written;
            if (written < got) break;
            if (got < chunk) break;
        }
        total += pos;
        if (pos < n) break;
    }

    return @intCast(total);
}

/// pwritev(fd, iov_ptr, iovcnt, pos_l) -> bytes written or -errno.
pub fn pwritev(fd: u32, iov_ptr: u64, iovcnt: u32, pos_l: u64) i64 {
    return pwritevMode(fd, iov_ptr, iovcnt, pos_l, .descriptor);
}

fn pwritevMode(fd: u32, iov_ptr: u64, iovcnt: u32, pos_l: u64, mode: vfs_mod.FdTable.AppendMode) i64 {
    var scan: Scan = .{};
    if (precheck(fd, iov_ptr, iovcnt, false, &scan)) |r| return r;
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    const append_call = switch (mode) {
        .descriptor => cur.fd_table.isAppendFile(fd),
        .append => cur.fd_table.isRegularWritableFile(fd),
        .no_append => false,
    };
    if (append_call) cur.fd_table.lockAppendCall(fd);
    defer if (append_call) cur.fd_table.unlockAppendCall(fd);
    var current_offset = pos_l;
    var total: usize = 0;
    for (0..iovcnt) |i| {
        var iov_buf: [16]u8 = undefined;
        const src: [*]const u8 = @ptrFromInt(iov_ptr + @as(u64, @intCast(i)) * 16);
        const copied = copy.copyFromUser(&iov_buf, src, 16);
        if (copied < 16) break;

        const iov_base: u64 = bo.readU64At(&iov_buf, 0);
        const iov_len: u64 = bo.readU64At(&iov_buf, 8);

        // A NULL base is not skipped: it faults when reached (precheck already refused bases outside user space).
        if (iov_len == 0) continue;

        const n: usize = @intCast(@min(iov_len, 0x7FFFFFFF));
        var pos: usize = 0;
        while (pos < n) {
            const chunk = @min(n - pos, 4096);
            var kbuf: [4096]u8 = undefined;
            const ucopy = copy.copyFromUserPrefix(kbuf[0..chunk], iov_base + pos, chunk);
            if (ucopy == 0) return if (total == 0 and pos == 0) -EFAULT else @intCast(total + pos);
            const result = cur.fd_table.writeAtOffsetMode(fd, &kbuf, ucopy, current_offset, mode);
            if (result < 0) return if (total == 0 and pos == 0) result else @intCast(total + pos);
            if (result == 0) break;
            pos += @intCast(result);
            const advanced, const overflow = @addWithOverflow(current_offset, @as(u64, @intCast(result)));
            if (overflow != 0) return if (total == 0 and pos == 0) -22 else @intCast(total + pos);
            current_offset = advanced;
            if (result < @as(i64, @intCast(ucopy))) break;
            if (ucopy < chunk) break;
        }
        total += pos;
        if (pos < n) break;
    }

    return @intCast(total);
}

/// preadv2(fd, iov_ptr, iovcnt, offset, flags): preadv with RWF_* flags. Offset -1 reads at the descriptor's position and advances it.
pub fn preadv2(fd: u32, iov_ptr: u64, iovcnt: u32, offset: i64, flags: u32) i64 {
    const rwf = @import("rwf_policy.zig");
    if (rwf.readFlagsValid(flags)) |e| return e;
    const nowait = NowaitGuard.begin(fd, rwf.wantsNowait(flags)) catch |e| return errnoOf(e);
    defer nowait.end();
    switch (rwf.offsetKind(offset)) {
        .invalid => return -22,
        .explicit => return preadv(fd, iov_ptr, iovcnt, @intCast(offset)),
        .current => return readv(fd, iov_ptr, iovcnt),
    }
}

const NowaitError = error{ BadFd, NotSupported };

fn errnoOf(e: NowaitError) i64 {
    return switch (e) {
        error.BadFd => EBADF,
        error.NotSupported => -95, // EOPNOTSUPP
    };
}

/// RWF_NOWAIT for one call: the descriptor behaves as O_NONBLOCK while the call runs and gets its own flags back afterwards. Only pipes and
/// sockets can block; a regular file is EOPNOTSUPP (Linux's tmpfs answers the same, it has no non-blocking file I/O).
const NowaitGuard = struct {
    desc: ?*vfs_mod.FileDescriptor = null,
    saved: u32 = 0,

    fn begin(fd: u32, wanted: bool) NowaitError!NowaitGuard {
        if (!wanted) return .{};
        const cur_idx = sched_mod.currentTaskIndex() orelse return error.BadFd;
        const cur = task_mod.getTask(cur_idx) orelse return error.BadFd;
        if (fd >= cur.fd_table.fds.len or cur.fd_table.fds[fd].fd_type == .none) return error.BadFd;
        const d = &cur.fd_table.fds[fd];
        switch (d.fd_type) {
            .pipe_read, .pipe_write, .unix_socket, .tcp_socket, .udp_socket => {},
            else => return error.NotSupported,
        }
        // Only this descriptor's copy changes: the open file description (shared by dup()s) keeps its own O_NONBLOCK, and
        // syncOffsetIn keeps the bit while force_nonblock is set.
        const saved = vfs_mod.statusFlagsOf(d);
        if (saved & 0x800 != 0) return .{};
        d.force_nonblock = true;
        d.status_flags = saved | 0x800;
        return .{ .desc = d, .saved = saved };
    }

    fn end(self: NowaitGuard) void {
        const d = self.desc orelse return;
        d.force_nonblock = false;
        d.status_flags = (vfs_mod.statusFlagsOf(d) & ~@as(u32, 0x800)) | (self.saved & 0x800);
    }
};

/// pwritev2(fd, iov_ptr, iovcnt, offset, flags): pwritev with RWF_* flags. RWF_APPEND appends even on a plain descriptor, RWF_NOAPPEND writes
/// at the offset even on an O_APPEND one; offset -1 writes at the descriptor's position (or appends on O_APPEND) and advances it.
pub fn pwritev2(fd: u32, iov_ptr: u64, iovcnt: u32, offset: i64, flags: u32) i64 {
    const rwf = @import("rwf_policy.zig");
    const mode: vfs_mod.FdTable.AppendMode = switch (rwf.writeMode(flags)) {
        .err => |e| return e,
        .ok => |m| switch (m) {
            .descriptor => .descriptor,
            .append => .append,
            .no_append => .no_append,
        },
    };
    const nowait = NowaitGuard.begin(fd, rwf.wantsNowait(flags)) catch |e| return errnoOf(e);
    defer nowait.end();
    const written = switch (rwf.offsetKind(offset)) {
        .invalid => return -22,
        .explicit => pwritevMode(fd, iov_ptr, iovcnt, @intCast(offset), mode),
        .current => writev(fd, iov_ptr, iovcnt),
    };
    if (written > 0 and rwf.wantsSync(flags)) {
        if (!syncDescriptor(fd)) return -5; // EIO: the data was written but could not be made durable
    }
    return written;
}

/// Flush a file descriptor's staged data to disk (RWF_DSYNC / RWF_SYNC). Non-file descriptors and tmpfs have nothing to flush.
fn syncDescriptor(fd: u32) bool {
    const cur_idx = sched_mod.currentTaskIndex() orelse return false;
    const cur = task_mod.getTask(cur_idx) orelse return false;
    if (fd >= cur.fd_table.fds.len) return false;
    const desc = &cur.fd_table.fds[fd];
    const wb_type: @import("writeback.zig").FsType = switch (desc.fd_type) {
        .ext2_file => .ext2,
        .fat32_file => .fat32,
        else => return true,
    };
    if (!vfs_mod.syncFile(desc.inode_id, wb_type)) return false;
    // Like fsync: also drain the volatile write cache of the disk FAT32 and ext2 live on (virtio-blk 0).
    const block_dev = @import("../drivers/block_dev.zig");
    const dev = block_dev.findByDriver(.virtio_blk, 0) orelse return true;
    if (!block_dev.supportsFlush(dev)) return true;
    return block_dev.flush(dev) == 0;
}

