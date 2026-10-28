/// unlink — delete a file by path.
///
/// Tries ext2 first, then FAT32; an ext2 permission denial is final.
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const ext2 = @import("../fs/ext2.zig");
const fat32 = @import("../fs/fat32.zig");
const sched = @import("../proc/sched.zig");

/// Copy a NUL-terminated user path into a kernel buffer. Shared by the
/// unlink/rmdir wrappers; a 256-byte buffer matches every other path-taking
/// syscall (the old 64-byte unlink buffer silently truncated long paths and
/// deleted the wrong file).
fn copyPath(path_ptr: u64, buf: *[256]u8) ?[]const u8 {
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return null;
    const copied = copy.copyFromUser(buf[0..], @ptrFromInt(path_ptr), 255);
    if (copied == 0) return null;
    buf[if (copied < 255) copied else 255] = 0;
    var name_len: usize = 0;
    while (name_len < copied and buf[name_len] != 0) : (name_len += 1) {}
    return buf[0..name_len];
}

fn tmpfsCaller() ?@import("../fs/tmpfs.zig").Remover {
    const cur = sched.currentTask() orelse return null;
    return .{ .euid = cur.euid, .egid = cur.egid, .effective_caps = cur.effective_caps };
}

fn caller() ?@import("../fs/ext2.zig").Who {
    const cur = sched.currentTask() orelse return null;
    return .{ .euid = cur.euid, .egid = cur.egid, .cap_dac_override = cur.effective_caps.cap_dac_override, .groups = cur.groups[0..cur.ngroups] };
}

/// unlink(path_ptr) -> 0 or -errno.
pub fn unlink(path_ptr: u64) i64 {
    var name_buf: [256]u8 = undefined;
    const name = copyPath(path_ptr, &name_buf) orelse return -1;

    // tmpfs: /tmp paths route there, mirroring the open path in vfs.zig.
    if (name.len >= 4 and name[0] == '/' and name[1] == 't' and name[2] == 'm' and name[3] == 'p') {
        const tmpfs = @import("../fs/tmpfs.zig");
        return tmpfs.tmpfsUnlinkAuthorized(name, tmpfsCaller());
    }

    // Try ext2 first
    if (ext2.isActive()) {
        const r = ext2.unlinkFile(name, caller());
        if (r == 0 or r == -13) return r;
    }

    // Try FAT32
    if (!fat32.isActive()) return -1;

    const file_count = fat32.getFileCount();
    var found_idx: ?u32 = null;
    for (0..file_count) |i| {
        const fname = fat32.getFileName(@intCast(i)) orelse continue;
        if (fname.len == name.len) {
            var match = true;
            for (fname, 0..) |c, j| {
                if (c != name[j]) { match = false; break; }
            }
            if (match) { found_idx = @intCast(i); break; }
        }
    }

    if (found_idx == null) return -2; // -ENOENT
    if (fat32.deleteFile(found_idx.?)) return 0;
    return -1;
}

/// rmdir(path_ptr) -> 0 or -errno. Empty-directory removal with POSIX
/// semantics: ext2 gets a real empty-dir implementation (unlink used to
/// accept directories and corrupt the namespace), tmpfs already validates.
pub fn rmdir(path_ptr: u64) i64 {
    var name_buf: [256]u8 = undefined;
    const name = copyPath(path_ptr, &name_buf) orelse return -1;

    if (name.len >= 4 and name[0] == '/' and name[1] == 't' and name[2] == 'm' and name[3] == 'p') {
        const tmpfs = @import("../fs/tmpfs.zig");
        return tmpfs.tmpfsUnlinkAuthorized(name, tmpfsCaller());
    }

    if (ext2.isActive()) {
        return ext2.rmdirFile(name, caller());
    }
    return -1;
}
