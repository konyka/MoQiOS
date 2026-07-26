/// Zero-copy data transfer syscalls: sendfile and splice.
///
/// sendfile(out_fd, in_fd, offset_ptr, count) — kernel-buffered file→socket/pipe
/// splice(fd_in, off_in, fd_out, off_out, len, flags) — pipe-mediated transfer
///
/// Both operate entirely within kernel space: data is read from the source
/// into a 4 KB kernel bounce buffer and written to the destination, never
/// crossing the user/kernel boundary.
const vfs = @import("vfs.zig");
const tcp = @import("../net/tcp.zig");
const copy = @import("../mm/copy_from_user.zig");
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");

// ─── errno constants (negative, Linux convention) ─────────────────────────

const errno = @import("../lib/errno.zig");
const EBADF = errno.EBADF;
const EINVAL = errno.EINVAL;
const EFAULT = errno.EFAULT;

/// Maximum bytes transferred per single iteration (one page).
const CHUNK_SIZE: u64 = 8192; // 8KB chunks for better throughput

/// splice(2) flags.
pub const SPLICE_F_MOVE: u32 = 1;
pub const SPLICE_F_NONBLOCK: u32 = 2;

/// Destination type for kernelTransfer.
const DstType = enum { tcp_socket, pipe_write };

// ─── Internal helpers ─────────────────────────────────────────────────────

/// Obtain the current task's FD table. Returns null if no current task.
fn getCurrentFdTable() ?*vfs.FdTable {
    const cur_idx = sched.currentTaskIndex() orelse return null;
    const t = task_mod.getTask(cur_idx) orelse return null;
    return &t.fd_table;
}

/// Validate that `fd` is open and return its type.
fn fdType(fd_table: *vfs.FdTable, fd: u32) vfs.FdType {
    if (fd >= vfs.MAX_FDS) return .none;
    return fd_table.fds[fd].fd_type;
}

/// True if the fd type represents a seekable file that can act as a
/// sendfile input (ramdisk / FAT32 / ext2).
fn isFileFd(ft: vfs.FdType) bool {
    return ft == .ramdisk_file or ft == .fat32_file or ft == .ext2_file;
}

/// True if the fd type can be a sendfile output target (socket or pipe).
fn isSendfileOutFd(ft: vfs.FdType) bool {
    return ft == .tcp_socket or ft == .pipe_write;
}

/// True if the fd type is any pipe end.
fn isPipeFd(ft: vfs.FdType) bool {
    return ft == .pipe_read or ft == .pipe_write;
}

/// Read up to `count` bytes from a file fd at a specific offset into a
/// kernel buffer.  Advances the offset.  Returns bytes read (0 = EOF),
/// or negative errno.
fn readFileAt(fd_table: *vfs.FdTable, fd: u32, offset: *u64, buf: [*]u8, count: usize) i64 {
    const desc = &fd_table.fds[fd];

    switch (desc.fd_type) {
        .ramdisk_file => {
            const remaining = desc.file_size - offset.*;
            if (remaining == 0) return 0;
            const to_read: usize = if (@as(u64, count) > remaining) @intCast(remaining) else count;
            const src: [*]const u8 = @ptrFromInt(desc.file_data + offset.*);
            @memcpy(buf[0..to_read], src[0..to_read]);
            offset.* += to_read;
            return @intCast(to_read);
        },
        .fat32_file => {
            if (offset.* >= desc.file_size) return 0;
            const fat32 = @import("fat32.zig");
            const n = fat32.readFile(desc.fat32_file_idx, @intCast(offset.*), buf, @intCast(count));
            if (n > 0) offset.* += @intCast(n);
            return n;
        },
        .ext2_file => {
            if (offset.* >= desc.file_size) return 0;
            const ext2 = @import("ext2.zig");
            const n = ext2.readFile(desc.ext2_file_idx, @intCast(offset.*), buf, @intCast(count));
            if (n > 0) offset.* += @intCast(n);
            return n;
        },
        else => return EBADF,
    }
}

/// Write `count` bytes from a kernel buffer to a TCP socket fd.
/// Returns bytes written or negative errno.
fn writeTcpSocket(fd_table: *vfs.FdTable, fd: u32, buf: [*]const u8, count: usize) i64 {
    const desc = &fd_table.fds[fd];
    if (desc.fd_type != .tcp_socket) return EBADF;
    return tcp.tcpSend(desc.tcb_idx, buf, @intCast(count));
}

/// Write `count` bytes from a kernel buffer to a pipe write-end fd.
/// Returns bytes written or negative errno.
fn writePipeWrite(fd_table: *vfs.FdTable, fd: u32, buf: [*]const u8, count: usize) i64 {
    const desc = &fd_table.fds[fd];
    if (desc.fd_type != .pipe_write) return EBADF;
    return vfs.pipeWrite(desc.pipe_idx, buf, count);
}

/// Read up to `count` bytes from a pipe read-end fd into a kernel buffer.
/// Returns bytes read or negative errno.
fn readPipeRead(fd_table: *vfs.FdTable, fd: u32, buf: [*]u8, count: usize) i64 {
    const desc = &fd_table.fds[fd];
    if (desc.fd_type != .pipe_read) return EBADF;
    return vfs.pipeRead(desc.pipe_idx, buf, count);
}

/// Write `count` bytes from a kernel buffer to a file fd at its current
/// offset.  Returns bytes written or negative errno.
fn writeFileCurrent(fd_table: *vfs.FdTable, fd: u32, buf: [*]const u8, count: usize) i64 {
    return fd_table.write(fd, buf, count);
}

/// Kernel-bounce-buffer transfer from src_fd to dst_fd.
/// Reads `count` bytes (in chunks) from the source and writes them to the
/// destination, all within kernel space.  Returns total bytes moved.
fn kernelTransfer(
    fd_table: *vfs.FdTable,
    src_fd: u32,
    src_offset: *u64,
    dst_type: DstType,
    dst_fd: u32,
    count: u64,
) i64 {
    var remaining: u64 = count;
    var total: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;

    while (remaining > 0) {
        const chunk: usize = if (remaining > CHUNK_SIZE) CHUNK_SIZE else @intCast(remaining);

        // Read from source file
        const nread = readFileAt(fd_table, src_fd, src_offset, &kbuf, chunk);
        if (nread <= 0) {
            // EOF or error — return what we've transferred so far
            if (total > 0) return total;
            return if (nread < 0) nread else total;
        }

        const to_write: usize = @intCast(nread);

        // Write to destination
        const nwritten = switch (dst_type) {
            .tcp_socket => writeTcpSocket(fd_table, dst_fd, &kbuf, to_write),
            .pipe_write => writePipeWrite(fd_table, dst_fd, &kbuf, to_write),
        };

        if (nwritten <= 0) {
            // Destination error — return what we've transferred so far
            if (total > 0) return total;
            return if (nwritten < 0) nwritten else total;
        }

        total += nwritten;
        const done: u64 = @intCast(nwritten);
        if (done >= remaining) break;
        remaining -= done;

        // If destination wrote fewer bytes than we read, the file offset
        // was already advanced by the full read. We accept the slight
        // discrepancy — same as Linux's behavior with short writes.
        if (@as(usize, @intCast(nwritten)) < to_write) break;
    }

    return total;
}

// ─── Public syscall implementations ───────────────────────────────────────

/// sendfile(out_fd, in_fd, offset_ptr, count) → bytes_sent
///
/// in_fd  must be a seekable file (ramdisk / FAT32 / ext2).
/// out_fd must be a tcp_socket or pipe_write.
/// If offset_ptr != null, use and update it; otherwise use the file's
/// current offset.  Returns the number of bytes sent.
pub fn sysSendfile(out_fd: u32, in_fd: u32, offset_ptr: u64, count: u64) i64 {
    const fd_table = getCurrentFdTable() orelse return EBADF;

    // Validate input fd — must be a seekable file
    const in_type = fdType(fd_table, in_fd);
    if (!isFileFd(in_type)) return EBADF;

    // Validate output fd — must be socket or pipe
    const out_type = fdType(fd_table, out_fd);
    if (!isSendfileOutFd(out_type)) return EINVAL;

    if (count == 0) return 0;

    // Determine starting offset
    var offset: u64 = undefined;
    var update_user_offset = false;

    if (offset_ptr != 0) {
        // Read the offset value from user space
        if (offset_ptr >= 0x0000_8000_0000_0000) return EFAULT;
        if (!copy.validateUserBufferWritable(offset_ptr, 8)) return EFAULT;
        var offset_buf: [8]u8 = undefined;
        const copied = copy.copyFromUser(&offset_buf, @ptrFromInt(offset_ptr), 8);
        if (copied < 8) return EFAULT;
        offset = @bitCast(offset_buf);
        update_user_offset = true;
    } else {
        // Use the fd's current offset
        offset = fd_table.fds[in_fd].offset;
    }

    // If offset is past EOF, nothing to do
    if (offset >= fd_table.fds[in_fd].file_size) return 0;

    // Determine destination type
    const dst_type: DstType = switch (out_type) {
        .tcp_socket => .tcp_socket,
        .pipe_write => .pipe_write,
        else => unreachable,
    };

    const result = kernelTransfer(fd_table, in_fd, &offset, dst_type, out_fd, count);

    // Update the fd offset (whether user-provided or not)
    fd_table.fds[in_fd].offset = offset;

    // Write back the new offset to user space if offset_ptr was provided
    if (update_user_offset and result > 0) {
        var offset_buf: [8]u8 = @bitCast(offset);
        if (copy.copyToUser(@ptrFromInt(offset_ptr), &offset_buf, 8) != 8) return EFAULT;
    }

    return result;
}

/// splice(fd_in, off_in, fd_out, off_out, len, flags) → bytes_moved
///
/// At least one of fd_in / fd_out must refer to a pipe.
/// Supported combinations:
///   - pipe_read → tcp_socket
///   - file → pipe_write
///   - pipe_read → file
///   - pipe_read → pipe_write
pub fn sysSplice(fd_in: u32, off_in: u64, fd_out: u32, off_out: u64, len: u64, flags: u32) i64 {
    _ = off_out; // output offsets not supported yet
    _ = flags; // flags are accepted but currently informational only

    const fd_table = getCurrentFdTable() orelse return EBADF;

    const in_type = fdType(fd_table, fd_in);
    const out_type = fdType(fd_table, fd_out);

    // At least one end must be a pipe
    if (!isPipeFd(in_type) and !isPipeFd(out_type)) return EINVAL;

    if (len == 0) return 0;

    // ── Case 1: pipe_read → tcp_socket ──────────────────────────────────
    if (in_type == .pipe_read and out_type == .tcp_socket) {
        return splicePipeToSocket(fd_table, fd_in, fd_out, len);
    }

    // ── Case 2: file → pipe_write ────────────────────────────────────────
    if (isFileFd(in_type) and out_type == .pipe_write) {
        return spliceFileToPipe(fd_table, fd_in, off_in, fd_out, len);
    }

    // ── Case 3: pipe_read → file ─────────────────────────────────────────
    if (in_type == .pipe_read and isFileFd(out_type)) {
        return splicePipeToFile(fd_table, fd_in, fd_out, len);
    }

    // ── Case 4: pipe_read → pipe_write ───────────────────────────────────
    if (in_type == .pipe_read and out_type == .pipe_write) {
        return splicePipeToPipe(fd_table, fd_in, fd_out, len);
    }

    return EINVAL;
}

/// pipe → socket: read from pipe, send to TCP.
fn splicePipeToSocket(fd_table: *vfs.FdTable, pipe_fd: u32, sock_fd: u32, len: u64) i64 {
    var remaining: u64 = len;
    var total: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;

    while (remaining > 0) {
        const chunk: usize = if (remaining > CHUNK_SIZE) CHUNK_SIZE else @intCast(remaining);

        const nread = readPipeRead(fd_table, pipe_fd, &kbuf, chunk);
        if (nread <= 0) {
            if (total > 0) return total;
            return if (nread < 0) nread else total;
        }

        const to_send: usize = @intCast(nread);
        const nsent = writeTcpSocket(fd_table, sock_fd, &kbuf, to_send);
        if (nsent <= 0) {
            if (total > 0) return total;
            return if (nsent < 0) nsent else total;
        }

        total += nsent;
        const done: u64 = @intCast(nsent);
        if (done >= remaining) break;
        remaining -= done;
        if (@as(usize, @intCast(nsent)) < to_send) break;
    }

    return total;
}

/// file → pipe: read from file at the given (or current) offset, write to pipe.
fn spliceFileToPipe(fd_table: *vfs.FdTable, file_fd: u32, off_in: u64, pipe_fd: u32, len: u64) i64 {
    var offset: u64 = undefined;
    var update_user_offset = false;

    if (off_in != 0) {
        // Read offset from user space
        if (off_in >= 0x0000_8000_0000_0000) return EFAULT;
        if (!copy.validateUserBufferWritable(off_in, 8)) return EFAULT;
        var offset_buf: [8]u8 = undefined;
        const copied = copy.copyFromUser(&offset_buf, @ptrFromInt(off_in), 8);
        if (copied < 8) return EFAULT;
        offset = @bitCast(offset_buf);
        update_user_offset = true;
    } else {
        offset = fd_table.fds[file_fd].offset;
    }

    var remaining: u64 = len;
    var total: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;

    while (remaining > 0) {
        const chunk: usize = if (remaining > CHUNK_SIZE) CHUNK_SIZE else @intCast(remaining);

        const nread = readFileAt(fd_table, file_fd, &offset, &kbuf, chunk);
        if (nread <= 0) {
            if (total > 0) return total;
            return if (nread < 0) nread else total;
        }

        const to_write: usize = @intCast(nread);
        const nwritten = writePipeWrite(fd_table, pipe_fd, &kbuf, to_write);
        if (nwritten <= 0) {
            if (total > 0) return total;
            return if (nwritten < 0) nwritten else total;
        }

        total += nwritten;
        const done: u64 = @intCast(nwritten);
        if (done >= remaining) break;
        remaining -= done;
        if (@as(usize, @intCast(nwritten)) < to_write) break;
    }

    // Update the fd offset
    fd_table.fds[file_fd].offset = offset;

    // Write back offset to user space if provided
    if (update_user_offset and total > 0) {
        var offset_buf: [8]u8 = @bitCast(offset);
        if (copy.copyToUser(@ptrFromInt(off_in), &offset_buf, 8) != 8) return EFAULT;
    }

    return total;
}

/// pipe → file: read from pipe, write to file.
fn splicePipeToFile(fd_table: *vfs.FdTable, pipe_fd: u32, file_fd: u32, len: u64) i64 {
    var remaining: u64 = len;
    var total: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;

    while (remaining > 0) {
        const chunk: usize = if (remaining > CHUNK_SIZE) CHUNK_SIZE else @intCast(remaining);

        const nread = readPipeRead(fd_table, pipe_fd, &kbuf, chunk);
        if (nread <= 0) {
            if (total > 0) return total;
            return if (nread < 0) nread else total;
        }

        const to_write: usize = @intCast(nread);
        const nwritten = writeFileCurrent(fd_table, file_fd, &kbuf, to_write);
        if (nwritten <= 0) {
            if (total > 0) return total;
            return if (nwritten < 0) nwritten else total;
        }

        total += nwritten;
        const done: u64 = @intCast(nwritten);
        if (done >= remaining) break;
        remaining -= done;
        if (@as(usize, @intCast(nwritten)) < to_write) break;
    }

    return total;
}

/// pipe → pipe: read from one pipe, write to another.
fn splicePipeToPipe(fd_table: *vfs.FdTable, in_fd: u32, out_fd: u32, len: u64) i64 {
    var remaining: u64 = len;
    var total: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;

    while (remaining > 0) {
        const chunk: usize = if (remaining > CHUNK_SIZE) CHUNK_SIZE else @intCast(remaining);

        const nread = readPipeRead(fd_table, in_fd, &kbuf, chunk);
        if (nread <= 0) {
            if (total > 0) return total;
            return if (nread < 0) nread else total;
        }

        const to_write: usize = @intCast(nread);
        const nwritten = writePipeWrite(fd_table, out_fd, &kbuf, to_write);
        if (nwritten <= 0) {
            if (total > 0) return total;
            return if (nwritten < 0) nwritten else total;
        }

        total += nwritten;
        const done: u64 = @intCast(nwritten);
        if (done >= remaining) break;
        remaining -= done;
        if (@as(usize, @intCast(nwritten)) < to_write) break;
    }

    return total;
}
