/// Pure validation for the munmap syscall's address arithmetic.
/// Keeping this separate makes the overflow and alignment contract testable
/// without constructing a kernel task or page table.
pub const PAGE_SIZE: u64 = 4096;
pub const USER_ADDR_MAX: u64 = 0x0000_8000_0000_0000;

pub const Range = struct {
    base: u64,
    num_pages: u64,
};

pub fn validate(addr: u64, length: u64) ?Range {
    // This kernel keeps unmapRange page-granular. Reject an unaligned length
    // rather than rounding it up and unmapping bytes outside the request.
    if (length == 0 or addr % PAGE_SIZE != 0 or length % PAGE_SIZE != 0) return null;
    const raw_end = @addWithOverflow(addr, length);
    if (raw_end[1] != 0 or raw_end[0] > USER_ADDR_MAX) return null;
    const rounded_end = @addWithOverflow(raw_end[0], PAGE_SIZE - 1);
    if (rounded_end[1] != 0) return null;
    const end = rounded_end[0] / PAGE_SIZE * PAGE_SIZE;
    if (end > USER_ADDR_MAX or end <= addr) return null;
    return .{ .base = addr, .num_pages = (end - addr) / PAGE_SIZE };
}

test "munmap policy requires alignment and rejects overflow" {
    const std = @import("std");
    try std.testing.expect(validate(0x4000, PAGE_SIZE).?.num_pages == 1);
    try std.testing.expect(validate(0x4000, 1) == null);
    try std.testing.expect(validate(0x4001, PAGE_SIZE) == null);
    try std.testing.expect(validate(USER_ADDR_MAX - PAGE_SIZE, PAGE_SIZE * 2) == null);
    try std.testing.expect(validate(std.math.maxInt(u64) - PAGE_SIZE, PAGE_SIZE) == null);
}
