//! Read-only NTFS volume parser — no I/O of its own, no allocation, no globals.
//! All access goes through an fs_reader.Reader.
//!
//! Supported: any sector/cluster/record size NTFS allows, a fragmented $MFT,
//! update-sequence fixups on every record and index block, resident and
//! non-resident $DATA (including sparse runs and a short initialised size),
//! $INDEX_ROOT + $INDEX_ALLOCATION B-tree directories (walked in full), DOS 8.3
//! aliases hidden, UTF-16 names converted to UTF-8, symlink/junction reparse
//! points reported as symlinks.
//!
//! Name matching is ASCII case-insensitive (NTFS itself folds through the
//! volume's $UpCase table). A non-ASCII name therefore only matches an
//! identical spelling; it can miss a differently-cased one but never matches
//! the wrong file.
//!
//! Not supported (error.Unsupported): compressed or encrypted $DATA, files
//! whose attributes spill into extension records via $ATTRIBUTE_LIST, and
//! MFT records larger than the cluster that straddle runs. The journal
//! ($LogFile) is ignored: a volume that was not cleanly dismounted is read
//! as-is and may show pre-crash state.

const std = @import("std");
const fr = @import("fs_reader.zig");

pub const Error = error{ Io, Corrupt, Unsupported, NotFound, NotDir, IsDir, Loop, NameTooLong, Invalid, Access };

pub const ROOT_REF: u64 = 5;

const REF_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;

const ATTR_STANDARD_INFORMATION: u32 = 0x10;
const ATTR_ATTRIBUTE_LIST: u32 = 0x20;
const ATTR_FILE_NAME: u32 = 0x30;
const ATTR_DATA: u32 = 0x80;
const ATTR_INDEX_ROOT: u32 = 0x90;
const ATTR_BITMAP: u32 = 0xB0;
const ATTR_INDEX_ALLOCATION: u32 = 0xA0;
const ATTR_REPARSE_POINT: u32 = 0xC0;
const ATTR_END: u32 = 0xFFFFFFFF;

const FLAG_COMPRESSED: u16 = 0x0001;
const FLAG_ENCRYPTED: u16 = 0x4000;
const FLAG_SPARSE: u16 = 0x8000;

const REC_IN_USE: u16 = 0x0001;
const REC_IS_DIR: u16 = 0x0002;

const FILE_ATTR_REPARSE: u32 = 0x400;
const FILE_ATTR_DIRECTORY_IDX: u32 = 0x10000000;
const REPARSE_SYMLINK: u32 = 0xA000000C;
const REPARSE_MOUNT_POINT: u32 = 0xA0000003;

const NS_DOS: u8 = 2;

const MAX_RECORD: u32 = 4096;
/// Largest index block supported. Windows and mkntfs both use 4096 whatever
/// the cluster size; larger values would not fit the kernel scratch budget.
pub const MAX_INDEX_BLOCK: u32 = 8192;
pub const MAX_TREE_DEPTH: u32 = 8;
const MAX_VISITS: u32 = 1 << 22;
/// Largest allocation bitmap statfs will scan (64 MiB = 512 Mi clusters).
const MAX_BITMAP_SCAN: u64 = 64 * 1024 * 1024;
const BITMAP_RECORD: u64 = 6;
const NTFS_SUPER_MAGIC: u32 = 0x5346544e;
const MAX_SYMLINK_DEPTH: u8 = 8;
const EPOCH_DIFF_100NS: u64 = 116444736000000000; // 1601 → 1970

fn r16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn r32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn r64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

fn ntTime(t: u64) u64 {
    return if (t < EPOCH_DIFF_100NS) 0 else (t - EPOCH_DIFF_100NS) / 10_000_000;
}

/// One decoded run: `len` clusters at `lcn`, or a sparse hole when lcn == null.
pub const Run = struct {
    vcn: u64,
    len: u64,
    lcn: ?u64,
};

/// Streaming decoder for a mapping-pairs array: no run table is built, so a
/// file with any number of fragments costs no memory.
pub const RunIter = struct {
    data: []const u8,
    pos: usize = 0,
    vcn: u64,
    lcn: i64 = 0,

    pub fn init(data: []const u8, start_vcn: u64) RunIter {
        return .{ .data = data, .vcn = start_vcn };
    }

    pub fn next(self: *RunIter) Error!?Run {
        const data = self.data;
        if (self.pos >= data.len or data[self.pos] == 0) return null;
        const hdr = data[self.pos];
        const len_sz: usize = hdr & 0x0F;
        const off_sz: usize = hdr >> 4;
        self.pos += 1;
        if (len_sz == 0 or len_sz > 8 or off_sz > 8) return error.Corrupt;
        if (self.pos + len_sz + off_sz > data.len) return error.Corrupt;
        var len: u64 = 0;
        for (0..len_sz) |i| len |= @as(u64, data[self.pos + i]) << @intCast(8 * i);
        self.pos += len_sz;
        if (len == 0) return error.Corrupt;
        var run_lcn: ?u64 = null;
        if (off_sz != 0) {
            var raw: u64 = 0;
            for (0..off_sz) |i| raw |= @as(u64, data[self.pos + i]) << @intCast(8 * i);
            var delta: i64 = @bitCast(raw);
            if (off_sz < 8 and data[self.pos + off_sz - 1] & 0x80 != 0) {
                delta = @bitCast(raw | (~@as(u64, 0) << @intCast(8 * off_sz)));
            }
            self.pos += off_sz;
            self.lcn = std.math.add(i64, self.lcn, delta) catch return error.Corrupt;
            if (self.lcn < 0) return error.Corrupt;
            run_lcn = @intCast(self.lcn);
        }
        const run: Run = .{ .vcn = self.vcn, .len = len, .lcn = run_lcn };
        self.vcn = std.math.add(u64, self.vcn, len) catch return error.Corrupt;
        return run;
    }
};

/// The run covering `vcn`, or null when it falls in a gap past the last run.
pub fn findRun(pairs: []const u8, start_vcn: u64, vcn: u64) Error!?Run {
    var it = RunIter.init(pairs, start_vcn);
    while (try it.next()) |r| {
        if (vcn >= r.vcn and vcn - r.vcn < r.len) return r;
        if (r.vcn > vcn) return null;
    }
    return null;
}

/// Collect runs into `out` (tests and diagnostics). error.Unsupported if full.
pub fn decodeRuns(data: []const u8, start_vcn: u64, out: []Run) Error!usize {
    var it = RunIter.init(data, start_vcn);
    var n: usize = 0;
    while (try it.next()) |r| {
        if (n >= out.len) return error.Unsupported;
        out[n] = r;
        n += 1;
    }
    return n;
}

/// Caller-provided index-block buffers (one per tree level), kept off the
/// small kernel stack.
pub const Scratch = struct {
    blocks: [MAX_TREE_DEPTH][MAX_INDEX_BLOCK]u8 align(16),
};

/// An attribute header located inside a record buffer.
const Attr = struct {
    type: u32,
    non_resident: bool,
    flags: u16,
    name_len: u8,
    off: usize,
    len: usize,
    value_off: usize = 0,
    value_len: usize = 0,
    start_vcn: u64 = 0,
    runs_off: usize = 0,
    alloc_size: u64 = 0,
    data_size: u64 = 0,
    init_size: u64 = 0,
};

fn parseAttr(rec: []const u8, off: usize) Error!?Attr {
    if (off + 4 > rec.len) return error.Corrupt;
    const t = r32(rec, off);
    if (t == ATTR_END) return null;
    if (off + 16 > rec.len) return error.Corrupt;
    const len = r32(rec, off + 4);
    if (len < 16 or len % 8 != 0 or off + len > rec.len) return error.Corrupt;
    var a: Attr = .{
        .type = t,
        .non_resident = rec[off + 8] != 0,
        .flags = r16(rec, off + 12),
        .name_len = rec[off + 9],
        .off = off,
        .len = len,
    };
    if (!a.non_resident) {
        if (len < 24) return error.Corrupt;
        a.value_len = r32(rec, off + 16);
        a.value_off = off + r16(rec, off + 20);
        if (a.value_off > off + len or a.value_len > off + len - a.value_off) return error.Corrupt;
    } else {
        if (len < 64) return error.Corrupt;
        a.start_vcn = r64(rec, off + 16);
        a.runs_off = off + r16(rec, off + 32);
        a.alloc_size = r64(rec, off + 40);
        a.data_size = r64(rec, off + 48);
        a.init_size = r64(rec, off + 56);
        if (a.runs_off > off + len) return error.Corrupt;
    }
    return a;
}

/// Everything the driver needs to know about one file.
pub const File = struct {
    ref: u64 = 0,
    is_dir: bool = false,
    attrs: u32 = 0,
    size: u64 = 0,
    alloc: u64 = 0,
    nlink: u16 = 1,
    atime: u64 = 0,
    mtime: u64 = 0,
    ctime: u64 = 0,
    reparse_tag: u32 = 0,
};

pub const Volume = struct {
    rd: fr.Reader,
    sector_size: u32,
    cluster_size: u32,
    record_size: u32,
    index_block_size: u32,
    total_clusters: u64,
    serial: u64,
    /// Raw mapping pairs of $MFT's data attribute (copied out of record 0).
    mft_pairs: [MAX_RECORD]u8 = undefined,
    mft_pairs_len: usize = 0,
    mft_size: u64 = 0,
    scratch: *Scratch,

    pub fn mount(rd: fr.Reader, scratch: *Scratch) Error!Volume {
        var boot: [512]u8 = undefined;
        if (!rd.read(0, &boot)) return error.Io;
        if (!std.mem.eql(u8, boot[3..11], "NTFS    ")) return error.Invalid;
        if (boot[510] != 0x55 or boot[511] != 0xAA) return error.Invalid;

        const bps: u32 = r16(&boot, 11);
        if (bps < 256 or bps > 4096 or !std.math.isPowerOfTwo(bps)) return error.Corrupt;
        const spc_raw = boot[13];
        var spc: u32 = spc_raw;
        if (spc_raw > 128) { // 2^(256 - n) sectors per cluster
            const shift: u32 = 256 - @as(u32, spc_raw);
            if (shift > 12) return error.Corrupt;
            spc = @as(u32, 1) << @intCast(shift);
        }
        if (spc == 0 or !std.math.isPowerOfTwo(spc)) return error.Corrupt;
        const cluster_size: u32 = bps * spc;
        if (cluster_size > 2 * 1024 * 1024) return error.Corrupt;

        const total_sectors = r64(&boot, 0x28);
        if (total_sectors == 0) return error.Corrupt;
        const mft_lcn = r64(&boot, 0x30);

        const record_size = try sizeField(boot[0x40], cluster_size);
        if (record_size < 256 or record_size > MAX_RECORD or !std.math.isPowerOfTwo(record_size)) return error.Corrupt;
        const index_block_size = try sizeField(boot[0x44], cluster_size);
        if (index_block_size < 512 or !std.math.isPowerOfTwo(index_block_size)) return error.Corrupt;
        if (index_block_size > MAX_INDEX_BLOCK) return error.Unsupported;

        var v: Volume = .{
            .rd = rd,
            .sector_size = bps,
            .cluster_size = cluster_size,
            .record_size = record_size,
            .index_block_size = index_block_size,
            .total_clusters = total_sectors / spc,
            .serial = r64(&boot, 0x48),
            .scratch = scratch,
        };
        if (mft_lcn >= v.total_clusters) return error.Corrupt;

        // Record 0 describes the MFT itself: read it from its boot-sector
        // address and adopt its (possibly fragmented) data runs.
        var buf: [MAX_RECORD]u8 = undefined;
        const r0 = buf[0..record_size];
        if (!rd.read(mft_lcn * cluster_size, r0)) return error.Io;
        if (!std.mem.eql(u8, r0[0..4], "FILE")) return error.Corrupt;
        try v.applyFixup(r0);
        var found = false;
        var off: usize = r16(r0, 0x14);
        if (off < 0x30 or off >= r0.len) return error.Corrupt;
        while (try parseAttr(r0, off)) |a| : (off += a.len) {
            if (a.type == ATTR_DATA and a.name_len == 0) {
                if (!a.non_resident) return error.Corrupt;
                v.mft_size = a.data_size;
                const pairs = r0[a.runs_off .. a.off + a.len];
                if (a.start_vcn != 0 or pairs.len > v.mft_pairs.len) return error.Unsupported;
                @memcpy(v.mft_pairs[0..pairs.len], pairs);
                v.mft_pairs_len = pairs.len;
                found = true;
                break;
            }
        }
        if (!found or v.mft_pairs_len == 0) return error.Corrupt;

        const root = try v.readFile(ROOT_REF);
        if (!root.is_dir) return error.Corrupt;
        return v;
    }

    fn sizeField(raw: u8, cluster_size: u32) Error!u32 {
        const s: i8 = @bitCast(raw);
        if (s > 0) return std.math.mul(u32, @as(u32, @intCast(s)), cluster_size) catch error.Corrupt;
        if (s >= -20 and s < 0) return @as(u32, 1) << @intCast(-@as(i32, s));
        return error.Corrupt;
    }

    // ─── Records ────────────────────────────────────────────────────────

    fn applyFixup(self: *const Volume, buf: []u8) Error!void {
        const usa_off: usize = r16(buf, 4);
        const usa_cnt: usize = r16(buf, 6);
        if (usa_cnt < 2 or usa_off + usa_cnt * 2 > buf.len) return error.Corrupt;
        const stride: usize = self.sector_size;
        if ((usa_cnt - 1) * stride != buf.len) return error.Corrupt;
        const usn0 = buf[usa_off];
        const usn1 = buf[usa_off + 1];
        var i: usize = 1;
        while (i < usa_cnt) : (i += 1) {
            const end = i * stride;
            if (buf[end - 2] != usn0 or buf[end - 1] != usn1) return error.Corrupt;
            buf[end - 2] = buf[usa_off + 2 * i];
            buf[end - 1] = buf[usa_off + 2 * i + 1];
        }
    }

    fn recordOffset(self: *const Volume, n: u64) Error!u64 {
        const byte = std.math.mul(u64, n, self.record_size) catch return error.Corrupt;
        if (byte + self.record_size > self.mft_size) return error.NotFound;
        const cs: u64 = self.cluster_size;
        const vcn = byte / cs;
        const run = (try findRun(self.mft_pairs[0..self.mft_pairs_len], 0, vcn)) orelse return error.Corrupt;
        const lcn = run.lcn orelse return error.Corrupt;
        // A record must not straddle two runs.
        if ((byte + self.record_size - 1) / cs >= run.vcn + run.len) return error.Unsupported;
        return (lcn + (vcn - run.vcn)) * cs + byte % cs;
    }

    fn loadRecord(self: *const Volume, n: u64, buf: []u8) Error![]u8 {
        const rec = buf[0..self.record_size];
        const off = try self.recordOffset(n);
        if (!self.rd.read(off, rec)) return error.Io;
        if (!std.mem.eql(u8, rec[0..4], "FILE")) return error.Corrupt;
        try self.applyFixup(rec);
        if (r16(rec, 0x16) & REC_IN_USE == 0) return error.NotFound;
        const first_attr: usize = r16(rec, 0x14);
        if (first_attr < 0x30 or first_attr >= rec.len) return error.Corrupt;
        return rec;
    }

    pub fn readFile(self: *const Volume, ref: u64) Error!File {
        const n = ref & REF_MASK;
        var buf: [MAX_RECORD]u8 = undefined;
        const rec = try self.loadRecord(n, &buf);
        var f: File = .{ .ref = n, .is_dir = r16(rec, 0x16) & REC_IS_DIR != 0, .nlink = r16(rec, 0x12) };
        var off: usize = r16(rec, 0x14);
        while (try parseAttr(rec, off)) |a| : (off += a.len) {
            switch (a.type) {
                ATTR_STANDARD_INFORMATION => if (!a.non_resident and a.value_len >= 48) {
                    f.ctime = ntTime(r64(rec, a.value_off + 8));
                    f.mtime = ntTime(r64(rec, a.value_off + 16));
                    f.atime = ntTime(r64(rec, a.value_off + 24));
                    f.attrs = r32(rec, a.value_off + 32);
                },
                ATTR_DATA => if (a.name_len == 0) {
                    if (a.non_resident) {
                        if (a.start_vcn == 0) {
                            f.size = a.data_size;
                            f.alloc = a.alloc_size;
                        }
                    } else {
                        f.size = a.value_len;
                        f.alloc = a.value_len;
                    }
                },
                ATTR_REPARSE_POINT => if (!a.non_resident and a.value_len >= 8) {
                    f.reparse_tag = r32(rec, a.value_off);
                },
                else => {},
            }
        }
        if (f.is_dir) f.size = 0;
        return f;
    }

    pub fn fileKind(f: *const File) fr.FileKind {
        if (f.is_dir) return .directory;
        if (f.attrs & FILE_ATTR_REPARSE != 0 and
            (f.reparse_tag == REPARSE_SYMLINK or f.reparse_tag == REPARSE_MOUNT_POINT)) return .symlink;
        return .regular;
    }

    pub fn stat(f: *const File) fr.Stat {
        const type_bits: u32 = switch (fileKind(f)) {
            .directory => fr.S_IFDIR | 0o555,
            .symlink => fr.S_IFLNK | 0o777,
            else => fr.S_IFREG | 0o444,
        };
        return .{
            .ino = f.ref,
            .mode = type_bits,
            .nlink = if (f.nlink == 0) 1 else f.nlink,
            .size = f.size,
            .blocks = (f.alloc + 511) / 512,
            .atime = f.atime,
            .mtime = f.mtime,
            .ctime = f.ctime,
        };
    }

    // ─── Data streams ───────────────────────────────────────────────────

    const Stream = struct {
        resident: bool = false,
        res_off: usize = 0,
        res_len: usize = 0,
        size: u64 = 0,
        init_size: u64 = 0,
        /// Mapping pairs inside the record buffer, and the VCN they start at.
        pairs: []const u8 = &.{},
        start_vcn: u64 = 0,
    };

    fn streamFromAttr(rec: []const u8, a: Attr) Error!Stream {
        if (a.flags & (FLAG_COMPRESSED | FLAG_ENCRYPTED) != 0) return error.Unsupported;
        var s: Stream = .{};
        if (!a.non_resident) {
            s.resident = true;
            s.res_off = a.value_off;
            s.res_len = a.value_len;
            s.size = a.value_len;
            s.init_size = a.value_len;
            return s;
        }
        s.size = a.data_size;
        s.init_size = @min(a.init_size, a.data_size);
        s.pairs = rec[a.runs_off .. a.off + a.len];
        s.start_vcn = a.start_vcn;
        return s;
    }

    /// Locate attribute `want` (unnamed, first extent) of record `n`. The
    /// returned stream's `pairs` point into `rec_buf`, which must outlive it.
    fn findStream(self: *const Volume, n: u64, want: u32, rec_buf: []u8) Error!struct { rec: []u8, s: Stream } {
        const rec = try self.loadRecord(n, rec_buf);
        var has_list = false;
        var off: usize = r16(rec, 0x14);
        while (try parseAttr(rec, off)) |a| : (off += a.len) {
            if (a.type == want and a.name_len == 0 and (!a.non_resident or a.start_vcn == 0)) {
                return .{ .rec = rec, .s = try streamFromAttr(rec, a) };
            }
            if (a.type == ATTR_ATTRIBUTE_LIST) has_list = true;
        }
        return if (has_list) error.Unsupported else error.NotFound;
    }

    fn readRuns(self: *const Volume, pairs: []const u8, start_vcn: u64, size: u64, init_size: u64, offset: u64, buf: []u8) Error!usize {
        if (offset >= size or buf.len == 0) return 0;
        const want: usize = @intCast(@min(@as(u64, buf.len), size - offset));
        const cs: u64 = self.cluster_size;
        const volume_bytes = self.total_clusters * cs;
        var done: usize = 0;
        while (done < want) {
            const pos = offset + done;
            const vcn = pos / cs;
            const coff = pos % cs;
            const run = try findRun(pairs, start_vcn, vcn);
            const in_run: u64 = if (run) |r| (r.vcn + r.len - vcn) * cs - coff else cs - coff;
            const n: usize = @intCast(@min(in_run, @as(u64, want - done)));
            const out = buf[done..][0..n];
            if (run != null and run.?.lcn != null) {
                if (pos >= init_size) {
                    @memset(out, 0);
                } else {
                    const data_n: usize = @intCast(@min(@as(u64, n), init_size - pos));
                    const r = run.?;
                    const phys = (r.lcn.? + (vcn - r.vcn)) * cs + coff;
                    if (phys + data_n > volume_bytes) return error.Corrupt;
                    if (!self.rd.read(phys, out[0..data_n])) return error.Io;
                    if (data_n < n) @memset(out[data_n..], 0);
                }
            } else {
                @memset(out, 0); // sparse run or gap in the run list
            }
            done += n;
        }
        return done;
    }

    /// Read file contents (unnamed $DATA) of record `ref` at `offset`.
    pub fn read(self: *const Volume, ref: u64, offset: u64, buf: []u8) Error!usize {
        var rbuf: [MAX_RECORD]u8 = undefined;
        const found = try self.findStream(ref & REF_MASK, ATTR_DATA, &rbuf);
        const s = found.s;
        if (s.resident) {
            if (offset >= s.res_len) return 0;
            const n: usize = @intCast(@min(@as(u64, buf.len), s.res_len - offset));
            @memcpy(buf[0..n], found.rec[s.res_off + @as(usize, @intCast(offset)) ..][0..n]);
            return n;
        }
        return self.readRuns(s.pairs, s.start_vcn, s.size, s.init_size, offset, buf);
    }

    // ─── Volume statistics ──────────────────────────────────────────────

    /// Zero bits among the first `nbits` of attribute `attr` of record `ref`
    /// (an allocation bitmap), scanned in 4 KiB steps.
    fn countClear(self: *const Volume, ref: u64, attr: u32, nbits: u64) Error!u64 {
        var rbuf: [MAX_RECORD]u8 = undefined;
        const found = try self.findStream(ref, attr, &rbuf);
        const s = found.s;
        const need = (nbits + 7) / 8;
        if (need > MAX_BITMAP_SCAN) return error.Unsupported;
        if (s.size < need) return error.Corrupt;
        var chunk: [4096]u8 = undefined;
        var clear: u64 = 0;
        var pos: u64 = 0;
        while (pos < need) {
            const want: usize = @intCast(@min(@as(u64, chunk.len), need - pos));
            if (s.resident) {
                if (pos + want > s.res_len) return error.Corrupt;
                @memcpy(chunk[0..want], found.rec[s.res_off + @as(usize, @intCast(pos)) ..][0..want]);
            } else {
                const n = try self.readRuns(s.pairs, s.start_vcn, s.size, s.init_size, pos, chunk[0..want]);
                if (n != want) return error.Corrupt;
            }
            var i: usize = 0;
            while (i < want) : (i += 1) {
                const first = (pos + i) * 8;
                var b = chunk[i];
                // Bits past the end of the volume are padding and count as used.
                if (first + 8 > nbits) b |= @as(u8, 0xFF) << @intCast(nbits - first);
                clear += 8 - @popCount(b);
            }
            pos += want;
        }
        return clear;
    }

    /// Free clusters, from $Bitmap. Cost is proportional to the volume size.
    pub fn freeClusters(self: *const Volume) Error!u64 {
        return self.countClear(BITMAP_RECORD, ATTR_DATA, self.total_clusters);
    }

    /// statfs numbers; `free_clusters` is the result of freeClusters().
    pub fn fsStat(self: *const Volume, free_clusters: u64) Error!fr.FsStat {
        const total = self.mft_size / self.record_size;
        const free_recs = try self.countClear(0, ATTR_BITMAP, total);
        return .{
            .magic = NTFS_SUPER_MAGIC,
            .block_size = self.cluster_size,
            .blocks = self.total_clusters,
            .bfree = free_clusters,
            .bavail = free_clusters,
            .files = total,
            .ffree = free_recs,
            .name_max = 255,
            .fsid = self.serial,
        };
    }

    // ─── Directories ────────────────────────────────────────────────────

    const Entry = struct {
        len: usize,
        last: bool,
        has_sub: bool,
        sub_vcn: u64,
        ref: u64,
        key_len: usize,
        key_off: usize,
    };

    fn parseEntry(blk: []const u8, off: usize, limit: usize) Error!Entry {
        if (off + 16 > limit) return error.Corrupt;
        const len: usize = r16(blk, off + 8);
        const key_len: usize = r16(blk, off + 10);
        const flags = r16(blk, off + 12);
        if (len < 16 or len % 8 != 0 or off + len > limit) return error.Corrupt;
        var e: Entry = .{
            .len = len,
            .last = flags & 2 != 0,
            .has_sub = flags & 1 != 0,
            .sub_vcn = 0,
            .ref = r64(blk, off),
            .key_len = key_len,
            .key_off = off + 16,
        };
        if (e.has_sub) {
            if (len < 24) return error.Corrupt;
            e.sub_vcn = r64(blk, off + len - 8);
        }
        if (!e.last and (key_len < 0x42 or 16 + key_len > len)) return error.Corrupt;
        return e;
    }

    const IndexAlloc = struct {
        pairs: []const u8 = &.{},
        start_vcn: u64 = 0,
        size: u64 = 0,
        init_size: u64 = 0,
    };

    /// Walk the whole directory B-tree of `dir_ref`, calling `visit` for every
    /// user-visible name in tree order. `visit` returns false to stop.
    pub fn walkDir(self: *const Volume, dir_ref: u64, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *const fr.DirEntry) bool) Error!void {
        var rbuf: [MAX_RECORD]u8 = undefined;
        const rec = try self.loadRecord(dir_ref & REF_MASK, &rbuf);
        if (r16(rec, 0x16) & REC_IS_DIR == 0) return error.NotDir;

        var root_off: usize = 0;
        var root_len: usize = 0;
        var alloc: IndexAlloc = .{};
        var off: usize = r16(rec, 0x14);
        while (try parseAttr(rec, off)) |a| : (off += a.len) {
            if (a.type == ATTR_INDEX_ROOT and !a.non_resident) {
                root_off = a.value_off;
                root_len = a.value_len;
            } else if (a.type == ATTR_INDEX_ALLOCATION and a.non_resident and a.start_vcn == 0) {
                const st = try streamFromAttr(rec, a);
                alloc = .{ .pairs = st.pairs, .start_vcn = st.start_vcn, .size = st.size, .init_size = st.init_size };
            } else if (a.type == ATTR_ATTRIBUTE_LIST) {
                return error.Unsupported;
            }
        }
        if (root_len < 32) return error.Corrupt;
        const root = rec[root_off .. root_off + root_len];
        if (r32(root, 0) != ATTR_FILE_NAME) return error.Unsupported;
        if (r32(root, 8) != self.index_block_size) return error.Corrupt;
        const hdr_off: usize = 16;
        const entries_off: usize = hdr_off + r32(root, hdr_off);
        const total: usize = hdr_off + r32(root, hdr_off + 4);
        if (entries_off < hdr_off + 16 or total > root.len or entries_off > total) return error.Corrupt;

        var visits: u32 = 0;
        _ = try self.walkEntries(root, entries_off, total, &alloc, 0, ctx, visit, &visits);
    }

    fn walkEntries(
        self: *const Volume,
        blk: []const u8,
        start: usize,
        limit: usize,
        alloc: *const IndexAlloc,
        depth: u32,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), *const fr.DirEntry) bool,
        visits: *u32,
    ) Error!bool {
        if (depth >= MAX_TREE_DEPTH) return error.Corrupt;
        var off = start;
        while (true) {
            const e = try parseEntry(blk, off, limit);
            if (e.has_sub) {
                if (alloc.pairs.len == 0) return error.Corrupt;
                if (try self.walkSubnode(e.sub_vcn, alloc, depth + 1, ctx, visit, visits)) return true;
            }
            if (e.last) return false;
            visits.* += 1;
            if (visits.* > MAX_VISITS) return error.Corrupt;
            if (try emit(blk, e, ctx, visit)) return true;
            off += e.len;
        }
    }

    fn walkSubnode(
        self: *const Volume,
        vcn: u64,
        alloc: *const IndexAlloc,
        depth: u32,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), *const fr.DirEntry) bool,
        visits: *u32,
    ) Error!bool {
        if (depth > MAX_TREE_DEPTH) return error.Corrupt;
        // A block's VCN counts clusters when the index block is at least one
        // cluster wide, and 512-byte units when blocks are smaller than a cluster.
        const unit: u64 = if (self.index_block_size >= self.cluster_size) self.cluster_size else 512;
        const byte = std.math.mul(u64, vcn, unit) catch return error.Corrupt;
        // One buffer per level: the parent's block stays intact while we descend.
        const blk = self.scratch.blocks[depth - 1][0..self.index_block_size];
        const got = try self.readRuns(alloc.pairs, alloc.start_vcn, alloc.size, alloc.init_size, byte, blk);
        if (got != blk.len) return error.Corrupt;
        if (!std.mem.eql(u8, blk[0..4], "INDX")) return error.Corrupt;
        try self.applyFixup(blk);
        const hdr_off: usize = 24;
        const entries_off: usize = hdr_off + r32(blk, hdr_off);
        const total: usize = hdr_off + r32(blk, hdr_off + 4);
        if (entries_off < hdr_off + 16 or total > blk.len or entries_off > total) return error.Corrupt;
        return self.walkEntries(blk, entries_off, total, alloc, depth, ctx, visit, visits);
    }

    fn emit(blk: []const u8, e: Entry, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *const fr.DirEntry) bool) Error!bool {
        const key = blk[e.key_off .. e.key_off + e.key_len];
        const name_len: usize = key[0x40];
        const namespace = key[0x41];
        if (0x42 + name_len * 2 > key.len) return error.Corrupt;
        if (namespace == NS_DOS) return false; // 8.3 alias of a Win32 entry
        const flags = r32(key, 0x38);
        var d: fr.DirEntry = .{ .ino = e.ref & REF_MASK };
        d.kind = if (flags & FILE_ATTR_DIRECTORY_IDX != 0) .directory else if (flags & FILE_ATTR_REPARSE != 0) .symlink else .regular;
        var o: usize = 0;
        var i: usize = 0;
        while (i < name_len) {
            var cp: u32 = r16(key, 0x42 + i * 2);
            i += 1;
            if (cp >= 0xD800 and cp < 0xDC00 and i < name_len) {
                const lo: u32 = r16(key, 0x42 + i * 2);
                if (lo >= 0xDC00 and lo < 0xE000) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 1;
                } else cp = 0xFFFD;
            } else if (cp >= 0xD800 and cp < 0xE000) cp = 0xFFFD;
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return error.Corrupt;
            if (o + n > fr.MAX_NAME) return error.NameTooLong;
            @memcpy(d.name[o..][0..n], tmp[0..n]);
            o += n;
        }
        if (o == 0) return error.Corrupt;
        d.name_len = @intCast(o);
        return !visit(ctx, &d);
    }

    const LookupCtx = struct { want: []const u8, found: ?u64 = null };

    fn lookupVisit(c: *LookupCtx, d: *const fr.DirEntry) bool {
        if (eqlFold(d.nameSlice(), c.want)) {
            c.found = d.ino;
            return false;
        }
        return true;
    }

    /// Find `name` in directory `dir_ref` (ASCII case-insensitive).
    pub fn lookup(self: *const Volume, dir_ref: u64, name: []const u8) Error!u64 {
        if (name.len > fr.MAX_NAME) return error.NameTooLong;
        var c: LookupCtx = .{ .want = name };
        try self.walkDir(dir_ref, &c, lookupVisit);
        return c.found orelse error.NotFound;
    }

    const NthCtx = struct { target: u64, seen: u64 = 0, out: *fr.DirEntry, hit: bool = false };

    fn nthVisit(c: *NthCtx, d: *const fr.DirEntry) bool {
        if (c.seen == c.target) {
            c.out.* = d.*;
            c.hit = true;
            return false;
        }
        c.seen += 1;
        return true;
    }

    /// Visible entry number `index` (0-based, tree order); false past the end.
    pub fn readDirAt(self: *const Volume, dir_ref: u64, index: u64, out: *fr.DirEntry) Error!bool {
        var c: NthCtx = .{ .target = index, .out = out };
        try self.walkDir(dir_ref, &c, nthVisit);
        return c.hit;
    }

    // ─── Symlinks and paths ─────────────────────────────────────────────

    /// Target of a symlink / junction, with `\` turned into `/`.
    pub fn readLink(self: *const Volume, ref: u64, buf: []u8) Error!usize {
        var rbuf: [MAX_RECORD]u8 = undefined;
        const rec = try self.loadRecord(ref & REF_MASK, &rbuf);
        var off: usize = r16(rec, 0x14);
        while (try parseAttr(rec, off)) |a| : (off += a.len) {
            if (a.type != ATTR_REPARSE_POINT or a.non_resident) continue;
            const v = rec[a.value_off .. a.value_off + a.value_len];
            if (v.len < 16) return error.Corrupt;
            const tag = r32(v, 0);
            // A symlink carries a 4-byte flags word before its path buffer.
            const hdr: usize = if (tag == REPARSE_SYMLINK) 20 else if (tag == REPARSE_MOUNT_POINT) 16 else return error.Unsupported;
            const sub_off: usize = r16(v, 8);
            const sub_len: usize = r16(v, 10);
            if (hdr + sub_off + sub_len > v.len or sub_len % 2 != 0) return error.Corrupt;
            var o: usize = 0;
            var i: usize = 0;
            while (i < sub_len / 2) : (i += 1) {
                const cp: u21 = @intCast(r16(v, hdr + sub_off + i * 2));
                if (cp < 0x80) {
                    if (o >= buf.len) return error.NameTooLong;
                    buf[o] = if (cp == '\\') '/' else @intCast(cp);
                    o += 1;
                } else {
                    var tmp: [4]u8 = undefined;
                    const nb = std.unicode.utf8Encode(cp, &tmp) catch return error.Corrupt;
                    if (o + nb > buf.len) return error.NameTooLong;
                    @memcpy(buf[o..][0..nb], tmp[0..nb]);
                    o += nb;
                }
            }
            return o;
        }
        return error.Invalid;
    }

    fn parentOf(self: *const Volume, ref: u64) Error!u64 {
        if (ref == ROOT_REF) return ROOT_REF;
        var rbuf: [MAX_RECORD]u8 = undefined;
        const rec = try self.loadRecord(ref, &rbuf);
        var off: usize = r16(rec, 0x14);
        while (try parseAttr(rec, off)) |a| : (off += a.len) {
            if (a.type == ATTR_FILE_NAME and !a.non_resident and a.value_len >= 0x42) {
                return r64(rec, a.value_off) & REF_MASK;
            }
        }
        return error.Corrupt;
    }

    pub const SearchCheck = struct {
        ctx: *anyopaque,
        allow: *const fn (ctx: *anyopaque, st: fr.Stat) bool,
    };

    fn walk(self: *const Volume, start: u64, path: []const u8, depth: u8, follow_last: bool, check: ?SearchCheck) Error!u64 {
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
            if (std.mem.eql(u8, comp, "..")) {
                cur = try self.parentOf(cur);
                continue;
            }
            const dir = try self.readFile(cur);
            if (!dir.is_dir) return error.NotDir;
            if (check) |c| if (!c.allow(c.ctx, stat(&dir))) return error.Access;
            const child = try self.lookup(cur, comp);
            const cf = try self.readFile(child);
            if (fileKind(&cf) == .symlink and (!last or follow_last)) {
                var link: [512]u8 = undefined;
                const n = try self.readLink(child, &link);
                const base: u64 = if (n > 0 and link[0] == '/') ROOT_REF else cur;
                cur = try self.walk(base, link[0..n], depth + 1, true, check);
                continue;
            }
            cur = child;
        }
    }

    pub fn resolve(self: *const Volume, path: []const u8, follow_last: bool) Error!u64 {
        return self.walk(ROOT_REF, path, 0, follow_last, null);
    }

    pub fn resolveChecked(self: *const Volume, path: []const u8, follow_last: bool, check: SearchCheck) Error!u64 {
        return self.walk(ROOT_REF, path, 0, follow_last, check);
    }
};

/// ASCII-only case-insensitive equality (see the module note on $UpCase).
pub fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}
