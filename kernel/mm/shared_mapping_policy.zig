//! Pure address-range policy for preserving MAP_SHARED mappings across fork.

pub fn contains(base: u64, pages: u64, address: u64, page_size: u64) bool {
    if (pages == 0 or page_size == 0) return false;
    const length = pages *| page_size;
    return address >= base and address - base < length;
}

test "shared mapping policy recognizes only addresses inside the region" {
    const std = @import("std");
    try std.testing.expect(contains(0x4000, 2, 0x4000, 0x1000));
    try std.testing.expect(contains(0x4000, 2, 0x4fff, 0x1000));
    try std.testing.expect(contains(0x4000, 2, 0x5000, 0x1000));
    try std.testing.expect(!contains(0x4000, 2, 0x6000, 0x1000));
    try std.testing.expect(!contains(0x4000, 0, 0x4000, 0x1000));
}
