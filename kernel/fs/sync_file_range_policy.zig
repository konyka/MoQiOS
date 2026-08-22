//! Pure validation and page-range derivation for sync_file_range(2).

pub const WAIT_BEFORE: u32 = 1;
pub const WRITE: u32 = 2;
pub const WAIT_AFTER: u32 = 4;
pub const ALLOWED_FLAGS: u32 = WAIT_BEFORE | WRITE | WAIT_AFTER;
pub const PAGE_SIZE: u64 = 4096;

pub const Range = struct {
    first_page: u64,
    page_count: u64,
};

pub const ValidationError = error{
    InvalidFlags,
    InvalidOffset,
    RangeOverflow,
};

/// nbytes == 0 is a valid empty request, not an implicit request to flush to
/// EOF. This keeps the kernel operation bounded and prevents whole-inode I/O.
pub fn validate(offset: u64, nbytes: u64, flags: u32) ValidationError!Range {
    if ((flags & ~ALLOWED_FLAGS) != 0) return error.InvalidFlags;
    if (offset > std.math.maxInt(i64)) return error.InvalidOffset;
    if (nbytes == 0) return .{ .first_page = 0, .page_count = 0 };
    if (offset > std.math.maxInt(u64) - nbytes) return error.RangeOverflow;

    const last_byte = offset + nbytes - 1;
    const first_page = offset / PAGE_SIZE;
    const last_page = last_byte / PAGE_SIZE;
    return .{
        .first_page = first_page,
        .page_count = last_page - first_page + 1,
    };
}

const std = @import("std");
