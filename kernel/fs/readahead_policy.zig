//! Pure validation and page-range planning for readahead requests.

const std = @import("std");

pub const PAGE_SIZE: u64 = 4096;
pub const MAX_PAGES: u32 = 32;

pub const PageRange = struct {
    first_page: u64,
    page_count: u32,
};

pub const Error = error{
    InvalidOffset,
    RangeOverflow,
    TooManyPages,
};

pub fn validate(offset: u64, count: u64) Error!PageRange {
    if (offset > std.math.maxInt(i64)) return error.InvalidOffset;
    if (count == 0) return .{ .first_page = offset / PAGE_SIZE, .page_count = 0 };

    if (count > std.math.maxInt(u64) - offset) return error.RangeOverflow;
    const end = offset + count;

    const first_page = offset / PAGE_SIZE;
    const last_page = (end - 1) / PAGE_SIZE;
    const page_count = last_page - first_page + 1;
    if (page_count > MAX_PAGES) return error.TooManyPages;

    return .{
        .first_page = first_page,
        .page_count = @intCast(page_count),
    };
}
