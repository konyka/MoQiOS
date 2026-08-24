/// Miscellaneous syscalls — sched_getaffinity, getcomm, closefrom, move_pages.
///
/// Extracted from syscall_entry.zig (v18.7).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const sched_getaffinity_policy = @import("../proc/sched_getaffinity_policy.zig");
const vfs_mod = @import("../fs/vfs.zig");

/// sched_getaffinity(pid, cpusetsize, mask_ptr) -> bytes copied or -errno.
pub fn schedGetaffinity(pid: u32, cpusetsize: u64, mask_ptr: u64) i64 {
    const cur = sched_mod.currentTask() orelse return -3; // -ESRCH
    const target = if (pid == 0) cur.tid else task_mod.findTaskByTid(pid);
    if (sched_getaffinity_policy.validatePid(pid, cur.tid, target != null) != 0) return -3; // -ESRCH
    if (mask_ptr == 0 or mask_ptr >= 0x0000_8000_0000_0000) return -14; // -EFAULT
    // Return CPU 0 only (single CPU affinity)
    var mask: [128]u8 = undefined;
    @memset(&mask, 0);
    mask[0] = 1; // CPU 0 set
    const to_copy: usize = @intCast(@min(cpusetsize, 128));
    return if (copy.copyToUser(@ptrFromInt(mask_ptr), &mask, to_copy) == to_copy) @intCast(to_copy) else -14;
}

/// getcomm(buf_ptr, size) -> bytes copied or -errno.
/// Custom syscall #432: get process comm name.
pub fn getcomm(buf_ptr: u64, size: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or size == 0) return -22; // -EINVAL
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;
    const to_copy: usize = @intCast(@min(size, 16));
    return if (copy.copyToUser(@ptrFromInt(buf_ptr), cur.comm[0..to_copy], to_copy) == to_copy) @intCast(to_copy) else -14;
}

/// closefrom(lowfd) -> 0 or -errno.
/// Close all file descriptors >= lowfd (minimum 3).
pub fn closefrom(lowfd: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -3; // -ESRCH
    const cur = task_mod.getTask(cur_idx) orelse return -3;
    const start = if (lowfd < 3) @as(u32, 3) else lowfd;
    var fd: u32 = start;
    while (fd < vfs_mod.MAX_FDS) : (fd += 1) {
        if (cur.fd_table.fds[fd].fd_type != .none) {
            _ = cur.fd_table.close(fd);
        }
    }
    return 0;
}

/// move_pages(pid, count, pages, nodes, status_ptr, flags) -> 0.
/// Move process pages to NUMA nodes. Stub: writes 0 for all status entries.
pub fn movePages(count: u64, status_ptr: u64) i64 {
    const capped = @min(count, 4096);
    if (capped > 0 and !copy.validateUserBufferWritable(status_ptr, @intCast(capped * 4))) return -14;
    if (status_ptr != 0 and status_ptr < 0x0000_8000_0000_0000 and count > 0) {
        const zero: i32 = 0;
        var i: u64 = 0;
        while (i < count and i < 4096) : (i += 1) {
            if (copy.copyToUser(@ptrFromInt(status_ptr + i * 4), @as([*]const u8, @ptrCast(&zero))[0..4], 4) != 4) return -14;
        }
    }
    return 0;
}
