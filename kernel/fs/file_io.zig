/// kernel/fs/file_io.zig — Core file I/O syscall implementations (read/write/open/close)
///
/// Extracted from syscall_entry.zig (v19.1).
const serial = @import("../arch/arch.zig").serial;
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const copy = @import("../mm/copy_from_user.zig");
const at_path = @import("at_path.zig");
const vfs_mod = @import("vfs.zig");

const EFAULT: i64 = 14;

/// write(fd, buf, count) → bytes written or -errno
/// A descriptor number is a full 64-bit register. Anything that does not fit a
/// u32 cannot name an open descriptor, so map it to maxInt(u32), which the fd
/// table rejects; a plain @intCast would panic the kernel for write(-1, ...).
fn fdIndex(fd: u64) u32 {
    return if (fd > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(fd);
}

pub fn write(fd: u64, buf: u64, count: u64) i64 {
    if (buf == 0 or buf >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    // stdout/stderr used to be hard-coded to the serial port before the fd
    // table was consulted — which made dup2(pipe, 1) redirection useless and
    // broke every shell pipeline. Unredirected fd 1/2 are `.special`
    // descriptors that fd_table.write routes to the serial console with the
    // same one-lock-per-chunk discipline, so go through the table instead.

    // VFS write
    if (sched_mod.currentTaskIndex()) |cur_idx| {
        if (task_mod.getTask(cur_idx)) |cur| {
            var pos: usize = 0;
            while (pos < n) {
                const chunk = @min(n - pos, 4096);
                var kbuf: [4096]u8 = undefined;
                const copied = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(buf + pos), chunk);
                if (copied == 0) break;
                const result = cur.fd_table.write(fdIndex(fd), &kbuf, copied);
                // Propagate a first-chunk error (e.g. -28 ENOSPC from the
                // writeback cache) instead of reporting a 0-byte write that
                // callers would retry forever — mirrors pwrite below.
                if (result < 0) {
                    if (pos == 0) return result;
                    break;
                }
                if (result == 0) break;
                pos += @intCast(result);
                if (result < @as(i64, @intCast(copied))) break;
            }
            return @intCast(pos);
        }
    }
    return -1;
}

/// open(name_ptr, flags) → fd or -1
pub fn open(name_ptr: u64, flags: u32) i64 {
    return openWithMode(name_ptr, flags, null);
}

/// Open with an optional creation mode; null preserves the legacy 0666 default.
pub fn openWithMode(name_ptr: u64, flags: u32, requested_mode: ?u32) i64 {
    return openAt(at_path.AT_FDCWD, name_ptr, flags, requested_mode);
}

/// openat(dirfd, name, flags, mode). A relative name is looked up from the
/// directory `dirfd` names when that is a directory on a mounted volume,
/// otherwise from the working directory as before.
pub fn openAt(dirfd: i64, name_ptr: u64, flags: u32, requested_mode: ?u32) i64 {
    if (name_ptr >= 0x0000_8000_0000_0000 or name_ptr == 0) return -14; // EFAULT

    var name_buf: [256]u8 = undefined;
    const copied = copy.copyPathFromUser(name_buf[0..], name_ptr, 255);
    const path_rc = @import("namespace_policy.zig").pathCopyErrno(name_buf[0..], copied, 255);
    if (path_rc != 0) return path_rc; // EFAULT or ENAMETOOLONG
    name_buf[if (copied < 255) copied else 255] = 0;

    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var joined: [256]u8 = undefined;
    const use_name = switch (at_path.resolve(cur, dirfd, name, &joined)) {
        .keep => name,
        .path => |p| p,
        .err => |e| return e,
    };

    const result = cur.fd_table.openWithCreationCredentials(use_name, flags, requested_mode, cur.umask_val, cur.euid, cur.egid, cur.effective_caps);
    return @bitCast(result);
}

/// read(fd, buf_ptr, count) → bytes read or -errno
pub fn read(fd: u32, buf_ptr: u64, count: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var pos: usize = 0;
    var faulted = false;
    var first_err: i64 = 0;
    while (pos < n) {
        const chunk = @min(n - pos, 4096);
        var kbuf: [4096]u8 = undefined;

        // Refuse before consuming. A pipe or socket hands its data over for
        // good, so discovering at copy time that the destination is read-only
        // means the bytes are simply gone.
        if (!copy.validateUserBufferWritable(buf_ptr + pos, chunk)) {
            faulted = true;
            break;
        }

        const result = cur.fd_table.read(fd, &kbuf, chunk);
        if (result < 0) {
            if (pos == 0) first_err = result;
            break;
        }
        if (result == 0) break;
        const got: usize = @intCast(result);
        // Count what reached the user buffer, not what came off the file:
        // copyToUser refuses an unmapped or read-only destination, and
        // crediting those bytes would report a read that never landed.
        const written = copy.copyToUser(@ptrFromInt(buf_ptr + pos), kbuf[0..got], got);
        pos += written;
        if (written < got) {
            faulted = true;
            break;
        }
        if (got < chunk) break;
        if (pos < n) {
            const desc = &cur.fd_table.fds[fd];
            const regular = switch (desc.fd_type) {
                .ramdisk_file, .fat32_file, .ext2_file, .tmpfs_file, .rofs_file, .proc_file => true,
                else => false,
            };
            if (!@import("namespace_policy.zig").readContinues(regular, regular or (@import("poll.zig").descEvents(desc) & 1) != 0)) break;
        }
    }
    if (faulted and pos == 0) return -EFAULT;
    // A genuine error is returned, never re-issued: re-reading after an error
    // would consume more from a pipe and could turn the error into a bogus
    // 1-byte success. The fallback below is only for the EOF-ish 0 return.
    if (pos == 0 and first_err < 0) return first_err;
    if (pos == 0 and n > 0) {
        // v53.45: Fix 1-byte read not being copied to user space
        var tmp: [1]u8 = undefined;
        const r = cur.fd_table.read(fd, &tmp, 1);
        if (r > 0) {
            if (copy.copyToUser(@ptrFromInt(buf_ptr), &tmp, 1) == 0) return -EFAULT;
        }
        return @bitCast(r);
    }
    return @intCast(pos);
}

/// close(fd) → 0 or -1
pub fn close(fd: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const result = cur.fd_table.close(fd);
    return @bitCast(result);
}

/// pread64(fd, buf_ptr, count, offset) → bytes read or -errno
/// Reads from a file at a specific offset without changing the fd's current position.
pub fn pread(fd: u32, buf_ptr: u64, count: u64, offset: u64) i64 {
    const off_rc = @import("namespace_policy.zig").positionedOffsetErrno(offset);
    if (off_rc != 0) return off_rc;
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var pos: usize = 0;
    var current_offset = offset;
    var faulted = false;
    while (pos < n) {
        const chunk = @min(n - pos, 4096);
        var kbuf: [4096]u8 = undefined;
        if (!copy.validateUserBufferWritable(buf_ptr + pos, chunk)) {
            faulted = true;
            break;
        }
        const result = cur.fd_table.readAtOffset(fd, &kbuf, chunk, current_offset);
        if (result < 0) {
            if (pos == 0) return result;
            break;
        }
        if (result == 0) break;
        const got: usize = @intCast(result);
        const written = copy.copyToUser(@ptrFromInt(buf_ptr + pos), kbuf[0..got], got);
        pos += written;
        current_offset += written;
        if (written < got) {
            faulted = true;
            break;
        }
        if (got < chunk) break;
    }

    if (faulted and pos == 0) return -EFAULT;
    return @intCast(pos);
}

/// pwrite64(fd, buf_ptr, count, offset) → bytes written or -errno
/// Writes to a file at a specific offset without changing the fd's current position.
pub fn pwrite(fd: u32, buf_ptr: u64, count: u64, offset: u64) i64 {
    const off_rc = @import("namespace_policy.zig").positionedOffsetErrno(offset);
    if (off_rc != 0) return off_rc;
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or count > 0x7FFFFFFF) return -1;
    const n: usize = @intCast(count);
    if (n == 0) return 0;

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var pos: usize = 0;
    var current_offset = offset;
    while (pos < n) {
        const chunk = @min(n - pos, 4096);
        var kbuf: [4096]u8 = undefined;
        const copied = copy.copyFromUser(kbuf[0..chunk], @ptrFromInt(buf_ptr + pos), chunk);
        if (copied == 0) break;
        const result = cur.fd_table.writeAtOffset(fd, &kbuf, copied, current_offset);
        if (result < 0) {
            if (pos == 0) return result;
            break;
        }
        if (result == 0) break;
        pos += @intCast(result);
        current_offset += @intCast(result);
        if (result < @as(i64, @intCast(copied))) break;
    }

    return @intCast(pos);
}
