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

const guard = @import("kernel_shared").rofs_guard_policy;

test "rofs guard table names every path operand of the mutating syscalls" {
    const rename = guard.lookup(82).?;
    try std.testing.expectEqual(@as(u8, 0), rename.a);
    try std.testing.expectEqual(@as(u8, 1), rename.b);
    // symlink: only the link path (arg 1) is created, the target is plain data
    const sym = guard.lookup(88).?;
    try std.testing.expectEqual(@as(u8, 1), sym.a);
    try std.testing.expectEqual(guard.NONE, sym.b);
    // renameat2: oldpath in rsi relative to rdi, newpath in r10 relative to rdx
    const r2 = guard.lookup(261).?;
    try std.testing.expectEqual(@as(u8, 1), r2.a);
    try std.testing.expectEqual(@as(u8, 3), r2.b);
    try std.testing.expectEqual(@as(u8, 0), r2.da);
    try std.testing.expectEqual(@as(u8, 2), r2.db);
    // the single-path *at() mutators resolve rsi against the dirfd in rdi
    for ([_]u64{ 256, 257, 260, 452, 463, 466 }) |nr| {
        const e = guard.lookup(nr).?;
        try std.testing.expectEqual(@as(u8, 1), e.a);
        try std.testing.expectEqual(@as(u8, 0), e.da);
    }
    // a plain-path call has no dirfd
    try std.testing.expectEqual(guard.NONE, guard.lookup(87).?.da);
}

test "unlinkat flags: AT_REMOVEDIR selects rmdir, anything else is EINVAL" {
    try std.testing.expectEqual(guard.UnlinkAtAction.unlink, guard.unlinkAtAction(0));
    try std.testing.expectEqual(guard.UnlinkAtAction.rmdir, guard.unlinkAtAction(0x200));
    try std.testing.expectEqual(guard.UnlinkAtAction.invalid, guard.unlinkAtAction(0x1));
    try std.testing.expectEqual(guard.UnlinkAtAction.invalid, guard.unlinkAtAction(0x200 | 0x100));
    try std.testing.expectEqual(@as(?guard.Entry, null), guard.lookup(0));
    try std.testing.expectEqual(@as(?guard.Entry, null), guard.lookup(10)); // read
    // every entry is unique
    for (guard.table, 0..) |e, i| {
        for (guard.table[i + 1 ..]) |f| try std.testing.expect(e.nr != f.nr);
    }
}
