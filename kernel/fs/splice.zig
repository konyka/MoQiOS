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
const dac = @import("dac.zig");
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");

// ─── errno constants (negative, Linux convention) ─────────────────────────

const errno = @import("../lib/errno.zig");
const EBADF = errno.EBADF;
const EINVAL = errno.EINVAL;
const EFAULT = errno.EFAULT;
const ENOTCONN = errno.ENOTCONN;

/// Maximum bytes transferred per single iteration (one page).
const CHUNK_SIZE: u64 = 8192; // 8KB chunks for better throughput

/// Linux sendfile's bounded ABI count for this kernel's file backends.
pub const MAX_SENDFILE_COUNT: u64 = 0x7FFF_FFFF;

/// splice(2) flags.
pub const SPLICE_F_MOVE: u32 = 1;
pub const SPLICE_F_NONBLOCK: u32 = 2;

/// Destination type for kernelTransfer.
const DstType = enum { tcp_socket, pipe_write };

pub const SpliceEndpoint = enum { file, pipe_read, pipe_write, tcp_socket, other };

pub fn validateSpliceFlags(flags: u32) i64 {
    return if ((flags & ~(SPLICE_F_MOVE | SPLICE_F_NONBLOCK)) != 0) EINVAL else 0;
}

pub fn validateSpliceOffsets(in_is_pipe: bool, off_in: u64, out_is_pipe: bool, off_out: u64) i64 {
    if (in_is_pipe and off_in != 0) return EINVAL;
    if (out_is_pipe and off_out != 0) return EINVAL;
    return 0;
}

pub fn classifySpliceEndpoints(in_type: SpliceEndpoint, out_type: SpliceEndpoint) bool {
    return (in_type == .pipe_read and (out_type == .tcp_socket or out_type == .file or out_type == .pipe_write)) or
        (in_type == .file and out_type == .pipe_write);
}

pub fn validateSendfileCount(count: u64) i64 {
    return if (count > MAX_SENDFILE_COUNT) EINVAL else 0;
}

pub fn validate32BitFileRange(offset: u64, count: u64) i64 {
    return if (offset > 0xFFFF_FFFF or count > 0xFFFF_FFFF - offset) EINVAL else 0;
}

pub fn transferCapacity(remaining: u64, destination_capacity: u64, chunk_size: u64) u64 {
    return @min(remaining, @min(chunk_size, destination_capacity));
}

pub fn acceptedProgress(requested: u64, written: i64) u64 {
    if (written <= 0) return 0;
    return @min(requested, @as(u64, @intCast(written)));
}

// ─── Internal helpers ─────────────────────────────────────────────────────

/// Obtain the current task's FD table. Returns null if no current task.
fn getCurrentFdTable() ?*vfs.FdTable {
    const cur_idx = sched.currentTaskIndex() orelse return null;
    const t = task_mod.getTask(cur_idx) orelse return null;
    return t.fd_table;
}

/// Validate that `fd` is open and return its type.
fn fdType(fd_table: *vfs.FdTable, fd: u32) vfs.FdType {
    if (fd >= vfs.MAX_FDS) return .none;
    return fd_table.fds[fd].fd_type;
}

fn fdIsOpen(fd_table: *vfs.FdTable, fd: u32) bool {
    return fd < vfs.MAX_FDS and fd_table.fds[fd].fd_type != .none;
}

fn readUserOffset(ptr: u64) ?u64 {
    if (ptr == 0 or !copy.validateUserBuffer(ptr, 8) or
        !copy.validateUserBufferWritable(ptr, 8)) return null;
    var buf: [8]u8 = undefined;
    if (copy.copyFromUser(&buf, @ptrFromInt(ptr), 8) != 8) return null;
    return @bitCast(buf);
}

fn writeUserOffset(ptr: u64, offset: u64) bool {
    var buf: [8]u8 = @bitCast(offset);
    return copy.copyToUser(@ptrFromInt(ptr), &buf, 8) == 8;
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
    if (!dac.descriptorCanRead(desc.status_flags)) return EBADF;

    switch (desc.fd_type) {
        .ramdisk_file => {
            if (offset.* >= desc.file_size) return 0;
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
    const result = tcp.tcpSend(desc.tcb_idx, buf, @intCast(count));
    if (result < 0 and !tcp.isEstablished(desc.tcb_idx)) return ENOTCONN;
    return result;
}

fn destinationCapacity(fd_table: *vfs.FdTable, fd: u32, dst_type: DstType) u64 {
    return switch (dst_type) {
        .tcp_socket => tcp.tcpSendSpace(fd_table.fds[fd].tcb_idx),
        .pipe_write => if (vfs.pipeState(fd_table.fds[fd].pipe_idx)) |state|
            if (state.writable) vfs.PIPE_BUF_SIZE - 1 - state.readable else 0
        else
            0,
    };
}

fn destinationPipeClosed(fd_table: *vfs.FdTable, fd: u32) bool {
    if (vfs.pipeState(fd_table.fds[fd].pipe_idx)) |state| return !state.read_open;
    return true;
}

fn tcpDestinationError(fd_table: *vfs.FdTable, fd: u32) i64 {
    return if (tcp.isEstablished(fd_table.fds[fd].tcb_idx)) 0 else ENOTCONN;
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
    return vfs.pipeRead(desc.pipe_idx, buf, count, 0);
}

/// Put back bytes dequeued from a pipe when the destination accepted less.
/// The pipe ring has exactly the freed space from the preceding read.
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
        if (dst_type == .tcp_socket) {
            const state_error = tcpDestinationError(fd_table, dst_fd);
            if (state_error < 0) return if (total > 0) total else state_error;
        }
        const capacity = destinationCapacity(fd_table, dst_fd, dst_type);
        if (capacity == 0) {
            if (dst_type == .pipe_write and destinationPipeClosed(fd_table, dst_fd)) {
                return if (total > 0) total else writePipeWrite(fd_table, dst_fd, &kbuf, 1);
            }
            break;
        }
        const bounded = @min(remaining, @min(CHUNK_SIZE, capacity));
        const chunk: usize = @intCast(bounded);
        const read_offset = src_offset.*;

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
            // The read only staged data. Do not consume bytes that the
            // destination did not accept.
            src_offset.* = read_offset;
            // Destination error — return what we've transferred so far
            if (total > 0) return total;
            return if (nwritten < 0) nwritten else total;
        }

        const accepted = @min(nwritten, @as(i64, @intCast(to_write)));
        src_offset.* = read_offset + @as(u64, @intCast(accepted));
        total += accepted;
        const done: u64 = @intCast(accepted);
        if (done >= remaining) break;
        remaining -= done;

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
    if (!fd_table.acquireTransferFd(in_fd)) return EBADF;
    defer fd_table.releaseTransferFd(in_fd);
    if (!fd_table.acquireTransferFd(out_fd)) return EBADF;
    defer fd_table.releaseTransferFd(out_fd);

    // Validate input fd — must be a seekable file
    if (!fdIsOpen(fd_table, in_fd) or !fdIsOpen(fd_table, out_fd)) return EBADF;
    const in_type = fdType(fd_table, in_fd);
    if (!isFileFd(in_type)) return EINVAL;

    // Validate output fd — must be socket or pipe
    const out_type = fdType(fd_table, out_fd);
    if (!isSendfileOutFd(out_type)) return EINVAL;
    if (!dac.descriptorCanRead(fd_table.fds[in_fd].status_flags)) return EBADF;

    if (count == 0) return 0;
    if (count > MAX_SENDFILE_COUNT) return EINVAL;
    if (out_type == .tcp_socket and !tcp.isEstablished(fd_table.fds[out_fd].tcb_idx)) return ENOTCONN;

    // Determine starting offset
    var offset: u64 = undefined;
    var update_user_offset = false;

    if (offset_ptr != 0) {
        // Read the offset value from user space
        // It is both an input and an output: preflight both permissions so
        // an invalid destination cannot be discovered after I/O begins.
        offset = readUserOffset(offset_ptr) orelse return EFAULT;
        update_user_offset = true;
    } else {
        // Use the fd's current offset
        offset = fd_table.fds[in_fd].offset;
    }

    // The file implementations use 32-bit offsets. Check the requested
    // range before any transfer or descriptor mutation.
    if (offset > 0xFFFF_FFFF or count > 0xFFFF_FFFF - offset) return EINVAL;

    // If offset is past EOF, nothing to do, but still honor explicit offset
    // writeback because the pointer is an in/out argument.
    if (offset >= fd_table.fds[in_fd].file_size) {
        if (update_user_offset and !writeUserOffset(offset_ptr, offset)) return EFAULT;
        return 0;
    }

    // Determine destination type
    const dst_type: DstType = switch (out_type) {
        .tcp_socket => .tcp_socket,
        .pipe_write => .pipe_write,
        else => unreachable,
    };

    const result = kernelTransfer(fd_table, in_fd, &offset, dst_type, out_fd, count);

    // An explicit offset is independent of the open file description's
    // position. Only the NULL-offset form advances the descriptor offset.
    if (!update_user_offset) fd_table.fds[in_fd].offset = offset;

    // Write back the new offset even when no bytes were accepted. The pointer
    // was preflighted above, and a writeback fault must not be hidden.
    if (update_user_offset) {
        if (!writeUserOffset(offset_ptr, offset))
            return if (result > 0) result else EFAULT;
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
    const fd_table = getCurrentFdTable() orelse return EBADF;
    if (!fd_table.acquireTransferFd(fd_in)) return EBADF;
    defer fd_table.releaseTransferFd(fd_in);
    if (!fd_table.acquireTransferFd(fd_out)) return EBADF;
    defer fd_table.releaseTransferFd(fd_out);

    if (!fdIsOpen(fd_table, fd_in) or !fdIsOpen(fd_table, fd_out)) return EBADF;
    if (validateSpliceFlags(flags) < 0) return EINVAL;

    const in_type = fdType(fd_table, fd_in);
    const out_type = fdType(fd_table, fd_out);

    // At least one end must be a pipe. Offset pointers are meaningful only
    // for the seekable endpoint and are rejected for stream endpoints.
    if (!isPipeFd(in_type) and !isPipeFd(out_type)) return EINVAL;
    if (validateSpliceOffsets(isPipeFd(in_type), off_in, isPipeFd(out_type), off_out) < 0) return EINVAL;

    // ── Case 1: pipe_read → tcp_socket ──────────────────────────────────
    if (in_type == .pipe_read and out_type == .tcp_socket) {
        if (len == 0) return 0;
        return splicePipeToSocket(fd_table, fd_in, fd_out, len);
    }

    // ── Case 2: file → pipe_write ────────────────────────────────────────
    if (isFileFd(in_type) and out_type == .pipe_write) {
        if (len == 0) return 0;
        return spliceFileToPipe(fd_table, fd_in, off_in, fd_out, len);
    }

    // ── Case 3: pipe_read → file ─────────────────────────────────────────
    if (in_type == .pipe_read and isFileFd(out_type)) {
        if (!fd_table.fds[fd_out].writable) return EBADF;
        if (len == 0) return 0;
        return splicePipeToFile(fd_table, fd_in, fd_out, off_out, len);
    }

    // ── Case 4: pipe_read → pipe_write ───────────────────────────────────
    if (in_type == .pipe_read and out_type == .pipe_write) {
        if (len == 0) return 0;
        return splicePipeToPipe(fd_table, fd_in, fd_out, len);
    }

    return EINVAL;
}

/// pipe → socket: read from pipe, send to TCP.
fn splicePipeToSocket(fd_table: *vfs.FdTable, pipe_fd: u32, sock_fd: u32, len: u64) i64 {
    const state_error = tcpDestinationError(fd_table, sock_fd);
    if (state_error < 0) return state_error;
    var remaining: u64 = len;
    var total: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;

    while (remaining > 0) {
        const capacity = tcp.tcpSendSpace(fd_table.fds[sock_fd].tcb_idx);
        if (capacity == 0) {
            const probe = writeTcpSocket(fd_table, sock_fd, &kbuf, 1);
            if (probe < 0) return if (total > 0) total else probe;
            break;
        }
        const chunk: usize = @intCast(@min(remaining, @min(CHUNK_SIZE, capacity)));

        var reservation: vfs.PipeReadToken = .{};
        const nread = vfs.pipeReserveRead(fd_table.fds[pipe_fd].pipe_idx, &kbuf, chunk, &reservation);
        if (nread <= 0) {
            if (total > 0) return total;
            return if (nread < 0) nread else total;
        }
        {
            defer vfs.pipeReleaseRead(reservation);
            const to_send: usize = @intCast(nread);
            const nsent = writeTcpSocket(fd_table, sock_fd, &kbuf, to_send);
            if (nsent <= 0) {
                if (total > 0) return total;
                return if (nsent < 0) nsent else total;
            }

            const accepted = @min(nsent, @as(i64, @intCast(to_send)));
            _ = vfs.pipeCommitRead(reservation, @intCast(accepted));
            total += accepted;
            const done: u64 = @intCast(accepted);
            if (done >= remaining) break;
            remaining -= done;
            if (@as(usize, @intCast(nsent)) < to_send) break;
        }
    }

    return total;
}

/// file → pipe: read from file at the given (or current) offset, write to pipe.
fn spliceFileToPipe(fd_table: *vfs.FdTable, file_fd: u32, off_in: u64, pipe_fd: u32, len: u64) i64 {
    var offset: u64 = undefined;
    var update_user_offset = false;

    // Check source permissions before EOF or destination-capacity shortcuts.
    if (!dac.descriptorCanRead(fd_table.fds[file_fd].status_flags)) return EBADF;

    if (off_in != 0) {
        // Read offset from user space
        offset = readUserOffset(off_in) orelse return EFAULT;
        update_user_offset = true;
    } else {
        offset = fd_table.fds[file_fd].offset;
    }

    if (offset > 0xFFFF_FFFF or len > 0xFFFF_FFFF - offset) return EINVAL;

    // If offset is past EOF, nothing to do.
    if (offset >= fd_table.fds[file_fd].file_size) {
        if (update_user_offset and !writeUserOffset(off_in, offset)) return EFAULT;
        return 0;
    }

    var remaining: u64 = len;
    var total: i64 = 0;
    var failure: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;
    while (remaining > 0) {
        const capacity = destinationCapacity(fd_table, pipe_fd, .pipe_write);
        if (capacity == 0) {
            if (destinationPipeClosed(fd_table, pipe_fd)) {
                const probe = writePipeWrite(fd_table, pipe_fd, &kbuf, 1);
                if (total == 0 and probe < 0) failure = probe;
            }
            break;
        }
        const chunk: usize = @intCast(@min(remaining, @min(CHUNK_SIZE, capacity)));

        const read_offset = offset;
        const nread = readFileAt(fd_table, file_fd, &offset, &kbuf, chunk);
        if (nread <= 0) {
            if (nread < 0 and total == 0) failure = nread;
            break;
        }

        const to_write: usize = @intCast(nread);
        const nwritten = writePipeWrite(fd_table, pipe_fd, &kbuf, to_write);
        if (nwritten <= 0) {
            offset = read_offset;
            if (nwritten < 0 and total == 0) failure = nwritten;
            break;
        }

        const accepted = @min(nwritten, @as(i64, @intCast(to_write)));
        offset = read_offset + @as(u64, @intCast(accepted));
        total += accepted;
        const done: u64 = @intCast(accepted);
        if (done >= remaining) break;
        remaining -= done;
        if (@as(usize, @intCast(nwritten)) < to_write) break;
    }

    if (!update_user_offset) {
        fd_table.fds[file_fd].offset = offset;
    } else if (!writeUserOffset(off_in, offset)) {
        return if (total > 0) total else EFAULT;
    }
    return if (total > 0) total else failure;
}

/// pipe → file: read from pipe, write to file.
fn splicePipeToFile(fd_table: *vfs.FdTable, pipe_fd: u32, file_fd: u32, off_out: u64, len: u64) i64 {
    var file_offset = fd_table.fds[file_fd].offset;
    var explicit_offset = false;
    if (off_out != 0) {
        file_offset = readUserOffset(off_out) orelse return EFAULT;
        explicit_offset = true;
    }
    if (file_offset > 0xFFFF_FFFF or len > 0xFFFF_FFFF - file_offset) return EINVAL;
    var remaining: u64 = len;
    var total: i64 = 0;
    var failure: i64 = 0;
    var kbuf: [CHUNK_SIZE]u8 = undefined;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, @min(CHUNK_SIZE, 0xFFFF_FFFF - file_offset)));
        if (chunk == 0) break;

        const read_state = file_offset;
        var reservation: vfs.PipeReadToken = .{};
        const nread = vfs.pipeReserveRead(fd_table.fds[pipe_fd].pipe_idx, &kbuf, chunk, &reservation);
        if (nread <= 0) {
            if (nread < 0 and total == 0) failure = nread;
            break;
        }
        {
            defer vfs.pipeReleaseRead(reservation);
            const to_write: usize = @intCast(nread);
            const nwritten = if (explicit_offset)
                fd_table.writeAtOffset(file_fd, &kbuf, to_write, file_offset)
            else
                writeFileCurrent(fd_table, file_fd, &kbuf, to_write);
            if (nwritten <= 0) {
                if (nwritten < 0 and total == 0) failure = nwritten;
                break;
            }

            const accepted = @min(nwritten, @as(i64, @intCast(to_write)));
            _ = vfs.pipeCommitRead(reservation, @intCast(accepted));
            file_offset = if (explicit_offset) read_state else fd_table.fds[file_fd].offset;
            if (explicit_offset) file_offset = read_state + @as(u64, @intCast(accepted));
            total += accepted;
            const done: u64 = @intCast(accepted);
            if (done >= remaining) break;
            remaining -= done;
            if (@as(usize, @intCast(nwritten)) < to_write) break;
        }
    }

    if (!explicit_offset) {
        fd_table.fds[file_fd].offset = file_offset;
    } else if (!writeUserOffset(off_out, file_offset)) {
        return if (total > 0) total else EFAULT;
    }
    return if (total > 0) total else failure;
}

/// pipe → pipe: read from one pipe, write to another.
fn splicePipeToPipe(fd_table: *vfs.FdTable, in_fd: u32, out_fd: u32, len: u64) i64 {
    var remaining: u64 = len;
    var total: i64 = 0;

    while (remaining > 0) {
        const moved = vfs.pipeTransfer(fd_table.fds[in_fd].pipe_idx, fd_table.fds[out_fd].pipe_idx, @intCast(@min(remaining, CHUNK_SIZE)));
        if (moved <= 0) {
            if (total > 0) return total;
            return moved;
        }
        total += moved;
        const done: u64 = @intCast(moved);
        if (done >= remaining) break;
        remaining -= done;
    }

    return total;
}
