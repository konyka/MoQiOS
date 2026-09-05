/// kernel/proc/process_mgmt.zig — Process management syscall implementations
///
/// Extracted from syscall_entry.zig (v19.1): getpid, getenv, pipe, dup2.
const serial = @import("../arch/arch.zig").serial;
const sched_mod = @import("sched.zig");
const task_mod = @import("task.zig");
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");

/// getpid() → current task TGID（线程返回其线程组 leader 的 tid）
pub fn getpid() i64 {
    if (sched_mod.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |current| {
            // POSIX 线程语义：进程内全部线程共享一个 pid（tgid）。
            if (current.is_thread and current.parent_tid != 0) {
                return @intCast(current.parent_tid);
            }
            return @intCast(current.tid);
        }
    }
    return 0;
}

/// getenv(key_ptr, val_ptr, val_max) → value length or -1
pub fn getenv(key_ptr: u64, val_ptr: u64, val_max: u64) i64 {
    if (key_ptr == 0 or key_ptr >= 0x0000_8000_0000_0000) return -22;

    const var_max = task_mod.ENV_VAR_BYTES - 1;
    var key_buf: [task_mod.ENV_VAR_BYTES]u8 = undefined;
    const copied = copy.copyFromUser(key_buf[0..], @ptrFromInt(key_ptr), var_max);
    if (copied == 0) return -1;
    key_buf[if (copied < var_max) copied else var_max] = 0;
    var key_len: usize = 0;
    while (key_len < copied and key_buf[key_len] != 0) : (key_len += 1) {}

    const current = sched_mod.currentTask() orelse return -1;

    for (0..current.env_count) |i| {
        const entry = current.env_vars[i][0..];
        var j: usize = 0;
        while (j < var_max and entry[j] != 0 and entry[j] != '=' and j < key_len) : (j += 1) {
            if (entry[j] != key_buf[j]) break;
        }
        if (j == key_len and entry[j] == '=') {
            const val_start = j + 1;
            var val_len: usize = 0;
            while (val_start + val_len < var_max and entry[val_start + val_len] != 0) : (val_len += 1) {}

            if (val_ptr != 0 and val_ptr < 0x0000_8000_0000_0000 and val_max > 0) {
                const to_copy = @min(val_len, val_max - 1);
                if (!copy.validateUserBufferWritable(val_ptr, to_copy + 1)) return -14;
                if (copy.copyToUser(@ptrFromInt(val_ptr), entry[val_start .. val_start + to_copy], to_copy) != to_copy) return -14;
                const zero: u8 = 0;
                if (copy.copyToUser(@ptrFromInt(val_ptr + to_copy), @as([*]const u8, @ptrCast(&zero))[0..1], 1) != 1) return -14;
            }
            return @intCast(val_len);
        }
    }

    return -1;
}

/// pipe(pipefd_ptr) → 0 or -1
pub fn pipe(pipefd_ptr: u64) i64 {
    if (pipefd_ptr == 0 or pipefd_ptr >= 0x0000_8000_0000_0000) return -1;
    if (!copy.validateUserBufferWritable(pipefd_ptr, 8)) return -14;

    if (sched_mod.currentTaskIndex()) |cur_idx| {
        if (task_mod.getTask(cur_idx)) |cur| {
            const result = cur.fd_table.createPipe();
            if (result < 0) return result;
            const read_fd: u32 = @intCast(result & 0xFFFF);
            const write_fd: u32 = @intCast(@as(u64, @intCast(result)) >> 16);

            var pipefd_bytes: [8]u8 = undefined;
            bo.writeU32Le(pipefd_bytes[0..4], read_fd);
            bo.writeU32Le(pipefd_bytes[4..8], write_fd);

            if (copy.copyToUser(@ptrFromInt(pipefd_ptr), pipefd_bytes[0..8], 8) != 8) {
                _ = cur.fd_table.close(read_fd);
                _ = cur.fd_table.close(write_fd);
                return -14;
            }
            return 0;
        }
    }
    return -1;
}

/// dup2(oldfd, newfd) → new fd or -1
pub fn dup2(oldfd: u32, newfd: u32) i64 {
    if (sched_mod.currentTaskIndex()) |cur_idx| {
        if (task_mod.getTask(cur_idx)) |cur| {
            const result = cur.fd_table.dup2(oldfd, newfd);
            return @bitCast(result);
        }
    }
    return -1;
}
