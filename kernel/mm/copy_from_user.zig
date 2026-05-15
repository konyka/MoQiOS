/// Safe user-space memory access with page fault recovery.
///
/// Current approach: direct copy with page fault handler as safety net.
/// If a fault occurs during the copy, the page fault handler kills the
/// offending user process (segfault).
///
/// TODO: Implement assembly-level fault recovery with RIP-range guard
/// for truly safe copy_from_user that doesn't kill the process on fault.

/// Global recovery state (for future assembly-based recovery).
var recovery_rip: u64 = 0;
var in_user_access: bool = false;

/// Called by page fault handler. Currently unused (direct copy approach).
pub fn checkFault() ?u64 {
    if (in_user_access and recovery_rip != 0) {
        in_user_access = false;
        return recovery_rip;
    }
    return null;
}

/// Safely copy bytes from user space to a kernel buffer.
/// Returns the number of bytes successfully copied.
/// For now, uses direct memory copy. The page fault handler will catch
/// invalid accesses and kill the offending process.
pub fn copyFromUser(dst: []u8, src_user: [*]const u8, count: usize) usize {
    const copy_len = if (count > dst.len) dst.len else count;
    if (copy_len == 0) return 0;

    for (0..copy_len) |i| {
        dst[i] = src_user[i];
    }
    return copy_len;
}

/// Safely copy bytes from kernel buffer to user space.
/// Returns the number of bytes successfully copied.
pub fn copyToUser(dst_user: [*]u8, src: []const u8, count: usize) usize {
    const copy_len = if (count > src.len) src.len else count;
    if (copy_len == 0) return 0;

    for (0..copy_len) |i| {
        dst_user[i] = src[i];
    }
    return copy_len;
}
