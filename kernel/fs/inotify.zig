// kernel/fs/inotify.zig — Inotify subsystem
//
// Provides inotify_init, inotify_add_watch, inotify_rm_watch.

const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("vfs.zig");
const copy = @import("../mm/copy_from_user.zig");

const MAX_INOTIFY_INSTANCES: u32 = 16;
const MAX_INOTIFY_WATCHES: u32 = 32;

pub const InotifyWatch = struct {
    active: bool = false,
    wd: i32 = 0,
    inode_id: u64 = 0,
    mask: u32 = 0,
};

pub const InotifyInstance = struct {
    active: bool = false,
    watches: [MAX_INOTIFY_WATCHES]InotifyWatch = @splat(.{}),
    next_wd: i32 = 1,
};

pub var inotify_instances: [MAX_INOTIFY_INSTANCES]InotifyInstance = @splat(.{});

/// Allocate an inotify instance and a file descriptor. Returns fd or -errno.
pub fn inotifyInit() i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    var inst_idx: u32 = MAX_INOTIFY_INSTANCES;
    for (0..MAX_INOTIFY_INSTANCES) |i| {
        if (!inotify_instances[i].active) {
            inst_idx = @intCast(i);
            break;
        }
    }
    if (inst_idx >= MAX_INOTIFY_INSTANCES) return -24; // ENFILE
    inotify_instances[inst_idx] = .{ .active = true };

    const slot = cur.fd_table.allocFd() orelse {
        inotify_instances[inst_idx].active = false;
        return -24;
    };

    cur.fd_table.fds[slot] = .{
        .fd_type = .inotify,
        .inotify_idx = inst_idx,
    };
    cur.fd_table.publishFd(slot);
    return @intCast(slot);
}

/// Add or update a watch on an inotify fd. Returns wd or -errno.
pub fn addWatch(fd: u32, path_ptr: u64, mask: u32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type != .inotify) return -9;
    const inst_idx = cur.fd_table.fds[fd].inotify_idx;
    if (inst_idx >= MAX_INOTIFY_INSTANCES or !inotify_instances[inst_idx].active) return -9;

    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return -14;
    var path_buf: [256]u8 = undefined;
    const n = copy.copyFromUser(path_buf[0..], @ptrFromInt(path_ptr), 255);
    if (n == 0) return -14;
    path_buf[if (n < 255) n else 255] = 0;
    var path_len: usize = 0;
    while (path_len < 256 and path_buf[path_len] != 0) : (path_len += 1) {}

    // Use hash of path as inode_id for watch tracking
    var inode_id: u64 = 0;
    for (0..path_len) |i| {
        inode_id = inode_id * 31 + path_buf[i];
    }

    const inst = &inotify_instances[inst_idx];
    // Update existing watch if found
    for (0..MAX_INOTIFY_WATCHES) |i| {
        if (inst.watches[i].active and inst.watches[i].inode_id == inode_id) {
            inst.watches[i].mask = mask;
            return @intCast(inst.watches[i].wd);
        }
    }
    // Add new watch
    for (0..MAX_INOTIFY_WATCHES) |i| {
        if (!inst.watches[i].active) {
            const wd = inst.next_wd;
            inst.next_wd += 1;
            inst.watches[i] = .{ .active = true, .wd = wd, .inode_id = inode_id, .mask = mask };
            return @intCast(wd);
        }
    }
    return -28; // ENOSPC
}

/// Remove a watch by wd. Returns 0 or -errno.
pub fn rmWatch(fd: u32, wd: i32) i64 {
    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS or cur.fd_table.fds[fd].fd_type != .inotify) return -9;
    const inst_idx = cur.fd_table.fds[fd].inotify_idx;
    if (inst_idx >= MAX_INOTIFY_INSTANCES or !inotify_instances[inst_idx].active) return -9;

    const inst = &inotify_instances[inst_idx];
    for (0..MAX_INOTIFY_WATCHES) |i| {
        if (inst.watches[i].active and inst.watches[i].wd == wd) {
            inst.watches[i].active = false;
            return 0;
        }
    }
    return -22; // EINVAL
}
