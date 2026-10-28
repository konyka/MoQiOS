//! Pure MBR / FAT32 parsing + geometry helpers — no I/O, no globals.
//!
//! FAT32 and MBR on-disk structures are little-endian. All supported targets
//! (x86_64 / riscv64 / aarch64) are little-endian, so `@bitCast` of a byte
//! array reads an on-disk field directly and portably. Keeping this logic free
//! of block-driver / allocator dependencies lets it be unit-probed on non-x86
//! and shared unchanged by the x86 FAT32 driver.

pub const SECTOR_SIZE: u32 = 512;
pub const MAX_PARTITIONS: u32 = 4;

// ─── MBR partition table ───────────────────────────────────────────────────

pub const Partition = struct {
    bootable: bool,
    type: u8,
    lba_start: u32,
    sector_count: u32,
};

/// Parse MBR primary partition entry `idx` (0..3) from a 512-byte boot sector.
/// Returns null for an empty entry (partition type == 0).
pub fn parsePartition(buf: *const [512]u8, idx: u32) ?Partition {
    if (idx >= MAX_PARTITIONS) return null;
    const off = 446 + idx * 16;
    const ptype = buf[off + 4];
    if (ptype == 0) return null;
    const lba_start: u32 = @bitCast([4]u8{ buf[off + 8], buf[off + 9], buf[off + 10], buf[off + 11] });
    const sector_count: u32 = @bitCast([4]u8{ buf[off + 12], buf[off + 13], buf[off + 14], buf[off + 15] });
    if (lba_start == 0 or sector_count == 0) return null;
    return .{
        .bootable = buf[off] == 0x80,
        .type = ptype,
        .lba_start = lba_start,
        .sector_count = sector_count,
    };
}

/// FAT32 partition type codes (CHS-limited 0x0B and LBA 0x0C).
pub fn isFat32Type(ptype: u8) bool {
    return ptype == 0x0B or ptype == 0x0C;
}

// ─── FAT32 BIOS Parameter Block ────────────────────────────────────────────

pub const Bpb = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    num_fats: u8,
    root_cluster: u32,
    total_sectors: u32,
    fat_size_sectors: u32,
    // Derived geometry (absolute LBAs, relative to the volume's lba_start).
    fat_start: u32,
    data_start: u32,
    sector_mask: u32,
    total_data_clusters: u32,
    /// Absolute LBA of the FSInfo sector, 0 when the volume declares none.
    fsinfo_lba: u32 = 0,
};

/// Parse and validate a FAT32 BPB from a 512-byte boot sector whose volume
/// begins at absolute `lba_start`. Returns null if it is not a valid FAT32
/// volume (bad sector size / geometry / FS-type signature).
pub fn parseBpb(buf: *const [512]u8, lba_start: u32) ?Bpb {
    const bytes_per_sector: u16 = @bitCast([2]u8{ buf[11], buf[12] });
    const sectors_per_cluster: u8 = buf[13];
    const reserved_sectors: u16 = @bitCast([2]u8{ buf[14], buf[15] });
    const num_fats: u8 = buf[16];
    const total_sectors_16: u16 = @bitCast([2]u8{ buf[19], buf[20] });
    const total_sectors_32: u32 = @bitCast([4]u8{ buf[32], buf[33], buf[34], buf[35] });
    const fat_size_32: u32 = @bitCast([4]u8{ buf[36], buf[37], buf[38], buf[39] });
    const root_cluster: u32 = @bitCast([4]u8{ buf[44], buf[45], buf[46], buf[47] });

    if (bytes_per_sector != 512 or sectors_per_cluster == 0 or
        sectors_per_cluster > 128 or (sectors_per_cluster & (sectors_per_cluster - 1)) != 0 or
        reserved_sectors == 0 or num_fats == 0 or fat_size_32 == 0) return null;

    // FS type string at 82..87 should read "FAT32"; also accept images that
    // omit it as long as the extended boot signature (0x29 @ 66) or a leading
    // 'F' @ 82 is present (matches the historical driver's leniency).
    const sig_ok = buf[82] == 'F' and buf[83] == 'A' and buf[84] == 'T' and
        buf[85] == '3' and buf[86] == '2';
    if (!sig_ok and buf[66] != 0x29 and buf[82] != 'F') return null;

    const total_sectors: u32 = if (total_sectors_32 != 0) total_sectors_32 else total_sectors_16;
    const fat_span = @as(u64, num_fats) * fat_size_32;
    const metadata = @as(u64, reserved_sectors) + fat_span;
    if (total_sectors == 0 or metadata >= total_sectors) return null;
    const fat_start_u64 = @as(u64, lba_start) + reserved_sectors;
    const data_start_u64 = fat_start_u64 + fat_span;
    if (data_start_u64 > 0xFFFF_FFFF or @as(u64, lba_start) + total_sectors > 0x1_0000_0000) return null;
    const data_sectors = total_sectors - @as(u32, @intCast(metadata));
    const total_data_clusters = data_sectors / @as(u32, sectors_per_cluster);
    if (total_data_clusters == 0 or root_cluster < 2 or @as(u64, root_cluster - 2) >= total_data_clusters) return null;

    const fsinfo_rel: u16 = @bitCast([2]u8{ buf[48], buf[49] });
    const fsinfo_lba: u32 = if (fsinfo_rel != 0 and fsinfo_rel != 0xFFFF and fsinfo_rel < reserved_sectors)
        lba_start + fsinfo_rel
    else
        0;

    return .{
        .fsinfo_lba = fsinfo_lba,
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sectors = reserved_sectors,
        .num_fats = num_fats,
        .root_cluster = root_cluster,
        .total_sectors = total_sectors,
        .fat_size_sectors = fat_size_32,
        .fat_start = @intCast(fat_start_u64),
        .data_start = @intCast(data_start_u64),
        .sector_mask = sectors_per_cluster - 1,
        .total_data_clusters = total_data_clusters,
    };
}

/// Mark the FSInfo free-cluster count and next-free hint as unknown
/// (0xFFFFFFFF). The driver does not track them, so once the FAT changes the
/// stored values are stale; "unknown" is the spec-sanctioned way to say so.
/// Returns false (and leaves the sector alone) when it is not a valid FSInfo.
pub fn invalidateFsInfo(sector: []u8) bool {
    if (sector.len < 512) return false;
    const lead: u32 = @bitCast([4]u8{ sector[0], sector[1], sector[2], sector[3] });
    const struc: u32 = @bitCast([4]u8{ sector[484], sector[485], sector[486], sector[487] });
    if (lead != 0x41615252 or struc != 0x61417272) return false;
    @memset(sector[488..496], 0xFF);
    return true;
}

// ─── Cluster / FAT arithmetic ──────────────────────────────────────────────

/// LBA of the first sector of data `cluster` (valid clusters start at 2).
pub fn clusterToLba(data_start: u32, sectors_per_cluster: u8, cluster: u32) u32 {
    if (cluster < 2 or sectors_per_cluster == 0) return 0;
    const lba = @as(u64, data_start) + @as(u64, cluster - 2) * sectors_per_cluster;
    return if (lba <= 0xFFFF_FFFF) @intCast(lba) else 0;
}

pub const FatLoc = struct { sector: u32, offset: u32 };

/// Sector + byte offset of the 32-bit FAT entry describing `cluster`.
pub fn fatEntryLocation(fat_start: u32, bytes_per_sector: u16, cluster: u32) FatLoc {
    if (bytes_per_sector < 4 or bytes_per_sector % 4 != 0) return .{ .sector = 0, .offset = 0 };
    const fat_offset = @as(u64, cluster) * 4;
    const sector = @as(u64, fat_start) + fat_offset / bytes_per_sector;
    if (sector > 0xFFFF_FFFF) return .{ .sector = 0, .offset = 0 };
    return .{
        .sector = @intCast(sector),
        .offset = @intCast(fat_offset % bytes_per_sector),
    };
}

/// Extract the 28-bit FAT32 entry value from a sector buffer at `offset`.
pub fn fatEntryValue(sector_buf: []const u8, offset: u32) ?u32 {
    if (offset > sector_buf.len or sector_buf.len - offset < 4) return null;
    const raw: u32 = @bitCast([4]u8{
        sector_buf[offset],
        sector_buf[offset + 1],
        sector_buf[offset + 2],
        sector_buf[offset + 3],
    });
    return raw & 0x0FFFFFFF;
}

// ─── Cluster classification (28-bit masked) ────────────────────────────────

/// Exclusive upper bound on allocatable cluster numbers. `foreign_lba` is the
/// first sector of another volume that shares the disk with this FAT32 volume
/// (0 when there is none). The BPB of the boot disk claims the whole disk even
/// though ext2 starts at LBA 32768, so without this bound the allocator handed
/// out clusters that lie inside ext2. A cluster that would straddle the
/// boundary is excluded too.
pub fn allocLimitCluster(data_start: u32, sectors_per_cluster: u8, total_data_clusters: u32, foreign_lba: u32) u32 {
    const own = total_data_clusters + 2;
    if (foreign_lba == 0 or sectors_per_cluster == 0) return own;
    if (foreign_lba <= data_start) return 2;
    const fits: u32 = (foreign_lba - data_start) / @as(u32, sectors_per_cluster);
    return @min(own, fits + 2);
}

/// Clusters a file's chain holds for `size` bytes. A file created empty
/// already owns one cluster (createFile preallocates it), so an empty file
/// with a first cluster counts as one — the first write must reuse it rather
/// than append a second cluster and leave the first one forever unused.
pub fn ownedClusters(size: u32, cluster_size: u32, has_first_cluster: bool) u32 {
    if (cluster_size == 0) return 0;
    const by_size = (size + cluster_size - 1) / cluster_size;
    if (by_size == 0 and has_first_cluster) return 1;
    return by_size;
}

/// Sector LBAs of `sector` (an LBA inside FAT #0) in every FAT copy, so a FAT
/// update reaches the mirror FATs too (BPB_NumFATs; mirroring is on unless
/// BPB_ExtFlags says otherwise, which this driver does not use). Returns the
/// number of LBAs written into `out`.
pub fn fatCopySectors(fat_start: u32, fat_size_sectors: u32, num_fats: u8, sector: u32, out: []u32) u32 {
    const rel = sector - fat_start;
    const n: u32 = @min(@as(u32, @max(num_fats, 1)), @as(u32, @intCast(out.len)));
    for (0..n) |i| out[i] = fat_start + @as(u32, @intCast(i)) * fat_size_sectors + rel;
    return n;
}

pub fn isEndOfChain(entry: u32) bool {
    return (entry & 0x0FFFFFFF) >= 0x0FFFFFF8;
}
pub fn isFreeCluster(entry: u32) bool {
    return (entry & 0x0FFFFFFF) == 0;
}
pub fn isBadCluster(entry: u32) bool {
    return (entry & 0x0FFFFFFF) == 0x0FFFFFF7;
}

/// A cluster index addresses real file data iff it is >= 2 and not an
/// end-of-chain / reserved marker.
pub fn isValidDataCluster(cluster: u32) bool {
    return cluster >= 2 and cluster < 0x0FFFFFF8;
}

// ─── Directory entry / 8.3 + LFN helpers ───────────────────────────────────

pub const ATTR_READ_ONLY: u8 = 0x01;
pub const ATTR_HIDDEN: u8 = 0x02;
pub const ATTR_SYSTEM: u8 = 0x04;
pub const ATTR_VOLUME_ID: u8 = 0x08;
pub const ATTR_DIRECTORY: u8 = 0x10;
pub const ATTR_ARCHIVE: u8 = 0x20;
/// LFN entries use ATTR_READ_ONLY|HIDDEN|SYSTEM|VOLUME_ID (== 0x0F).
pub const ATTR_LFN: u8 = 0x0F;

pub fn isLfnAttr(attr: u8) bool {
    return attr == ATTR_LFN;
}
pub fn isVolumeLabelAttr(attr: u8) bool {
    return attr == ATTR_VOLUME_ID;
}
pub fn isDirectoryAttr(attr: u8) bool {
    return (attr & ATTR_DIRECTORY) != 0;
}

/// Decode an 11-byte on-disk 8.3 name into a readable lowercase form
/// (`NAME.EXT`, no trailing spaces). Returns the number of bytes written.
pub fn decode83Name(short_name: *const [11]u8, out: []u8) u32 {
    var ni: u32 = 0;
    for (0..8) |j| {
        const c = short_name[j];
        if (c == 0x20) break;
        if (ni >= out.len) return ni;
        out[ni] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        ni += 1;
    }
    if (short_name[8] != 0x20 and ni < out.len) {
        out[ni] = '.';
        ni += 1;
        for (8..11) |j| {
            const c = short_name[j];
            if (c == 0x20) break;
            if (ni >= out.len) return ni;
            out[ni] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            ni += 1;
        }
    }
    return ni;
}

/// Encode a readable name into an 11-byte space-padded uppercase 8.3 field.
/// Behaviour matches the historical FAT32 driver (truncate base/ext; no
/// illegal-char validation).
pub fn encode83Name(name: []const u8, out: *[11]u8) void {
    @memset(out, 0x20);
    var dot_pos: usize = name.len;
    for (0..name.len) |j| {
        if (name[j] == '.') {
            dot_pos = j;
            break;
        }
    }
    const base_len = if (dot_pos < 8) dot_pos else @as(usize, 8);
    for (0..base_len) |j| {
        const c = name[j];
        out[j] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    if (dot_pos < name.len) {
        const ext_start = dot_pos + 1;
        for (0..3) |j| {
            if (ext_start + j < name.len) {
                const c = name[ext_start + j];
                out[8 + j] = if (c >= 'a' and c <= 'z') c - 32 else c;
            }
        }
    }
}

/// First cluster from a 32-byte directory entry (hi@20, lo@26).
pub fn dirEntryFirstCluster(entry: [*]const u8) u32 {
    const lo: u16 = @bitCast([2]u8{ entry[26], entry[27] });
    const hi: u16 = @bitCast([2]u8{ entry[20], entry[21] });
    return @as(u32, lo) | (@as(u32, hi) << 16);
}

/// File size from a 32-byte directory entry (@28).
pub fn dirEntrySize(entry: [*]const u8) u32 {
    return @bitCast([4]u8{ entry[28], entry[29], entry[30], entry[31] });
}

pub fn setDirEntryFirstCluster(entry: [*]u8, cluster: u32) void {
    entry[26] = @truncate(cluster);
    entry[27] = @truncate(cluster >> 8);
    entry[20] = @truncate(cluster >> 16);
    entry[21] = @truncate(cluster >> 24);
}

pub fn setDirEntrySize(entry: [*]u8, size: u32) void {
    entry[28] = @truncate(size);
    entry[29] = @truncate(size >> 8);
    entry[30] = @truncate(size >> 16);
    entry[31] = @truncate(size >> 24);
}

/// Microsoft LFN checksum over the 11-byte short name (used by LFN slots).
pub fn lfnChecksum(short_name: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (short_name.*) |c| {
        sum = ((sum & 1) << 7) +% (sum >> 1) +% c;
    }
    return sum;
}

/// Extract up to 13 UCS-2 code units from one 32-byte LFN directory entry.
/// Stops before a 0x0000 terminator; 0xFFFF padding is ignored as end.
pub fn decodeLfnEntryChars(entry: [*]const u8, out: *[13]u16) u32 {
    const offsets = [_]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    var n: u32 = 0;
    for (offsets) |off| {
        const ch: u16 = @bitCast([2]u8{ entry[off], entry[off + 1] });
        if (ch == 0x0000 or ch == 0xFFFF) break;
        out[n] = ch;
        n += 1;
    }
    return n;
}

/// LFN sequence number in bits 0..4; bit 6 marks the last (highest) slot.
pub fn lfnSequence(entry_first_byte: u8) u5 {
    return @truncate(entry_first_byte & 0x1F);
}
pub fn isLastLfnSlot(entry_first_byte: u8) bool {
    return (entry_first_byte & 0x40) != 0;
}

/// Checksum byte stored in an LFN directory entry (@13).
pub fn lfnEntryChecksum(entry: [*]const u8) u8 {
    return entry[13];
}

/// Max LFN slots per short entry (255 UTF-16 units / 13 ≈ 20).
pub const MAX_LFN_SLOTS: u32 = 20;

fn utf8EncodeCp(cp: u32, out: []u8) ?u32 {
    if (cp < 0x80) {
        if (out.len < 1) return null;
        out[0] = @truncate(cp);
        return 1;
    }
    if (cp < 0x800) {
        if (out.len < 2) return null;
        out[0] = @truncate(0xC0 | (cp >> 6));
        out[1] = @truncate(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (out.len < 3) return null;
        out[0] = @truncate(0xE0 | (cp >> 12));
        out[1] = @truncate(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @truncate(0x80 | (cp & 0x3F));
        return 3;
    }
    if (cp <= 0x10FFFF) {
        if (out.len < 4) return null;
        out[0] = @truncate(0xF0 | (cp >> 18));
        out[1] = @truncate(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @truncate(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @truncate(0x80 | (cp & 0x3F));
        return 4;
    }
    return null;
}

/// Number of trailing LFN slots in `slots` (forward-scan order, the run
/// directly preceding a short entry) that belong to `short_name`: a chain
/// that starts with the last-slot marker, counts down to sequence 1 and
/// carries the short name's checksum. Deleting the file must tombstone
/// exactly these; an older orphaned run in front of them is not touched.
pub fn ownedLfnRun(slots: []const [*]const u8, short_name: *const [11]u8) u32 {
    const sum = lfnChecksum(short_name);
    var k: u32 = 0;
    var expect_seq: u32 = 1;
    var i = slots.len;
    while (i > 0) {
        i -= 1;
        const e = slots[i];
        if (lfnEntryChecksum(e) != sum or lfnSequence(e[0]) != expect_seq) return 0;
        k += 1;
        if (isLastLfnSlot(e[0])) return k;
        expect_seq += 1;
        if (expect_seq > MAX_LFN_SLOTS) return 0;
    }
    return 0;
}

/// Collects the LFN slots that precede a short entry during a forward
/// directory scan. A slot carrying the last-slot marker (0x40) always begins a
/// new name: anything collected before it belongs to an earlier, orphaned
/// chain (for example a deleted file whose short entry was tombstoned but
/// whose LFN slots were left behind) and must not be glued onto this one.
pub const LfnAccumulator = struct {
    raw: [MAX_LFN_SLOTS][32]u8 = undefined,
    count: u32 = 0,

    pub fn reset(self: *LfnAccumulator) void {
        self.count = 0;
    }

    pub fn push(self: *LfnAccumulator, entry: [*]const u8) void {
        if (isLastLfnSlot(entry[0])) self.count = 0;
        if (self.count >= MAX_LFN_SLOTS) {
            self.count = 0;
            return;
        }
        @memcpy(self.raw[self.count][0..32], entry[0..32]);
        self.count += 1;
    }

    /// Assemble the pending chain for `short_name` and clear it. Null when
    /// nothing is pending or the chain does not belong to this short entry.
    pub fn take(self: *LfnAccumulator, short_name: *const [11]u8, out: []u8) ?u32 {
        if (self.count == 0) return null;
        var ptrs: [MAX_LFN_SLOTS][*]const u8 = undefined;
        for (0..self.count) |i| ptrs[i] = &self.raw[i];
        const n = self.count;
        self.count = 0;
        return assembleLfnUtf8(ptrs[0..n], short_name, out);
    }
};

/// Assemble one or more on-disk LFN directory entries into a UTF-8 name.
///
/// `lfn_entries` must be in forward-scan order: the first entry carries the
/// last-slot marker (`0x40 | N`), then N-1 … 1, immediately before the short
/// entry. All slot checksums must match `lfnChecksum(short_name)`. Returns the
/// UTF-8 byte length, or null on any structural / checksum error.
pub fn assembleLfnUtf8(
    lfn_entries: []const [*]const u8,
    short_name: *const [11]u8,
    out: []u8,
) ?u32 {
    if (lfn_entries.len == 0 or lfn_entries.len > MAX_LFN_SLOTS) return null;
    const expect = lfnChecksum(short_name);

    var slot_chars: [MAX_LFN_SLOTS][13]u16 = undefined;
    var slot_lens: [MAX_LFN_SLOTS]u32 = @splat(0);
    var slot_present: [MAX_LFN_SLOTS]bool = @splat(false);
    var max_seq: u32 = 0;

    for (lfn_entries, 0..) |entry, i| {
        if (!isLfnAttr(entry[11])) return null;
        const first = entry[0];
        if (first == 0x00 or first == 0xE5) return null;
        if ((first & 0xA0) != 0 or entry[12] != 0 or entry[26] != 0 or entry[27] != 0) return null;
        const seq: u32 = lfnSequence(first);
        if (seq == 0 or seq > MAX_LFN_SLOTS) return null;
        if (i == 0) {
            if (!isLastLfnSlot(first)) return null;
            max_seq = seq;
        } else if (isLastLfnSlot(first)) {
            return null;
        }
        if (i > 0) {
            if (i >= max_seq or seq != max_seq - @as(u32, @intCast(i))) return null;
        }
        if (lfnEntryChecksum(entry) != expect) return null;
        if (slot_present[seq - 1]) return null;
        slot_lens[seq - 1] = decodeLfnEntryChars(entry, &slot_chars[seq - 1]);
        slot_present[seq - 1] = true;
    }
    if (max_seq != lfn_entries.len) return null;
    for (0..max_seq) |si| {
        if (!slot_present[si]) return null;
    }

    var out_len: u32 = 0;
    var pending_hi: ?u16 = null;
    for (0..max_seq) |si| {
        const n = slot_lens[si];
        for (0..n) |ci| {
            const unit = slot_chars[si][ci];
            var cp: u32 = undefined;
            if (pending_hi) |hi| {
                // Expect a low surrogate to finish the pair.
                if (unit < 0xDC00 or unit > 0xDFFF) return null;
                cp = 0x10000 + (@as(u32, hi - 0xD800) << 10) + (unit - 0xDC00);
                pending_hi = null;
            } else if (unit >= 0xD800 and unit <= 0xDBFF) {
                pending_hi = unit;
                continue;
            } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
                return null; // lone low surrogate
            } else {
                cp = unit;
            }
            if (out_len > out.len) return null;
            const wrote = utf8EncodeCp(cp, out[out_len..]) orelse return null;
            out_len += wrote;
        }
    }
    if (pending_hi != null) return null;
    return out_len;
}

// ─── LFN encode / 8.3 alias (SK-67) ────────────────────────────────────────

const LFN_CHAR_OFFSETS = [_]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };

/// Decode UTF-8 into UTF-16 code units (BMP + surrogate pairs). Returns unit
/// count, or null on invalid UTF-8 / overflow.
pub fn utf8ToUtf16(src: []const u8, out: []u16) ?u32 {
    var i: usize = 0;
    var o: u32 = 0;
    while (i < src.len) {
        const c0 = src[i];
        var cp: u32 = undefined;
        var adv: usize = undefined;
        if (c0 < 0x80) {
            cp = c0;
            adv = 1;
        } else if ((c0 & 0xE0) == 0xC0) {
            if (i + 1 >= src.len) return null;
            const c1 = src[i + 1];
            if ((c1 & 0xC0) != 0x80) return null;
            cp = (@as(u32, c0 & 0x1F) << 6) | (c1 & 0x3F);
            if (cp < 0x80) return null;
            adv = 2;
        } else if ((c0 & 0xF0) == 0xE0) {
            if (i + 2 >= src.len) return null;
            const c1 = src[i + 1];
            const c2 = src[i + 2];
            if ((c1 & 0xC0) != 0x80 or (c2 & 0xC0) != 0x80) return null;
            cp = (@as(u32, c0 & 0x0F) << 12) | (@as(u32, c1 & 0x3F) << 6) | (c2 & 0x3F);
            if (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
            adv = 3;
        } else if ((c0 & 0xF8) == 0xF0) {
            if (i + 3 >= src.len) return null;
            const c1 = src[i + 1];
            const c2 = src[i + 2];
            const c3 = src[i + 3];
            if ((c1 & 0xC0) != 0x80 or (c2 & 0xC0) != 0x80 or (c3 & 0xC0) != 0x80) return null;
            cp = (@as(u32, c0 & 0x07) << 18) | (@as(u32, c1 & 0x3F) << 12) |
                (@as(u32, c2 & 0x3F) << 6) | (c3 & 0x3F);
            if (cp < 0x10000 or cp > 0x10FFFF) return null;
            adv = 4;
        } else {
            return null;
        }
        i += adv;
        if (cp < 0x10000) {
            if (o >= out.len) return null;
            out[o] = @intCast(cp);
            o += 1;
        } else {
            if (o + 1 >= out.len) return null;
            const x = cp - 0x10000;
            out[o] = @intCast(0xD800 + (x >> 10));
            out[o + 1] = @intCast(0xDC00 + (x & 0x3FF));
            o += 2;
        }
    }
    return o;
}

/// The FAT32 volume is flat: this driver only knows root-directory entries.
/// A path with a '/' after its first character names something inside a
/// directory, which FAT32 here cannot hold, so it is not a FAT32 name: open
/// and create must return "not found" and let the VFS try ext2. Accepting it
/// created a root entry literally named "testdir/x" (invalid on FAT, flagged
/// by fsck) that shadowed the ext2 file of the same path. A single leading
/// '/' is still part of the stored name, as it always was.
pub fn isRootName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name[1..]) |c| if (c == '/') return false;
    return true;
}

/// True when `name` round-trips through 8.3 encode/decode (case-insensitive).
pub fn fits83Name(name: []const u8) bool {
    if (name.len == 0 or name.len > 12) return false;
    var short: [11]u8 = undefined;
    encode83Name(name, &short);
    var decoded: [12]u8 = undefined;
    const n = decode83Name(&short, decoded[0..]);
    if (n != name.len) return false;
    for (0..n) |i| {
        const a = name[i];
        const b = decoded[i];
        const al: u8 = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const bl: u8 = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (al != bl) return false;
    }
    return true;
}

fn dosUpperChar(c: u8) ?u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if (c >= 'A' and c <= 'Z') return c;
    if (c >= '0' and c <= '9') return c;
    // Common 8.3-safe punctuation retained by historical Windows short names.
    return switch (c) {
        '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&' => c,
        else => null,
    };
}

/// Build a lossy DOS 8.3 alias `XXXXXX~N.EXT` for a long UTF-8 name.
pub fn make83Alias(name: []const u8, suffix_n: u8, out: *[11]u8) void {
    @memset(out, 0x20);
    var last_dot: usize = name.len;
    for (0..name.len) |i| {
        if (name[i] == '.') last_dot = i;
    }
    const base = if (last_dot < name.len) name[0..last_dot] else name;
    const ext = if (last_dot < name.len) name[last_dot + 1 ..] else name[0..0];

    var bi: usize = 0;
    for (base) |c| {
        if (bi >= 6) break;
        if (dosUpperChar(c)) |u| {
            out[bi] = u;
            bi += 1;
        }
    }
    if (bi == 0) {
        out[0] = 'F';
        bi = 1;
    }
    out[bi] = '~';
    const digit: u8 = if (suffix_n == 0) 1 else suffix_n;
    out[bi + 1] = '0' + (digit % 10);

    var ei: usize = 0;
    for (ext) |c| {
        if (ei >= 3) break;
        if (dosUpperChar(c)) |u| {
            out[8 + ei] = u;
            ei += 1;
        }
    }
}

/// Encode one 32-byte LFN directory entry from up to 13 UTF-16 units.
pub fn encodeLfnEntry(out: [*]u8, seq: u8, is_last: bool, checksum: u8, chars: []const u16) void {
    @memset(out[0..32], 0xFF);
    out[0] = if (is_last) seq | 0x40 else seq;
    out[11] = ATTR_LFN;
    out[12] = 0;
    out[13] = checksum;
    out[26] = 0;
    out[27] = 0;
    var i: usize = 0;
    while (i < 13) : (i += 1) {
        const ch: u16 = if (i < chars.len) chars[i] else if (i == chars.len) 0 else 0xFFFF;
        const off = LFN_CHAR_OFFSETS[i];
        out[off] = @truncate(ch);
        out[off + 1] = @truncate(ch >> 8);
    }
}

/// True if the 11-byte short name already appears as a non-LFN/non-volume entry
/// in a 512-byte directory sector.
pub fn shortNameTaken(sector: [*]const u8, short_name: *const [11]u8) bool {
    for (0..16) |i| {
        const off = i * 32;
        if (sector[off] == 0x00) break;
        if (sector[off] == 0xE5) continue;
        const attr = sector[off + 11];
        if (isLfnAttr(attr) or isVolumeLabelAttr(attr)) continue;
        var same = true;
        for (0..11) |j| {
            if (sector[off + j] != short_name[j]) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

/// Find `need` consecutive free (0x00/0xE5) directory slots in one sector.
/// Returns the starting entry index (0..15), or null.
pub fn findConsecutiveFree(sector: [*]const u8, need: u32) ?u32 {
    if (need == 0 or need > 16) return null;
    var run_start: ?u32 = null;
    var run_len: u32 = 0;
    for (0..16) |i| {
        const off = i * 32;
        const free = sector[off] == 0x00 or sector[off] == 0xE5;
        if (free) {
            if (run_start == null) run_start = @intCast(i);
            run_len += 1;
            if (run_len >= need) return run_start;
            // A 0x00 free slot means the rest of the directory is empty —
            // remaining slots in this sector are also free for our purposes.
            if (sector[off] == 0x00) {
                const avail = 16 - (run_start orelse @as(u32, @intCast(i)));
                if (avail >= need) return run_start;
            }
        } else {
            run_start = null;
            run_len = 0;
        }
    }
    return null;
}

/// True if this sector contains an end-of-directory marker (first-byte 0x00).
pub fn sectorHasDirEnd(sector: [*]const u8) bool {
    for (0..16) |i| {
        if (sector[i * 32] == 0x00) return true;
    }
    return false;
}

/// Split a linear directory-entry index into (sector_index, entry_in_sector).
pub fn splitDirIndex(global_entry: u32) struct { sector: u32, entry: u32 } {
    return .{ .sector = global_entry / 16, .entry = global_entry % 16 };
}

/// Find `need` consecutive free slots across a multi-sector directory window
/// (LFN chains may span sector boundaries). Returns the starting linear entry
/// index, or null.
pub fn findConsecutiveFreeMulti(sectors: []const [*]const u8, need: u32) ?u32 {
    if (need == 0 or sectors.len == 0) return null;
    const total = @as(u32, @intCast(sectors.len)) * 16;
    if (need > total) return null;

    var run_start: ?u32 = null;
    var run_len: u32 = 0;
    var gi: u32 = 0;
    while (gi < total) : (gi += 1) {
        const sec = sectors[gi / 16];
        const first = sec[(gi % 16) * 32];
        const free = first == 0x00 or first == 0xE5;
        if (free) {
            if (run_start == null) run_start = gi;
            run_len += 1;
            if (run_len >= need) return run_start;
            if (first == 0x00) {
                // End-of-directory: the remainder of the window is empty.
                const avail = total - (run_start orelse gi);
                if (avail >= need) return run_start;
                return null;
            }
        } else {
            run_start = null;
            run_len = 0;
        }
    }
    return null;
}

/// Build forward-scan-ordered LFN entries for `utf8_name` keyed to `short_name`.
/// Returns the number of 32-byte slots written into `out_entries`, or null.
pub fn buildLfnEntries(
    utf8_name: []const u8,
    short_name: *const [11]u8,
    out_entries: [][32]u8,
) ?u32 {
    if (utf8_name.len == 0 or out_entries.len == 0) return null;
    for (utf8_name) |byte| if (byte == 0) return null;
    var units: [260]u16 = undefined;
    const nunits = utf8ToUtf16(utf8_name, units[0..]) orelse return null;
    if (nunits == 0 or nunits > 255) return null;
    const nslots = (nunits + 12) / 13;
    if (nslots == 0 or nslots > MAX_LFN_SLOTS or nslots > out_entries.len) return null;
    const sum = lfnChecksum(short_name);

    var out_i: u32 = 0;
    var seq: u32 = nslots;
    while (seq >= 1) : (seq -= 1) {
        const start = (seq - 1) * 13;
        const remain = nunits - start;
        const take = if (remain > 13) @as(u32, 13) else remain;
        encodeLfnEntry(&out_entries[out_i], @intCast(seq), seq == nslots, sum, units[start .. start + take]);
        out_i += 1;
    }
    return nslots;
}

// ─── FAT timestamps (local time is taken as UTC) ────────────────────────

/// Days since 1970-01-01 for a civil date (proleptic Gregorian).
fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const DosStamp = struct { date: u16, time: u16 };

/// Unix seconds → FAT date/time (2-second resolution, years 1980..2107).
/// Out-of-range values clamp to the FAT epoch/limit.
pub fn unixToDos(unix: u64) DosStamp {
    const min_unix: u64 = 315532800; // 1980-01-01
    const max_unix: u64 = 4354819198; // 2107-12-31 23:59:58
    const t = @min(@max(unix, min_unix), max_unix);
    const days: i64 = @intCast(t / 86400);
    const secs: u32 = @intCast(t % 86400);
    // civil from days (inverse of daysFromCivil)
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: i64 = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    const year_off: u16 = @intCast(y - 1980);
    return .{
        .date = (year_off << 9) | (@as(u16, @intCast(m)) << 5) | @as(u16, @intCast(d)),
        .time = (@as(u16, @intCast(secs / 3600)) << 11) | (@as(u16, @intCast((secs / 60) % 60)) << 5) | @as(u16, @intCast((secs % 60) / 2)),
    };
}

/// FAT date/time → Unix seconds. A zero date (never stamped) maps to 0.
pub fn dosToUnix(date: u16, time: u16) u64 {
    if (date == 0) return 0;
    const y: i64 = 1980 + @as(i64, date >> 9);
    const m: u32 = @max(1, @min(12, (date >> 5) & 0xF));
    const d: u32 = @max(1, date & 0x1F);
    const days = daysFromCivil(y, m, d);
    const secs: u64 = @as(u64, time >> 11) * 3600 + @as(u64, (time >> 5) & 0x3F) * 60 + @as(u64, time & 0x1F) * 2;
    return @as(u64, @intCast(days)) * 86400 + secs;
}

/// Write-time (@22/@24), creation (@14/@16) and access date (@18) fields.
pub fn setDirEntryMtime(entry: [*]u8, s: DosStamp) void {
    entry[22] = @truncate(s.time);
    entry[23] = @truncate(s.time >> 8);
    entry[24] = @truncate(s.date);
    entry[25] = @truncate(s.date >> 8);
    entry[18] = @truncate(s.date);
    entry[19] = @truncate(s.date >> 8);
}

pub fn setDirEntryCtime(entry: [*]u8, s: DosStamp) void {
    entry[14] = @truncate(s.time);
    entry[15] = @truncate(s.time >> 8);
    entry[16] = @truncate(s.date);
    entry[17] = @truncate(s.date >> 8);
}

pub fn dirEntryMtime(entry: [*]const u8) u64 {
    const time: u16 = @bitCast([2]u8{ entry[22], entry[23] });
    const date: u16 = @bitCast([2]u8{ entry[24], entry[25] });
    return dosToUnix(date, time);
}
