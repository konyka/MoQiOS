//! Host tests for kernel/fs/ext4.zig against real mke2fs images
//! (tools/fsfixtures/mkfixtures.sh): ext4 with 1 KiB and 4 KiB blocks (extents,
//! 64bit, flex_bg, metadata_csum, htree) and ext3 (indirect block maps).

const std = @import("std");
const kt = @import("kernel_shared");
const ext4 = kt.ext4;
const fr = kt.fs_reader;
const Image = @import("fs_image.zig").Image;

const images = [_][]const u8{
    "tests/fixtures/fs/ext4_1k.img",
    "tests/fixtures/fs/ext4_4k.img",
    "tests/fixtures/fs/ext3_1k.img",
};

fn bigByte(i: usize) u8 {
    return @truncate(i * 7 + i / 251);
}

fn readAll(v: *const ext4.Volume, path: []const u8, out: []u8) !usize {
    const ino = try v.resolve(path, true);
    const in = try v.readInode(ino);
    return v.readFile(&in, 0, out);
}

test "mount identifies the volume" {
    var img = try Image.open(images[0]);
    defer img.close();
    const v = try ext4.Volume.mount(img.reader());
    try std.testing.expectEqual(@as(u32, 1024), v.block_size);
    try std.testing.expect(std.mem.startsWith(u8, &v.label, "MOQIEXT4"));
    try std.testing.expect(v.incompat & 0x40 != 0); // extents
    var img4 = try Image.open(images[1]);
    defer img4.close();
    const v4 = try ext4.Volume.mount(img4.reader());
    try std.testing.expectEqual(@as(u32, 4096), v4.block_size);
}

test "small file, empty file and nested path" {
    for (images) |path| {
        var img = try Image.open(path);
        defer img.close();
        const v = try ext4.Volume.mount(img.reader());
        var buf: [64]u8 = undefined;
        const n = try readAll(&v, "/small.txt", &buf);
        try std.testing.expectEqualStrings("hello fs\n", buf[0..n]);
        try std.testing.expectEqual(@as(usize, 0), try readAll(&v, "empty.txt", &buf));
        const m = try readAll(&v, "/dir/sub/n.txt", &buf);
        try std.testing.expectEqualStrings("nested\n", buf[0..m]);
        const k = try readAll(&v, "dir//sub/../sub/./n.txt", &buf);
        try std.testing.expectEqualStrings("nested\n", buf[0..k]);
    }
}

test "large file reads back byte for byte across block and extent boundaries" {
    for (images) |path| {
        var img = try Image.open(path);
        defer img.close();
        const v = try ext4.Volume.mount(img.reader());
        const ino = try v.resolve("/big.bin", true);
        const in = try v.readInode(ino);
        try std.testing.expectEqual(@as(u64, 300000), in.size);
        var buf: [4099]u8 = undefined; // odd size so reads straddle blocks
        var off: u64 = 0;
        while (off < in.size) {
            const n = try v.readFile(&in, off, &buf);
            try std.testing.expect(n > 0);
            for (0..n) |i| try std.testing.expectEqual(bigByte(@intCast(off + i)), buf[i]);
            off += n;
        }
        try std.testing.expectEqual(@as(usize, 0), try v.readFile(&in, in.size, &buf));
        // unaligned read in the middle
        var mid: [10]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 10), try v.readFile(&in, 123457, &mid));
        for (0..10) |i| try std.testing.expectEqual(bigByte(123457 + i), mid[i]);
    }
}

test "sparse file: holes read as zero, data blocks intact" {
    for (images) |path| {
        var img = try Image.open(path);
        defer img.close();
        const v = try ext4.Volume.mount(img.reader());
        const ino = try v.resolve("/sparse.bin", true);
        const in = try v.readInode(ino);
        try std.testing.expectEqual(@as(u64, 24 * 16384 + 5000 + 3), in.size);
        var b: [200]u8 = undefined;
        for (0..24) |k| {
            const n = try v.readFile(&in, k * 16384, &b);
            try std.testing.expectEqual(@as(usize, 200), n);
            for (0..100) |i| try std.testing.expectEqual(@as(u8, @intCast(65 + k % 26)), b[i]);
            for (100..200) |i| try std.testing.expectEqual(@as(u8, 0), b[i]);
        }
        var e: [3]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 3), try v.readFile(&in, 24 * 16384 + 5000, &e));
        try std.testing.expectEqualStrings("END", &e);
        var z: [5000]u8 = undefined;
        _ = try v.readFile(&in, 24 * 16384, &z);
        for (z[100..]) |c| try std.testing.expectEqual(@as(u8, 0), c);
    }
}

test "directory with 300 entries lists every name exactly once" {
    for (images) |path| {
        var img = try Image.open(path);
        defer img.close();
        const v = try ext4.Volume.mount(img.reader());
        const dino = try v.resolve("/dir", true);
        const dir = try v.readInode(dino);
        try std.testing.expect(dir.isDir());
        var seen = [_]bool{false} ** 301;
        var count: usize = 0;
        var e: fr.DirEntry = undefined;
        var pos: u64 = 0;
        var saw_sub = false;
        while (try v.readDir(&dir, pos, &e)) |next| : (pos = next) {
            const name = e.nameSlice();
            if (std.mem.eql(u8, name, "sub")) {
                saw_sub = true;
                try std.testing.expectEqual(fr.FileKind.directory, e.kind);
                continue;
            }
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try std.testing.expect(std.mem.startsWith(u8, name, "file_"));
            const num = try std.fmt.parseInt(usize, name[5 .. name.len - 4], 10);
            try std.testing.expect(!seen[num]);
            seen[num] = true;
            count += 1;
        }
        try std.testing.expect(saw_sub);
        try std.testing.expectEqual(@as(usize, 300), count);
        var buf: [16]u8 = undefined;
        const n = try readAll(&v, "/dir/file_217.txt", &buf);
        try std.testing.expectEqualStrings("217\n", buf[0..n]);
    }
}

test "htree directory still resolves any name" {
    var img = try Image.open(images[0]);
    defer img.close();
    const v = try ext4.Volume.mount(img.reader());
    const dir = try v.readInode(try v.resolve("/dir", true));
    try std.testing.expect(dir.flags & 0x1000 != 0); // EXT4_INDEX_FL: really an htree
    var buf: [16]u8 = undefined;
    for ([_]usize{ 1, 2, 150, 299, 300 }) |i| {
        var name: [32]u8 = undefined;
        const p = try std.fmt.bufPrint(&name, "/dir/file_{d}.txt", .{i});
        const n = try readAll(&v, p, &buf);
        var want: [8]u8 = undefined;
        const w = try std.fmt.bufPrint(&want, "{d}\n", .{i});
        try std.testing.expectEqualStrings(w, buf[0..n]);
    }
    try std.testing.expectError(error.NotFound, v.resolve("/dir/file_301.txt", true));
}

test "symlinks: followed by default, not on lstat-style resolve" {
    for (images) |path| {
        var img = try Image.open(path);
        defer img.close();
        const v = try ext4.Volume.mount(img.reader());
        const lnk = try v.readInode(try v.resolve("/link", false));
        try std.testing.expect(lnk.isLnk());
        var t: [64]u8 = undefined;
        const n = try v.readLink(&lnk, &t);
        try std.testing.expectEqualStrings("small.txt", t[0..n]);
        var buf: [32]u8 = undefined;
        const m = try readAll(&v, "/link", &buf);
        try std.testing.expectEqualStrings("hello fs\n", buf[0..m]);
        const target = try v.readInode(try v.resolve("/link", true));
        try std.testing.expect(target.isReg());
    }
}

test "errors: missing, not-a-directory, and reading a directory as a file" {
    var img = try Image.open(images[0]);
    defer img.close();
    const v = try ext4.Volume.mount(img.reader());
    try std.testing.expectError(error.NotFound, v.resolve("/nope", true));
    try std.testing.expectError(error.NotDir, v.resolve("/small.txt/x", true));
    const dir = try v.readInode(try v.resolve("/dir", true));
    var b: [8]u8 = undefined;
    try std.testing.expectError(error.IsDir, v.readFile(&dir, 0, &b));
    const long = [_]u8{'a'} ** 300;
    try std.testing.expectError(error.NameTooLong, v.resolve(&long, true));
}

test "stat reports mode, size, ownership and link count" {
    var img = try Image.open(images[0]);
    defer img.close();
    const v = try ext4.Volume.mount(img.reader());
    const in = try v.readInode(try v.resolve("/small.txt", true));
    const st = v.stat(&in);
    try std.testing.expectEqual(@as(u64, 9), st.size);
    try std.testing.expectEqual(fr.S_IFREG, st.mode & fr.S_IFMT);
    try std.testing.expectEqual(@as(u32, 1), st.nlink);
    try std.testing.expect(st.mtime > 1_600_000_000);
    const d = try v.readInode(try v.resolve("/dir", true));
    try std.testing.expectEqual(fr.S_IFDIR, v.stat(&d).mode & fr.S_IFMT);
}

test "hostile images are rejected, never crash" {
    var img = try Image.open(images[0]);
    defer img.close();
    // Corrupt the superblock in memory and mount through a patching reader.
    const Patch = struct {
        inner: fr.Reader,
        off: u64,
        val: []const u8,
        fn read(ctx: *anyopaque, offset: u64, buf: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.inner.read(offset, buf)) return false;
            // overlay
            var i: usize = 0;
            while (i < buf.len) : (i += 1) {
                const abs = offset + i;
                if (abs >= self.off and abs < self.off + self.val.len) buf[i] = self.val[abs - self.off];
            }
            return true;
        }
    };
    const cases = [_]struct { off: u64, val: []const u8, want: anyerror }{
        .{ .off = 1024 + 0x38, .val = &.{ 0, 0 }, .want = error.Invalid }, // bad magic
        .{ .off = 1024 + 0x18, .val = &.{ 99, 0, 0, 0 }, .want = error.Corrupt }, // block size
        .{ .off = 1024 + 0x20, .val = &.{ 0, 0, 0, 0 }, .want = error.Corrupt }, // blocks/group 0
        .{ .off = 1024 + 0x60, .val = &.{ 0x16, 0, 0, 0 }, .want = error.Unsupported }, // meta_bg
        .{ .off = 1024 + 0xFE, .val = &.{ 3, 0 }, .want = error.Corrupt }, // desc_size not pow2
    };
    for (cases) |c| {
        var p: Patch = .{ .inner = img.reader(), .off = c.off, .val = c.val };
        const rd: fr.Reader = .{ .ctx = &p, .read_fn = Patch.read };
        try std.testing.expectError(c.want, ext4.Volume.mount(rd));
    }
}

test "a corrupt extent tree is reported, not followed" {
    var img = try Image.open(images[0]);
    defer img.close();
    const v = try ext4.Volume.mount(img.reader());
    var in = try v.readInode(try v.resolve("/big.bin", true));
    in.iblock[0] = 0; // break the extent header magic
    try std.testing.expectError(error.Corrupt, v.mapBlock(&in, 0));
    var in2 = try v.readInode(try v.resolve("/big.bin", true));
    in2.iblock[6] = 99; // depth beyond the limit
    try std.testing.expectError(error.Corrupt, v.mapBlock(&in2, 0));
}

const DenyCtx = struct { denied_ino: u64, calls: usize = 0 };
fn denyOne(ctx: *anyopaque, st: fr.Stat) bool {
    const c: *DenyCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    return st.ino != c.denied_ino;
}

test "a search check can veto any directory on the path" {
    var img = try Image.open(images[0]);
    defer img.close();
    const v = try ext4.Volume.mount(img.reader());
    const dir_ino = try v.resolve("/dir", true);
    var ctx: DenyCtx = .{ .denied_ino = dir_ino };
    const chk: ext4.Volume.SearchCheck = .{ .ctx = &ctx, .allow = denyOne };
    // the root is searchable, /dir is not: reaching anything inside it is refused
    try std.testing.expectError(error.Access, v.resolveChecked("/dir/sub/n.txt", true, chk));
    try std.testing.expectError(error.Access, v.resolveChecked("/dir/file_1.txt", true, chk));
    // the directory itself can still be named (only searching INSIDE it is vetoed)
    try std.testing.expectEqual(dir_ino, try v.resolveChecked("/dir", true, chk));
    // paths that never enter it are unaffected
    _ = try v.resolveChecked("/small.txt", true, chk);
    // the check really ran for each traversed directory
    try std.testing.expect(ctx.calls >= 3);
}

const access = kt.rofs_access_policy;

fn metaOf(st: fr.Stat) access.Meta {
    return .{ .mode = st.mode, .uid = st.uid, .gid = st.gid };
}

fn canOpen(v: *const ext4.Volume, p: []const u8, who: access.Creds) !bool {
    const Sc = struct {
        creds: access.Creds,
        fn allow(ctx: *anyopaque, st: fr.Stat) bool {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            return access.canSearch(metaOf(st), s.creds);
        }
    };
    var sc: Sc = .{ .creds = who };
    const ino = v.resolveChecked(p, true, .{ .ctx = &sc, .allow = Sc.allow }) catch |e| switch (e) {
        error.Access => return false,
        else => return e,
    };
    const in = try v.readInode(ino);
    return access.allows(metaOf(v.stat(&in)), who, access.R);
}

test "permission matrix on the real fixture (owner 1000, others 4242)" {
    var img = try Image.open(images[0]);
    defer img.close();
    const v = try ext4.Volume.mount(img.reader());
    const me: access.Creds = .{ .euid = 1000, .egid = 1000 };
    const root_c: access.Creds = .{ .euid = 0, .egid = 0 };
    try std.testing.expect(try canOpen(&v, "/perm/world.txt", me));
    try std.testing.expect(!try canOpen(&v, "/perm/private.txt", me));
    try std.testing.expect(!try canOpen(&v, "/perm/group.txt", me));
    try std.testing.expect(try canOpen(&v, "/perm/mine_open.txt", me));
    try std.testing.expect(!try canOpen(&v, "/perm/mine_closed.txt", me)); // owner class 000
    try std.testing.expect(!try canOpen(&v, "/perm/locked/inside.txt", me));
    try std.testing.expect(!try canOpen(&v, "/perm/listonly/inside.txt", me));
    // root reads everything (these files have no execute bit; read needs none)
    try std.testing.expect(try canOpen(&v, "/perm/private.txt", root_c));
    try std.testing.expect(try canOpen(&v, "/perm/locked/inside.txt", root_c));
}
