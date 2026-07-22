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
pub fn parsePartition(buf: [*]const u8, idx: u32) ?Partition {
    const off = 446 + idx * 16;
    const ptype = buf[off + 4];
    if (ptype == 0) return null;
    return .{
        .bootable = buf[off] == 0x80,
        .type = ptype,
        .lba_start = @bitCast([4]u8{ buf[off + 8], buf[off + 9], buf[off + 10], buf[off + 11] }),
        .sector_count = @bitCast([4]u8{ buf[off + 12], buf[off + 13], buf[off + 14], buf[off + 15] }),
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
};

/// Parse and validate a FAT32 BPB from a 512-byte boot sector whose volume
/// begins at absolute `lba_start`. Returns null if it is not a valid FAT32
/// volume (bad sector size / geometry / FS-type signature).
pub fn parseBpb(buf: [*]const u8, lba_start: u32) ?Bpb {
    const bytes_per_sector: u16 = @bitCast([2]u8{ buf[11], buf[12] });
    const sectors_per_cluster: u8 = buf[13];
    const reserved_sectors: u16 = @bitCast([2]u8{ buf[14], buf[15] });
    const num_fats: u8 = buf[16];
    const total_sectors_16: u16 = @bitCast([2]u8{ buf[19], buf[20] });
    const total_sectors_32: u32 = @bitCast([4]u8{ buf[32], buf[33], buf[34], buf[35] });
    const fat_size_32: u32 = @bitCast([4]u8{ buf[36], buf[37], buf[38], buf[39] });
    const root_cluster: u32 = @bitCast([4]u8{ buf[44], buf[45], buf[46], buf[47] });

    if (bytes_per_sector != 512 or sectors_per_cluster == 0 or reserved_sectors == 0) return null;

    // FS type string at 82..87 should read "FAT32"; also accept images that
    // omit it as long as the extended boot signature (0x29 @ 66) or a leading
    // 'F' @ 82 is present (matches the historical driver's leniency).
    const sig_ok = buf[82] == 'F' and buf[83] == 'A' and buf[84] == 'T' and
        buf[85] == '3' and buf[86] == '2';
    if (!sig_ok and buf[66] != 0x29 and buf[82] != 'F') return null;

    const total_sectors: u32 = if (total_sectors_32 != 0) total_sectors_32 else total_sectors_16;
    const fat_start = lba_start + reserved_sectors;
    const data_start = fat_start + @as(u32, num_fats) * fat_size_32;
    const data_sectors = total_sectors - @as(u32, reserved_sectors) - @as(u32, num_fats) * fat_size_32;

    return .{
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sectors = reserved_sectors,
        .num_fats = num_fats,
        .root_cluster = root_cluster,
        .total_sectors = total_sectors,
        .fat_size_sectors = fat_size_32,
        .fat_start = fat_start,
        .data_start = data_start,
        .sector_mask = sectors_per_cluster - 1,
        .total_data_clusters = data_sectors / @as(u32, sectors_per_cluster),
    };
}

// ─── Cluster / FAT arithmetic ──────────────────────────────────────────────

/// LBA of the first sector of data `cluster` (valid clusters start at 2).
pub fn clusterToLba(data_start: u32, sectors_per_cluster: u8, cluster: u32) u32 {
    return data_start + (cluster - 2) * @as(u32, sectors_per_cluster);
}

pub const FatLoc = struct { sector: u32, offset: u32 };

/// Sector + byte offset of the 32-bit FAT entry describing `cluster`.
pub fn fatEntryLocation(fat_start: u32, bytes_per_sector: u16, cluster: u32) FatLoc {
    const fat_offset = cluster * 4;
    return .{
        .sector = fat_start + fat_offset / @as(u32, bytes_per_sector),
        .offset = fat_offset % @as(u32, bytes_per_sector),
    };
}

/// Extract the 28-bit FAT32 entry value from a sector buffer at `offset`.
pub fn fatEntryValue(sector_buf: [*]const u8, offset: u32) u32 {
    const raw: u32 = @bitCast([4]u8{
        sector_buf[offset],
        sector_buf[offset + 1],
        sector_buf[offset + 2],
        sector_buf[offset + 3],
    });
    return raw & 0x0FFFFFFF;
}

// ─── Cluster classification (28-bit masked) ────────────────────────────────

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
