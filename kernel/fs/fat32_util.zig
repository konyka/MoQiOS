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
