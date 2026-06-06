/// unlink — delete a file by path.
///
/// Tries ext2 first, then FAT32.
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const ext2 = @import("../fs/ext2.zig");
const fat32 = @import("../fs/fat32.zig");

/// unlink(path_ptr) -> 0 or -errno.
pub fn unlink(path_ptr: u64) i64 {
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return -1;

    var name_buf: [64]u8 = undefined;
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(path_ptr), 63);
    if (copied == 0) return -1;
    name_buf[if (copied < 63) copied else 63] = 0;
    var name_len: usize = 0;
    while (name_len < copied and name_buf[name_len] != 0) : (name_len += 1) {}
    const name = name_buf[0..name_len];

    // Try ext2 first
    if (ext2.isActive()) {
        if (ext2.unlinkFile(name)) return 0;
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
