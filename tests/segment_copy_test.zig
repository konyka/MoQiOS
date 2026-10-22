const std = @import("std");
const p = @import("kernel_shared").segment_copy_policy;

test "unaligned first page copies only what fits after the offset" {
    // devmgr-like: vaddr 0x1001ee0, 0x259a file bytes.
    const w = p.window(0x1001000, 0x1001ee0, 0x259a).?;
    try std.testing.expectEqual(@as(u64, 0xee0), w.page_off);
    try std.testing.expectEqual(@as(u64, 4096 - 0xee0), w.len);
    try std.testing.expectEqual(@as(u64, 0), w.file_off);
    try std.testing.expect(w.page_off + w.len <= p.PAGE_SIZE);
}

test "later pages continue exactly where the first page stopped" {
    const first = p.window(0x1001000, 0x1001ee0, 0x259a).?;
    const second = p.window(0x1002000, 0x1001ee0, 0x259a).?;
    try std.testing.expectEqual(@as(u64, 0), second.page_off);
    try std.testing.expectEqual(first.file_off + first.len, second.file_off);
}

test "no copy ever crosses a page, for every offset and size" {
    var vaddr: u64 = 0x1000000;
    while (vaddr < 0x1000000 + 4096) : (vaddr += 37) {
        const filesz: u64 = 3 * 4096 + 123;
        var copied: u64 = 0;
        var page: u64 = vaddr & ~@as(u64, 4095);
        while (page < vaddr + filesz) : (page += 4096) {
            if (p.window(page, vaddr, filesz)) |w| {
                try std.testing.expect(w.page_off + w.len <= p.PAGE_SIZE);
                try std.testing.expectEqual(copied, w.file_off);
                copied += w.len;
            }
        }
        try std.testing.expectEqual(filesz, copied);
    }
}

test "aligned segment and empty file part" {
    const w = p.window(0x2000000, 0x2000000, 100).?;
    try std.testing.expectEqual(@as(u64, 100), w.len);
    try std.testing.expectEqual(@as(?p.Window, null), p.window(0x2001000, 0x2000000, 100));
    try std.testing.expectEqual(@as(?p.Window, null), p.window(0x2000000, 0x2000000, 0));
}
