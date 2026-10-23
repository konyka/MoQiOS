//! Host tests for kernel/fs/ntfs.zig against a real mkntfs image
//! (tools/fsfixtures/mkfixtures.sh): 512-byte sectors, 1 KiB clusters/records,
//! 4 KiB index blocks, resident + non-resident + sparse files, and a root
//! directory big enough to need $INDEX_ALLOCATION.

const std = @import("std");
const kt = @import("kernel_shared");
const ntfs = kt.ntfs;
const fr = kt.fs_reader;
const Image = @import("fs_image.zig").Image;

var scratch: ntfs.Scratch = undefined;

fn mountImage(img: *Image) !ntfs.Volume {
    return ntfs.Volume.mount(img.reader(), &scratch);
}

const path = "tests/fixtures/fs/ntfs.img";

fn bigByte(i: usize) u8 {
    return @truncate(i * 7 + i / 251);
}

fn readAll(v: *const ntfs.Volume, p: []const u8, out: []u8) !usize {
    const ref = try v.resolve(p, true);
    return v.read(ref, 0, out);
}

test "mount reads the boot sector geometry" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    try std.testing.expectEqual(@as(u32, 512), v.sector_size);
    try std.testing.expectEqual(@as(u32, 1024), v.cluster_size);
    try std.testing.expectEqual(@as(u32, 1024), v.record_size);
    try std.testing.expectEqual(@as(u32, 4096), v.index_block_size);
    try std.testing.expectEqual(@as(u64, 4095), v.total_clusters);
}

test "resident file, empty file and case-insensitive names" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    var buf: [64]u8 = undefined;
    const n = try readAll(&v, "/small.txt", &buf);
    try std.testing.expectEqualStrings("hello fs\n", buf[0..n]);
    const m = try readAll(&v, "SMALL.TXT", &buf);
    try std.testing.expectEqualStrings("hello fs\n", buf[0..m]);
    try std.testing.expectEqual(@as(usize, 0), try readAll(&v, "empty.txt", &buf));
    const f = try v.readFile(try v.resolve("small.txt", true));
    try std.testing.expectEqual(@as(u64, 9), f.size);
    try std.testing.expect(!f.is_dir);
}

test "non-resident file reads back byte for byte" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    const ref = try v.resolve("/big.bin", true);
    const f = try v.readFile(ref);
    try std.testing.expectEqual(@as(u64, 300000), f.size);
    var buf: [4099]u8 = undefined;
    var off: u64 = 0;
    while (off < f.size) {
        const n = try v.read(ref, off, &buf);
        try std.testing.expect(n > 0);
        for (0..n) |i| try std.testing.expectEqual(bigByte(@intCast(off + i)), buf[i]);
        off += n;
    }
    try std.testing.expectEqual(@as(usize, 0), try v.read(ref, f.size, &buf));
    var mid: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10), try v.read(ref, 123457, &mid));
    for (0..10) |i| try std.testing.expectEqual(bigByte(123457 + i), mid[i]);
}

test "sparse file: holes read as zero, data runs intact" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    const ref = try v.resolve("/sparse.bin", true);
    const f = try v.readFile(ref);
    try std.testing.expectEqual(@as(u64, 24 * 16384 + 5000 + 3), f.size);
    var b: [200]u8 = undefined;
    for (0..24) |k| {
        const n = try v.read(ref, k * 16384, &b);
        try std.testing.expectEqual(@as(usize, 200), n);
        for (0..100) |i| try std.testing.expectEqual(@as(u8, @intCast(65 + k % 26)), b[i]);
        for (100..200) |i| try std.testing.expectEqual(@as(u8, 0), b[i]);
    }
    var e: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try v.read(ref, 24 * 16384 + 5000, &e));
    try std.testing.expectEqualStrings("END", &e);
}

const ListCtx = struct {
    names: [200][64]u8 = undefined,
    lens: [200]u8 = undefined,
    n: usize = 0,
};

fn collect(c: *ListCtx, d: *const fr.DirEntry) bool {
    if (c.n >= c.names.len) return false;
    const nm = d.nameSlice();
    const l = @min(nm.len, 64);
    @memcpy(c.names[c.n][0..l], nm[0..l]);
    c.lens[c.n] = @intCast(l);
    c.n += 1;
    return true;
}

test "root directory B-tree with INDEX_ALLOCATION lists every visible file once" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    var c: ListCtx = .{};
    try v.walkDir(ntfs.ROOT_REF, &c, collect);
    // 4 plain files + 120 long names, plus NTFS system files ($MFT etc.) that
    // mkntfs hides in the root: those are real entries and must be listed too.
    var plain: usize = 0;
    var longs: usize = 0;
    var seen_long = [_]bool{false} ** 121;
    for (0..c.n) |i| {
        const nm = c.names[i][0..c.lens[i]];
        if (std.mem.startsWith(u8, nm, "file_with_a_long_name_number_")) {
            const prefix = "file_with_a_long_name_number_";
            const num = try std.fmt.parseInt(usize, nm[prefix.len .. nm.len - 4], 10);
            try std.testing.expect(!seen_long[num]);
            seen_long[num] = true;
            longs += 1;
        } else if (std.mem.eql(u8, nm, "small.txt") or std.mem.eql(u8, nm, "big.bin") or
            std.mem.eql(u8, nm, "sparse.bin") or std.mem.eql(u8, nm, "empty.txt"))
        {
            plain += 1;
        }
        // 8.3 aliases (e.g. FILE_W~1.TXT) must have been filtered out
        try std.testing.expect(std.mem.indexOfScalar(u8, nm, '~') == null);
    }
    try std.testing.expectEqual(@as(usize, 4), plain);
    try std.testing.expectEqual(@as(usize, 120), longs);
    // index-addressed access agrees with the walk
    var e: fr.DirEntry = undefined;
    try std.testing.expect(try v.readDirAt(ntfs.ROOT_REF, 0, &e));
    try std.testing.expectEqualStrings(c.names[0][0..c.lens[0]], e.nameSlice());
    try std.testing.expect(!(try v.readDirAt(ntfs.ROOT_REF, c.n, &e)));
}

test "lookups across the whole index tree" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    var buf: [16]u8 = undefined;
    for ([_]usize{ 1, 2, 57, 119, 120 }) |i| {
        var name: [64]u8 = undefined;
        const p = try std.fmt.bufPrint(&name, "/file_with_a_long_name_number_{d}.txt", .{i});
        const n = try readAll(&v, p, &buf);
        var want: [8]u8 = undefined;
        const w = try std.fmt.bufPrint(&want, "{d}\n", .{i});
        try std.testing.expectEqualStrings(w, buf[0..n]);
    }
    try std.testing.expectError(error.NotFound, v.resolve("/file_with_a_long_name_number_121.txt", true));
    try std.testing.expectError(error.NotFound, v.resolve("/nope", true));
}

test "errors: not a directory, name too long, directory read" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    try std.testing.expectError(error.NotDir, v.resolve("/small.txt/x", true));
    const long = [_]u8{'a'} ** 300;
    try std.testing.expectError(error.NameTooLong, v.resolve(&long, true));
    var c: ListCtx = .{};
    try std.testing.expectError(error.NotDir, v.walkDir(try v.resolve("small.txt", true), &c, collect));
}

test "stat carries type, size, allocation and timestamps" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    const f = try v.readFile(try v.resolve("big.bin", true));
    const st = ntfs.Volume.stat(&f);
    try std.testing.expectEqual(fr.S_IFREG, st.mode & fr.S_IFMT);
    try std.testing.expectEqual(@as(u64, 300000), st.size);
    try std.testing.expect(st.blocks * 512 >= 300000);
    try std.testing.expect(st.mtime > 1_600_000_000);
    const root = try v.readFile(ntfs.ROOT_REF);
    try std.testing.expectEqual(fr.S_IFDIR, ntfs.Volume.stat(&root).mode & fr.S_IFMT);
}

test "run list decoding: signed deltas, sparse runs, malformed input" {
    var runs: [8]ntfs.Run = undefined;
    // 4 clusters at LCN 0x100, then 2 clusters 0x10 BACK (negative delta), then a 3-cluster hole
    const data = [_]u8{ 0x21, 0x04, 0x00, 0x01, 0x11, 0x02, 0xF0, 0x01, 0x03, 0x00 };
    const n = try ntfs.decodeRuns(&data, 0, &runs);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(?u64, 0x100), runs[0].lcn);
    try std.testing.expectEqual(@as(u64, 4), runs[1].vcn);
    try std.testing.expectEqual(@as(?u64, 0xF0), runs[1].lcn);
    try std.testing.expectEqual(@as(?u64, null), runs[2].lcn);
    try std.testing.expectEqual(@as(u64, 6), runs[2].vcn);
    try std.testing.expectError(error.Corrupt, ntfs.decodeRuns(&.{ 0x31, 0x04 }, 0, &runs)); // truncated
    try std.testing.expectEqual(@as(usize, 0), try ntfs.decodeRuns(&.{ 0x00, 0x05 }, 0, &runs)); // 0 header ends the list
    try std.testing.expectError(error.Corrupt, ntfs.decodeRuns(&.{ 0x10, 0x05, 0 }, 0, &runs)); // zero length field size
    try std.testing.expectError(error.Corrupt, ntfs.decodeRuns(&.{ 0x11, 0x00, 0x05, 0 }, 0, &runs)); // zero length
    try std.testing.expectError(error.Corrupt, ntfs.decodeRuns(&.{ 0x11, 0x01, 0x80, 0 }, 0, &runs)); // negative LCN
    var tiny: [1]ntfs.Run = undefined;
    try std.testing.expectError(error.Unsupported, ntfs.decodeRuns(&data, 0, &tiny));
}

test "hostile boot sectors and fixups are rejected, never crash" {
    var img = try Image.open(path);
    defer img.close();
    const Patch = struct {
        inner: fr.Reader,
        off: u64,
        val: []const u8,
        fn read(ctx: *anyopaque, offset: u64, buf: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.inner.read(offset, buf)) return false;
            var i: usize = 0;
            while (i < buf.len) : (i += 1) {
                const abs = offset + i;
                if (abs >= self.off and abs < self.off + self.val.len) buf[i] = self.val[abs - self.off];
            }
            return true;
        }
    };
    const cases = [_]struct { off: u64, val: []const u8, want: anyerror }{
        .{ .off = 3, .val = "XTFS", .want = error.Invalid }, // OEM id
        .{ .off = 510, .val = &.{ 0, 0 }, .want = error.Invalid }, // boot signature
        .{ .off = 11, .val = &.{ 3, 0 }, .want = error.Corrupt }, // bytes/sector not pow2
        .{ .off = 13, .val = &.{ 0 }, .want = error.Corrupt }, // sectors/cluster 0
        .{ .off = 0x40, .val = &.{ 0 }, .want = error.Corrupt }, // record size 0
        .{ .off = 0x30, .val = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0 }, .want = error.Corrupt }, // $MFT beyond volume
        .{ .off = 0x28, .val = &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, .want = error.Corrupt }, // 0 sectors
    };
    for (cases) |c| {
        var p: Patch = .{ .inner = img.reader(), .off = c.off, .val = c.val };
        const rd: fr.Reader = .{ .ctx = &p, .read_fn = Patch.read };
        try std.testing.expectError(c.want, ntfs.Volume.mount(rd, &scratch));
    }
    // A torn MFT record (fixup value mismatch) must be Corrupt, not trusted.
    // $MFT record 0 lives at LCN 16 (offset 16384); break its first sector's tail.
    var p: Patch = .{ .inner = img.reader(), .off = 16 * 1024 + 510, .val = &.{ 0xAB, 0xCD } };
    const rd: fr.Reader = .{ .ctx = &p, .read_fn = Patch.read };
    try std.testing.expectError(error.Corrupt, ntfs.Volume.mount(rd, &scratch));
}

const NDeny = struct { calls: usize = 0, deny_all: bool = false };
fn ntfsCheck(ctx: *anyopaque, st: fr.Stat) bool {
    _ = st;
    const c: *NDeny = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    return !c.deny_all;
}

test "a search check vetoes NTFS lookups too" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    var ctx: NDeny = .{};
    const chk: ntfs.Volume.SearchCheck = .{ .ctx = &ctx, .allow = ntfsCheck };
    _ = try v.resolveChecked("/small.txt", true, chk);
    try std.testing.expect(ctx.calls >= 1);
    ctx.deny_all = true;
    try std.testing.expectError(error.Access, v.resolveChecked("/small.txt", true, chk));
}

test "statfs counts free clusters and MFT records from the bitmaps" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    // Cross-checked outside the kernel: popcount of `ntfscat '$Bitmap'` gives
    // 2352 of 4095 clusters in use, and the $MFT bitmap has 143 of 188 records used.
    const free = try v.freeClusters();
    try std.testing.expectEqual(@as(u64, 1743), free);
    const s = try v.fsStat(free);
    try std.testing.expectEqual(@as(u32, 0x5346544e), s.magic);
    try std.testing.expectEqual(@as(u32, 1024), s.block_size);
    try std.testing.expectEqual(@as(u64, 4095), s.blocks);
    try std.testing.expectEqual(@as(u64, 1743), s.bfree);
    try std.testing.expectEqual(@as(u64, 1743), s.bavail);
    try std.testing.expectEqual(@as(u64, 188), s.files);
    try std.testing.expectEqual(@as(u64, 45), s.ffree);
}

test "statfs rejects a bitmap that is shorter than the volume" {
    var img = try Image.open(path);
    defer img.close();
    var v = try mountImage(&img);
    v.total_clusters *= 64; // claims far more clusters than $Bitmap describes
    try std.testing.expectError(error.Corrupt, v.freeClusters());
    v.total_clusters = (@as(u64, 1) << 40); // beyond the scan cap
    try std.testing.expectError(error.Unsupported, v.freeClusters());
}

const big_path = "tests/fixtures/fs/ntfs_bigdir.img";

const NameList = struct {
    names: std.ArrayList([]u8),
    fn add(c: *NameList, d: *const fr.DirEntry) bool {
        const copy = std.testing.allocator.dupe(u8, d.nameSlice()) catch return false;
        c.names.append(std.testing.allocator, copy) catch {
            std.testing.allocator.free(copy);
            return false;
        };
        return true;
    }
};

fn freeNames(l: *NameList) void {
    for (l.names.items) |n| std.testing.allocator.free(n);
    l.names.deinit(std.testing.allocator);
}

test "big directory: the cursor yields exactly what the whole-tree walk yields" {
    var img = try Image.open(big_path);
    defer img.close();
    const v = try mountImage(&img);
    var want: NameList = .{ .names = .empty };
    defer freeNames(&want);
    try v.walkDir(ntfs.ROOT_REF, &want, NameList.add);
    // 1900 files plus the system files mkntfs keeps in the root.
    try std.testing.expect(want.names.items.len >= 1900);

    var cur: ntfs.Volume.DirCursor = .{};
    var e: fr.DirEntry = undefined;
    var i: usize = 0;
    while (try v.nextDirEntry(ntfs.ROOT_REF, &cur, &e)) : (i += 1) {
        try std.testing.expect(i < want.names.items.len);
        try std.testing.expectEqualStrings(want.names.items[i], e.nameSlice());
    }
    try std.testing.expectEqual(want.names.items.len, i);
    // once finished it stays finished
    try std.testing.expect(!(try v.nextDirEntry(ntfs.ROOT_REF, &cur, &e)));
}

test "big directory: a cursor copy resumes from any position" {
    var img = try Image.open(big_path);
    defer img.close();
    const v = try mountImage(&img);
    var want: NameList = .{ .names = .empty };
    defer freeNames(&want);
    try v.walkDir(ntfs.ROOT_REF, &want, NameList.add);

    // Walk once, saving a copy of the cursor at every 37th entry, then resume
    // each saved copy (after unrelated reads reused the scratch blocks) and
    // check the next few names.
    var cur: ntfs.Volume.DirCursor = .{};
    var e: fr.DirEntry = undefined;
    var saved: std.ArrayList(struct { at: usize, c: ntfs.Volume.DirCursor }) = .empty;
    defer saved.deinit(std.testing.allocator);
    var i: usize = 0;
    while (true) {
        if (i % 37 == 0) try saved.append(std.testing.allocator, .{ .at = i, .c = cur });
        if (!try v.nextDirEntry(ntfs.ROOT_REF, &cur, &e)) break;
        i += 1;
    }
    try std.testing.expect(saved.items.len > 40);
    for (saved.items) |s| {
        var c = s.c;
        _ = try v.resolve("/bigdir_entry_with_a_long_name_1234.txt", true); // disturbs scratch
        var k: usize = 0;
        while (k < 5 and s.at + k < want.names.items.len) : (k += 1) {
            try std.testing.expect(try v.nextDirEntry(ntfs.ROOT_REF, &c, &e));
            try std.testing.expectEqualStrings(want.names.items[s.at + k], e.nameSlice());
        }
    }
}

test "big directory: listing with a cursor costs reads proportional to the directory, not its square" {
    var img = try Image.open(big_path);
    defer img.close();
    const v = try mountImage(&img);

    img.reads = 0;
    var full: NameList = .{ .names = .empty };
    defer freeNames(&full);
    try v.walkDir(ntfs.ROOT_REF, &full, NameList.add);
    const walk_reads = img.reads;

    img.reads = 0;
    var cur: ntfs.Volume.DirCursor = .{};
    var e: fr.DirEntry = undefined;
    var n: usize = 0;
    while (try v.nextDirEntry(ntfs.ROOT_REF, &cur, &e)) n += 1;
    const cursor_reads = img.reads;
    try std.testing.expectEqual(full.names.items.len, n);
    // Each call re-reads the MFT record and the blocks on its path (measured:
    // ~2 reads per entry on this depth-3 tree), nothing like entries^2 / 2 (~1.8M).
    try std.testing.expect(cursor_reads < n * 8);
    try std.testing.expect(walk_reads < n);
    try std.testing.expect(cur.depth == 0 and cur.done);
}

test "big directory: readDirAt agrees with the walk at the edges" {
    var img = try Image.open(big_path);
    defer img.close();
    const v = try mountImage(&img);
    var want: NameList = .{ .names = .empty };
    defer freeNames(&want);
    try v.walkDir(ntfs.ROOT_REF, &want, NameList.add);
    var e: fr.DirEntry = undefined;
    for ([_]usize{ 0, 1, want.names.items.len / 2, want.names.items.len - 1 }) |k| {
        try std.testing.expect(try v.readDirAt(ntfs.ROOT_REF, k, &e));
        try std.testing.expectEqualStrings(want.names.items[k], e.nameSlice());
    }
    try std.testing.expect(!(try v.readDirAt(ntfs.ROOT_REF, want.names.items.len, &e)));
    try std.testing.expect(!(try v.readDirAt(ntfs.ROOT_REF, want.names.items.len + 1000, &e)));
}

test "a directory cursor never runs away on a hostile tree" {
    var img = try Image.open(big_path);
    defer img.close();
    const v = try mountImage(&img);
    // Point the cursor at a block number far outside the index: it must fail
    // cleanly, not loop or read out of bounds.
    var cur: ntfs.Volume.DirCursor = .{};
    var e: fr.DirEntry = undefined;
    _ = try v.nextDirEntry(ntfs.ROOT_REF, &cur, &e);
    cur.depth = 1;
    cur.vcn[1] = 0x7fff_ffff;
    cur.off[1] = 0;
    try std.testing.expectError(error.Corrupt, v.nextDirEntry(ntfs.ROOT_REF, &cur, &e));
    // And a depth beyond the supported maximum is refused.
    var deep: ntfs.Volume.DirCursor = .{ .started = true, .depth = 200 };
    try std.testing.expectError(error.Corrupt, v.nextDirEntry(ntfs.ROOT_REF, &deep, &e));
}

fn allowAll(_: *anyopaque, _: fr.Stat) bool {
    return true;
}

test "resolveCheckedFrom and pathOf on an NTFS system directory" {
    var img = try Image.open(path);
    defer img.close();
    const v = try mountImage(&img);
    var dummy: u8 = 0;
    const chk: ntfs.Volume.SearchCheck = .{ .ctx = &dummy, .allow = allowAll };
    // Facts from `ntfsinfo`: $Extend is record 11 (parent 5), $ObjId is 25, $Quota is 24.
    const extend = try v.resolve("/$Extend", true);
    try std.testing.expectEqual(@as(u64, 11), extend);
    try std.testing.expectEqual(@as(u64, 25), try v.resolveCheckedFrom(extend, "$ObjId", true, chk));
    try std.testing.expectEqual(@as(u64, 24), try v.resolveCheckedFrom(extend, "$quota", true, chk)); // case-insensitive
    try std.testing.expectEqual(@as(u64, 24), try v.resolveCheckedFrom(extend, "./$Quota", true, chk));
    try std.testing.expectEqual(ntfs.ROOT_REF, try v.resolveCheckedFrom(extend, "..", true, chk));
    try std.testing.expectEqual(ntfs.ROOT_REF, try v.resolveCheckedFrom(extend, "../../..", true, chk));
    // from the root, a name resolves as with resolve()
    try std.testing.expectEqual(try v.resolve("/small.txt", true), try v.resolveCheckedFrom(ntfs.ROOT_REF, "small.txt", true, chk));
    try std.testing.expectError(error.NotFound, v.resolveCheckedFrom(extend, "missing", true, chk));
    try std.testing.expectError(error.NotDir, v.resolveCheckedFrom(try v.resolve("/small.txt", true), "x", true, chk));

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/$Extend", try v.pathOf(extend, &buf));
    try std.testing.expectEqualStrings("", try v.pathOf(ntfs.ROOT_REF, &buf));
    try std.testing.expectError(error.NotDir, v.pathOf(try v.resolve("/small.txt", true), &buf));
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, v.pathOf(extend, &tiny));
    // the path found for $Extend resolves back to it
    try std.testing.expectEqual(extend, try v.resolve(try v.pathOf(extend, &buf), true));
}
