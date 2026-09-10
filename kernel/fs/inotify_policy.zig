//! Pure path hash for inotify watch tracking (kernel/fs/inotify.zig).

/// Hash of the watched path used as the watch's inode_id. Wrapping ops keep
/// long paths (>= ~13 chars) from trapping on u64 overflow, same precedent
/// as dcache.hashName.
pub fn hashPathId(bytes: []const u8) u64 {
    var h: u64 = 0;
    for (bytes) |c| {
        h = h *% 31 +% c;
    }
    return h;
}
