//! Pure offset helpers for the getdents64 directory cursor.

/// Directory entry indices are u32; clamp a 64-bit file offset the same way
/// the ext2/devfs arms do so a huge lseek lands past EOF (0 entries) instead
/// of trapping on a truncating @intCast.
pub fn clampOffset(offset: u64) u32 {
    return @intCast(@min(offset, 0xFFFFFFFF));
}

/// Advance the cursor past `emitted` entries without wrapping u32 arithmetic
/// (start may sit at the 0xFFFFFFFF clamp).
pub fn nextOffset(start: u32, emitted: u32) u64 {
    return @as(u64, start) + emitted;
}
