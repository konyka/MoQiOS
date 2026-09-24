//! Pure path hash for inotify watch tracking (kernel/fs/inotify.zig).

pub const IN_NONBLOCK: u32 = 0x800;
pub const IN_CLOEXEC: u32 = 0x80000;
pub const VALID_INIT_FLAGS: u32 = IN_NONBLOCK | IN_CLOEXEC;

pub fn initFlagsValid(flags: u32) bool {
    return (flags & ~VALID_INIT_FLAGS) == 0;
}

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
