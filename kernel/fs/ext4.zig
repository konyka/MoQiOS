//! Read-only ext4 (and ext2/ext3) volume parser — no I/O of its own, no
//! allocation, no globals. All access goes through an fs_reader.Reader.
//!
//! Supported: extent trees (any depth, uninitialised extents read as zero) and
//! classic direct/indirect block maps, 32/64-bit group descriptors, flex_bg,
//! any block size, htree directories (scanned linearly: interior dx nodes look
//! like empty dirents, so a linear walk sees every leaf entry), fast and slow
//! symlinks, bigalloc (extents address blocks, only the bitmaps differ).
//!
//! Not supported (reported as error.Unsupported): meta_bg, journal devices,
//! mmp, compression, inline_data inodes, encrypted inodes, casefolded dirs.
//! A volume that needs journal recovery mounts read-only WITHOUT replaying the
//! journal, so it may show state older than the last committed transaction.
//! Metadata checksums are not verified (read-only, no repair path).

const std = @import("std");
const fr = @import("fs_reader.zig");

pub const Error = error{ Io, Corrupt, Unsupported, NotFound, NotDir, IsDir, Loop, NameTooLong, Invalid };

pub const ROOT_INO: u32 = 2;

const MAGIC: u16 = 0xEF53;

const INCOMPAT_COMPRESSION: u32 = 0x1;
const INCOMPAT_FILETYPE: u32 = 0x2;
const INCOMPAT_RECOVER: u32 = 0x4;
const INCOMPAT_JOURNAL_DEV: u32 = 0x8;
const INCOMPAT_META_BG: u32 = 0x10;
const INCOMPAT_EXTENTS: u32 = 0x40;
const INCOMPAT_64BIT: u32 = 0x80;
const INCOMPAT_MMP: u32 = 0x100;
const INCOMPAT_FLEX_BG: u32 = 0x200;
const INCOMPAT_EA_INODE: u32 = 0x400;
const INCOMPAT_DIRDATA: u32 = 0x1000;
const INCOMPAT_CSUM_SEED: u32 = 0x2000;
const INCOMPAT_LARGEDIR: u32 = 0x4000;
const INCOMPAT_INLINE_DATA: u32 = 0x8000;
const INCOMPAT_ENCRYPT: u32 = 0x10000;
const INCOMPAT_CASEFOLD: u32 = 0x20000;

const SUPPORTED_INCOMPAT: u32 = INCOMPAT_FILETYPE | INCOMPAT_RECOVER | INCOMPAT_EXTENTS |
    INCOMPAT_64BIT | INCOMPAT_FLEX_BG | INCOMPAT_EA_INODE | INCOMPAT_CSUM_SEED |
    INCOMPAT_LARGEDIR | INCOMPAT_INLINE_DATA | INCOMPAT_ENCRYPT | INCOMPAT_CASEFOLD;

const RO_COMPAT_HUGE_FILE: u32 = 0x8;

const FL_ENCRYPT: u32 = 0x800;
const FL_INDEX: u32 = 0x1000;
const FL_HUGE_FILE: u32 = 0x40000;
const FL_EXTENTS: u32 = 0x80000;
const FL_CASEFOLD: u32 = 0x40000000;
const FL_INLINE_DATA: u32 = 0x10000000;

const EXTENT_MAGIC: u16 = 0xF30A;
const MAX_EXTENT_DEPTH: u16 = 5;
const MAX_SYMLINK_DEPTH: u8 = 8;
const LINK_BUF: usize = 512;

fn r16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn r32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

pub const Inode = struct {
    ino: u32 = 0,
    mode: u16 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    links: u16 = 0,
    /// 512-byte units.
    blocks512: u64 = 0,
    flags: u32 = 0,
    atime: u32 = 0,
    ctime: u32 = 0,
    mtime: u32 = 0,
    file_acl: u64 = 0,
    iblock: [60]u8 = @splat(0),

    pub fn isDir(self: *const Inode) bool {
        return self.mode & fr.S_IFMT == fr.S_IFDIR;
    }
    pub fn isReg(self: *const Inode) bool {
        return self.mode & fr.S_IFMT == fr.S_IFREG;
    }
    pub fn isLnk(self: *const Inode) bool {
        return self.mode & fr.S_IFMT == fr.S_IFLNK;
    }
};

/// Physical placement of one logical block run.
pub const Map = struct {
    kind: enum { hole, data, zero },
    /// First physical block (data only).
    phys: u64 = 0,
    /// Logical blocks covered, starting at the queried block (>= 1).
    len: u64 = 1,
};

pub const Volume = struct {
    rd: fr.Reader,
    block_size: u32,
    inodes_per_group: u32,
    inode_size: u32,
    desc_size: u32,
    gdt_block: u32,
    groups_count: u32,
    inodes_count: u32,
    blocks_count: u64,
    free_blocks: u64,
    free_inodes: u32,
    incompat: u32,
    huge_file: bool,
    needs_recovery: bool,
    label: [16]u8,
    uuid: [16]u8,

    pub fn mount(rd: fr.Reader) Error!Volume {
        var sb: [1024]u8 = undefined;
        if (!rd.read(1024, &sb)) return error.Io;
        if (r16(&sb, 0x38) != MAGIC) return error.Invalid;

        const incompat = r32(&sb, 0x60);
        if (incompat & (INCOMPAT_META_BG | INCOMPAT_JOURNAL_DEV | INCOMPAT_MMP | INCOMPAT_COMPRESSION | INCOMPAT_DIRDATA) != 0) return error.Unsupported;
        if (incompat & ~SUPPORTED_INCOMPAT != 0) return error.Unsupported;

        const log_bs = r32(&sb, 0x18);
        if (log_bs > 6) return error.Corrupt; // 1 KiB .. 64 KiB
        const block_size: u32 = @as(u32, 1024) << @intCast(log_bs);

        const rev = r32(&sb, 0x4C);
        var inode_size: u32 = if (rev >= 1) r16(&sb, 0x58) else 128;
        if (inode_size == 0) inode_size = 128;
        if (inode_size < 128 or inode_size > block_size or !std.math.isPowerOfTwo(inode_size)) return error.Corrupt;

        const is64 = incompat & INCOMPAT_64BIT != 0;
        var desc_size: u32 = 32;
        if (is64) {
            desc_size = r16(&sb, 0xFE);
            if (desc_size < 64 or desc_size > 1024 or !std.math.isPowerOfTwo(desc_size)) return error.Corrupt;
        }

        const blocks_per_group = r32(&sb, 0x20);
        const inodes_per_group = r32(&sb, 0x28);
        if (blocks_per_group == 0 or inodes_per_group == 0) return error.Corrupt;
        if (inodes_per_group > block_size * 8) return error.Corrupt;

        var blocks_count: u64 = r32(&sb, 0x4);
        var free_blocks: u64 = r32(&sb, 0x0C);
        if (is64) {
            blocks_count |= @as(u64, r32(&sb, 0x150)) << 32;
            free_blocks |= @as(u64, r32(&sb, 0x158)) << 32;
        }
        const first_data = r32(&sb, 0x14);
        if (blocks_count == 0 or first_data >= blocks_count) return error.Corrupt;

        const groups: u64 = (blocks_count - first_data + blocks_per_group - 1) / blocks_per_group;
        if (groups == 0 or groups > std.math.maxInt(u32)) return error.Corrupt;
        const inodes_count = r32(&sb, 0x0);
        if (inodes_count == 0 or @as(u64, inodes_count) > groups * inodes_per_group) return error.Corrupt;

        var v: Volume = .{
            .rd = rd,
            .block_size = block_size,
            .inodes_per_group = inodes_per_group,
            .inode_size = inode_size,
            .desc_size = desc_size,
            // The superblock lives in block 1 for 1 KiB blocks, block 0 otherwise;
            // the descriptor table follows it.
            .gdt_block = (if (block_size == 1024) @as(u32, 1) else 0) + 1,
            .groups_count = @intCast(groups),
            .inodes_count = inodes_count,
            .blocks_count = blocks_count,
            .free_blocks = free_blocks,
            .free_inodes = r32(&sb, 0x10),
            .incompat = incompat,
            .huge_file = r32(&sb, 0x64) & RO_COMPAT_HUGE_FILE != 0,
            .needs_recovery = incompat & INCOMPAT_RECOVER != 0,
            .label = undefined,
            .uuid = undefined,
        };
        @memcpy(&v.label, sb[0x78..0x88]);
        @memcpy(&v.uuid, sb[0x68..0x78]);

        // The root inode must be a readable directory, or this is not a usable volume.
        const root = try v.readInode(ROOT_INO);
        if (!root.isDir()) return error.Corrupt;
        return v;
    }

    fn inodeTableBlock(self: *const Volume, group: u32) Error!u64 {
        const off: u64 = @as(u64, self.gdt_block) * self.block_size + @as(u64, group) * self.desc_size;
        var d: [4]u8 = undefined;
        if (!self.rd.read(off + 8, &d)) return error.Io;
        var tbl: u64 = r32(&d, 0);
        if (self.incompat & INCOMPAT_64BIT != 0) {
            if (!self.rd.read(off + 0x28, &d)) return error.Io;
            tbl |= @as(u64, r32(&d, 0)) << 32;
        }
        if (tbl == 0 or tbl >= self.blocks_count) return error.Corrupt;
        return tbl;
    }

    pub fn readInode(self: *const Volume, ino: u32) Error!Inode {
        if (ino == 0 or ino > self.inodes_count) return error.NotFound;
        const group = (ino - 1) / self.inodes_per_group;
        const index = (ino - 1) % self.inodes_per_group;
        if (group >= self.groups_count) return error.Corrupt;
        const tbl = try self.inodeTableBlock(group);
        const off = tbl * self.block_size + @as(u64, index) * self.inode_size;

        var raw: [128]u8 = undefined;
        if (!self.rd.read(off, &raw)) return error.Io;

        var in: Inode = .{ .ino = ino };
        in.mode = r16(&raw, 0);
        in.uid = @as(u32, r16(&raw, 2)) | (@as(u32, r16(&raw, 0x78)) << 16);
        in.gid = @as(u32, r16(&raw, 24)) | (@as(u32, r16(&raw, 0x7A)) << 16);
        in.size = @as(u64, r32(&raw, 4)) | (@as(u64, r32(&raw, 0x6C)) << 32);
        in.atime = r32(&raw, 8);
        in.ctime = r32(&raw, 12);
        in.mtime = r32(&raw, 16);
        in.links = r16(&raw, 26);
        in.flags = r32(&raw, 32);
        in.blocks512 = @as(u64, r32(&raw, 28)) | (@as(u64, r16(&raw, 0x74)) << 32);
        if (self.huge_file and in.flags & FL_HUGE_FILE != 0) in.blocks512 *= self.block_size / 512;
        in.file_acl = @as(u64, r32(&raw, 0x68));
        @memcpy(&in.iblock, raw[40..100]);
        // A free inode has mode 0 and no links; reaching one means a stale link.
        if (in.mode == 0) return error.Corrupt;
        return in;
    }

    pub fn stat(self: *const Volume, in: *const Inode) fr.Stat {
        _ = self;
        return .{
            .ino = in.ino,
            .mode = in.mode,
            .uid = in.uid,
            .gid = in.gid,
            .nlink = in.links,
            .size = in.size,
            .blocks = in.blocks512,
            .atime = in.atime,
            .mtime = in.mtime,
            .ctime = in.ctime,
        };
    }

    // ─── Logical → physical block mapping ───────────────────────────────

    fn checkData(self: *const Volume, phys: u64, len: u64) Error!void {
        if (phys >= self.blocks_count or len > self.blocks_count - phys) return error.Corrupt;
    }

    pub fn mapBlock(self: *const Volume, in: *const Inode, lblk: u64) Error!Map {
        if (in.flags & (FL_INLINE_DATA | FL_ENCRYPT) != 0) return error.Unsupported;
        if (in.flags & FL_EXTENTS != 0) return self.mapExtent(in, lblk);
        return self.mapIndirect(in, lblk);
    }

    const NodeLoc = union(enum) { mem: *const [60]u8, disk: u64 };

    fn nodeBytes(self: *const Volume, loc: NodeLoc, off: usize, out: []u8) Error!void {
        switch (loc) {
            .mem => |m| @memcpy(out, m[off..][0..out.len]),
            .disk => |base| if (!self.rd.read(base + off, out)) return error.Io,
        }
    }

    fn mapExtent(self: *const Volume, in: *const Inode, lblk: u64) Error!Map {
        var loc: NodeLoc = .{ .mem = &in.iblock };
        var hdr: [12]u8 = undefined;
        try self.nodeBytes(loc, 0, &hdr);
        if (r16(&hdr, 0) != EXTENT_MAGIC) return error.Corrupt;
        var depth = r16(&hdr, 6);
        if (depth > MAX_EXTENT_DEPTH) return error.Corrupt;
        var entries: u32 = r16(&hdr, 2);
        // Upper bound on where a hole in the current subtree can end.
        var bound: u64 = std.math.maxInt(u64);

        while (true) {
            const max_entries: u32 = r16(&hdr, 4);
            if (entries > max_entries) return error.Corrupt;
            if (loc == .mem and entries > 4) return error.Corrupt;
            if (entries == 0) return .{ .kind = .hole, .len = @min(bound - lblk, std.math.maxInt(u32)) };

            // Largest entry whose first logical block is <= lblk (binary search).
            var lo: u32 = 0;
            var hi: u32 = entries; // [lo, hi)
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                var first: [4]u8 = undefined;
                try self.nodeBytes(loc, 12 + @as(usize, mid) * 12, &first);
                if (r32(&first, 0) <= lblk) lo = mid + 1 else hi = mid;
            }
            // lo = count of entries with start <= lblk.
            if (lo == 0) {
                var first: [4]u8 = undefined;
                try self.nodeBytes(loc, 12, &first);
                const next_start: u64 = r32(&first, 0);
                return .{ .kind = .hole, .len = @min(@min(next_start, bound) - lblk, std.math.maxInt(u32)) };
            }
            const idx = lo - 1;
            var e: [12]u8 = undefined;
            try self.nodeBytes(loc, 12 + @as(usize, idx) * 12, &e);
            var next_first: ?u64 = null;
            if (idx + 1 < entries) {
                var nf: [4]u8 = undefined;
                try self.nodeBytes(loc, 12 + @as(usize, idx + 1) * 12, &nf);
                next_first = r32(&nf, 0);
            }

            if (depth > 0) {
                const child: u64 = @as(u64, r32(&e, 4)) | (@as(u64, r16(&e, 8)) << 32);
                try self.checkData(child, 1);
                if (next_first) |nx| bound = @min(bound, nx);
                loc = .{ .disk = child * self.block_size };
                try self.nodeBytes(loc, 0, &hdr);
                if (r16(&hdr, 0) != EXTENT_MAGIC) return error.Corrupt;
                const child_depth = r16(&hdr, 6);
                if (depth == 0 or child_depth != depth - 1) return error.Corrupt;
                depth = child_depth;
                entries = r16(&hdr, 2);
                continue;
            }

            const start: u64 = r32(&e, 0);
            const raw_len: u32 = r16(&e, 4);
            const uninit = raw_len > 32768;
            const elen: u64 = if (uninit) raw_len - 32768 else raw_len;
            if (elen == 0) return error.Corrupt;
            if (lblk < start + elen) {
                const phys0: u64 = @as(u64, r32(&e, 8)) | (@as(u64, r16(&e, 6)) << 32);
                const into = lblk - start;
                const run = start + elen - lblk;
                try self.checkData(phys0 + into, run);
                return .{ .kind = if (uninit) .zero else .data, .phys = phys0 + into, .len = run };
            }
            const hole_end = @min(next_first orelse std.math.maxInt(u64), bound);
            return .{ .kind = .hole, .len = @min(hole_end - lblk, std.math.maxInt(u32)) };
        }
    }

    fn readPtr(self: *const Volume, block: u64, idx: u64) Error!u32 {
        try self.checkData(block, 1);
        var b: [4]u8 = undefined;
        if (!self.rd.read(block * self.block_size + idx * 4, &b)) return error.Io;
        return r32(&b, 0);
    }

    fn mapIndirect(self: *const Volume, in: *const Inode, lblk_in: u64) Error!Map {
        const ppb: u64 = self.block_size / 4;
        var l = lblk_in;
        var p: u32 = 0;
        if (l < 12) {
            p = r32(&in.iblock, @intCast(l * 4));
        } else {
            l -= 12;
            if (l < ppb) {
                const ind = r32(&in.iblock, 48);
                if (ind != 0) p = try self.readPtr(ind, l);
            } else {
                l -= ppb;
                if (l < ppb * ppb) {
                    const dind = r32(&in.iblock, 52);
                    if (dind != 0) {
                        const ind = try self.readPtr(dind, l / ppb);
                        if (ind != 0) p = try self.readPtr(ind, l % ppb);
                    }
                } else {
                    l -= ppb * ppb;
                    if (l >= ppb * ppb * ppb) return .{ .kind = .hole };
                    const tind = r32(&in.iblock, 56);
                    if (tind != 0) {
                        const dind = try self.readPtr(tind, l / (ppb * ppb));
                        if (dind != 0) {
                            const ind = try self.readPtr(dind, (l / ppb) % ppb);
                            if (ind != 0) p = try self.readPtr(ind, l % ppb);
                        }
                    }
                }
            }
        }
        if (p == 0) return .{ .kind = .hole };
        try self.checkData(p, 1);
        return .{ .kind = .data, .phys = p, .len = 1 };
    }

    // ─── File data ──────────────────────────────────────────────────────

    /// Read up to buf.len bytes at `offset`. Returns the count (0 at/after EOF).
    pub fn readFile(self: *const Volume, in: *const Inode, offset: u64, buf: []u8) Error!usize {
        if (in.isDir()) return error.IsDir;
        if (offset >= in.size or buf.len == 0) return 0;
        const want: usize = @intCast(@min(@as(u64, buf.len), in.size - offset));
        const bs: u64 = self.block_size;
        var done: usize = 0;
        while (done < want) {
            const pos = offset + done;
            const m = try self.mapBlock(in, pos / bs);
            const boff = pos % bs;
            const avail = std.math.mul(u64, m.len, bs) catch std.math.maxInt(u64);
            const n: usize = @intCast(@min(avail - boff, @as(u64, want - done)));
            switch (m.kind) {
                .data => if (!self.rd.read(m.phys * bs + boff, buf[done..][0..n])) return error.Io,
                .hole, .zero => @memset(buf[done..][0..n], 0),
            }
            done += n;
        }
        return done;
    }

    // ─── Directories ────────────────────────────────────────────────────

    /// Next live entry at or after byte position `pos` of the directory.
    /// Returns the entry and the position to resume from, or null at the end.
    pub fn readDir(self: *const Volume, dir: *const Inode, pos_in: u64, out: *fr.DirEntry) Error!?u64 {
        if (!dir.isDir()) return error.NotDir;
        if (dir.flags & (FL_ENCRYPT | FL_CASEFOLD) != 0) return error.Unsupported;
        const bs: u64 = self.block_size;
        var pos = pos_in;
        var steps: u32 = 0;
        while (pos < dir.size) {
            steps += 1;
            if (steps > 1 << 20) return error.Corrupt;
            const lblk = pos / bs;
            const boff = pos % bs;
            const m = try self.mapBlock(dir, lblk);
            if (m.kind != .data) {
                pos = (lblk + 1) * bs; // hole in a directory: nothing to read
                continue;
            }
            if (boff + 8 > bs) return error.Corrupt;
            var h: [8]u8 = undefined;
            if (!self.rd.read(m.phys * bs + boff, &h)) return error.Io;
            var rec_len: u32 = r16(&h, 4);
            if (bs == 65536 and (rec_len == 0 or rec_len == 65535)) rec_len = 65536;
            const name_len: u32 = h[6];
            if (rec_len < 8 or rec_len % 4 != 0 or boff + rec_len > bs) return error.Corrupt;
            if (8 + name_len > rec_len) return error.Corrupt;
            const next = pos + rec_len;
            const ino = r32(&h, 0);
            if (ino == 0) {
                pos = next;
                continue;
            }
            out.ino = ino;
            out.kind = switch (h[7]) {
                1 => .regular,
                2 => .directory,
                7 => .symlink,
                0 => .unknown,
                else => .other,
            };
            out.name_len = @intCast(name_len);
            if (name_len > 0 and !self.rd.read(m.phys * bs + boff + 8, out.name[0..name_len])) return error.Io;
            return next;
        }
        return null;
    }

    pub fn lookup(self: *const Volume, dir: *const Inode, name: []const u8) Error!u32 {
        if (name.len > fr.MAX_NAME) return error.NameTooLong;
        var e: fr.DirEntry = undefined;
        var pos: u64 = 0;
        while (try self.readDir(dir, pos, &e)) |next| {
            if (std.mem.eql(u8, e.nameSlice(), name)) return @intCast(e.ino);
            pos = next;
        }
        return error.NotFound;
    }

    // ─── Symlinks and paths ─────────────────────────────────────────────

    /// Copy the symlink target into `buf`; returns its length.
    pub fn readLink(self: *const Volume, in: *const Inode, buf: []u8) Error!usize {
        if (!in.isLnk()) return error.Invalid;
        if (in.flags & (FL_ENCRYPT | FL_INLINE_DATA) != 0) return error.Unsupported;
        const ea_blocks: u64 = if (in.file_acl != 0) self.block_size / 512 else 0;
        const fast = in.flags & FL_EXTENTS == 0 and in.blocks512 == ea_blocks and in.size < 60;
        if (fast) {
            const n: usize = @intCast(in.size);
            if (n > buf.len) return error.NameTooLong;
            @memcpy(buf[0..n], in.iblock[0..n]);
            return n;
        }
        if (in.size > buf.len) return error.NameTooLong;
        const n: usize = @intCast(in.size);
        const got = try self.readFile(in, 0, buf[0..n]);
        if (got != n) return error.Corrupt;
        return n;
    }

    fn walk(self: *const Volume, start: u32, path: []const u8, depth: u8, follow_last: bool) Error!u32 {
        if (depth > MAX_SYMLINK_DEPTH) return error.Loop;
        var cur = start;
        var rest = path;
        while (true) {
            while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
            if (rest.len == 0) return cur;
            var end: usize = 0;
            while (end < rest.len and rest[end] != '/') end += 1;
            const comp = rest[0..end];
            rest = rest[end..];
            while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
            const last = rest.len == 0;
            if (std.mem.eql(u8, comp, ".")) continue;

            const dir = try self.readInode(cur);
            if (!dir.isDir()) return error.NotDir;
            const ino = try self.lookup(&dir, comp);
            const child = try self.readInode(ino);
            if (child.isLnk() and (!last or follow_last)) {
                var link: [LINK_BUF]u8 = undefined;
                const n = try self.readLink(&child, &link);
                // Absolute targets are resolved against this volume's root.
                const base: u32 = if (n > 0 and link[0] == '/') ROOT_INO else cur;
                cur = try self.walk(base, link[0..n], depth + 1, true);
                continue;
            }
            cur = ino;
        }
    }

    /// Resolve a path (relative to the volume root) to an inode number.
    pub fn resolve(self: *const Volume, path: []const u8, follow_last: bool) Error!u32 {
        return self.walk(ROOT_INO, path, 0, follow_last);
    }
};
