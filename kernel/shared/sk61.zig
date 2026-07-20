//! SK-61 — pure MBR/FAT32 parsing + geometry (`fs/fat32_util.zig`) on non-x86.
//!
//! The FAT32 driver's on-disk parsing (MBR partition table, BPB geometry,
//! cluster→LBA and FAT-entry addressing, cluster classification) was extracted
//! into fat32_util.zig, which has no block-driver / allocator / global-state
//! dependencies. This probe builds a synthetic MBR + BPB in memory and verifies
//! the extracted math on riscv64/aarch64 with exact expected values, proving the
//! parsing layer is portable and the x86 driver's delegation is behaviour-
//! preserving.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const fu = @import("../fs/fat32_util.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-61] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-61] fat32 parse/geometry non-x86: OK\n");
        return;
    }

    // ── Synthetic MBR: one bootable FAT32(LBA) partition at LBA 2048 ──────
    var mbr: [512]u8 = @splat(0);
    const p0 = 446;
    mbr[p0] = 0x80; // bootable
    mbr[p0 + 4] = 0x0C; // type FAT32 (LBA)
    // lba_start = 2048 = 0x00000800
    mbr[p0 + 8] = 0x00;
    mbr[p0 + 9] = 0x08;
    // sector_count = 131072 = 0x00020000
    mbr[p0 + 14] = 0x02;

    const part = fu.parsePartition(&mbr, 0) orelse {
        fail("partition 0 not parsed");
        return;
    };
    if (!part.bootable or part.type != 0x0C or part.lba_start != 2048 or part.sector_count != 131072) {
        fail("partition fields");
        return;
    }
    if (!fu.isFat32Type(part.type)) {
        fail("fat32 type predicate");
        return;
    }
    // Empty entry → null.
    if (fu.parsePartition(&mbr, 1) != null) {
        fail("empty partition not null");
        return;
    }

    // ── Synthetic FAT32 BPB, volume at lba_start = 2048 ──────────────────
    var bs: [512]u8 = @splat(0);
    bs[11] = 0x00;
    bs[12] = 0x02; // bytes_per_sector = 512
    bs[13] = 8; // sectors_per_cluster
    bs[14] = 32; // reserved_sectors = 32
    bs[16] = 2; // num_fats
    // total_sectors_32 = 131072 = 0x00020000
    bs[34] = 0x02;
    // fat_size_32 = 1009 = 0x000003F1
    bs[36] = 0xF1;
    bs[37] = 0x03;
    // root_cluster = 2
    bs[44] = 0x02;
    bs[66] = 0x29; // ext boot signature
    bs[82] = 'F';
    bs[83] = 'A';
    bs[84] = 'T';
    bs[85] = '3';
    bs[86] = '2';

    const bpb = fu.parseBpb(&bs, 2048) orelse {
        fail("bpb not parsed");
        return;
    };
    // Derived geometry: fat_start = 2048+32 = 2080; data_start = 2080+2*1009 =
    // 4098; sector_mask = 7; data_sectors = 131072-32-2018 = 129022;
    // total_data_clusters = 129022/8 = 16127.
    if (bpb.bytes_per_sector != 512 or bpb.sectors_per_cluster != 8 or
        bpb.reserved_sectors != 32 or bpb.num_fats != 2 or bpb.root_cluster != 2 or
        bpb.total_sectors != 131072 or bpb.fat_size_sectors != 1009 or
        bpb.fat_start != 2080 or bpb.data_start != 4098 or bpb.sector_mask != 7 or
        bpb.total_data_clusters != 16127)
    {
        fail("bpb geometry");
        return;
    }

    // Invalid BPB (all-zero → bytes_per_sector 0) → null.
    var zero: [512]u8 = @splat(0);
    if (fu.parseBpb(&zero, 0) != null) {
        fail("invalid bpb not null");
        return;
    }

    // ── Cluster / FAT arithmetic ─────────────────────────────────────────
    if (fu.clusterToLba(4098, 8, 2) != 4098 or fu.clusterToLba(4098, 8, 3) != 4106) {
        fail("clusterToLba");
        return;
    }
    const l1 = fu.fatEntryLocation(2080, 512, 100); // offset 400 → sector 2080
    if (l1.sector != 2080 or l1.offset != 400) {
        fail("fatEntryLocation same sector");
        return;
    }
    const l2 = fu.fatEntryLocation(2080, 512, 200); // offset 800 → sector 2081, off 288
    if (l2.sector != 2081 or l2.offset != 288) {
        fail("fatEntryLocation cross sector");
        return;
    }

    // FAT entry value extraction + classification.
    var fatbuf: [16]u8 = @splat(0);
    // offset 0: EOC marker 0x0FFFFFF8
    fatbuf[0] = 0xF8;
    fatbuf[1] = 0xFF;
    fatbuf[2] = 0xFF;
    fatbuf[3] = 0x0F;
    // offset 4: bad cluster 0x0FFFFFF7
    fatbuf[4] = 0xF7;
    fatbuf[5] = 0xFF;
    fatbuf[6] = 0xFF;
    fatbuf[7] = 0x0F;
    // offset 8: next=100 (0x64), with upper nibble noise that must be masked off
    fatbuf[8] = 0x64;
    fatbuf[11] = 0xF0; // top 4 bits ignored by 28-bit mask

    const eoc = fu.fatEntryValue(&fatbuf, 0);
    const bad = fu.fatEntryValue(&fatbuf, 4);
    const nxt = fu.fatEntryValue(&fatbuf, 8);
    if (eoc != 0x0FFFFFF8 or !fu.isEndOfChain(eoc)) {
        fail("eoc entry");
        return;
    }
    if (bad != 0x0FFFFFF7 or !fu.isBadCluster(bad)) {
        fail("bad entry");
        return;
    }
    if (nxt != 100 or fu.isEndOfChain(nxt) or fu.isFreeCluster(nxt)) {
        fail("next entry mask");
        return;
    }
    if (!fu.isFreeCluster(0) or fu.isFreeCluster(5)) {
        fail("free predicate");
        return;
    }
    if (!fu.isValidDataCluster(2) or !fu.isValidDataCluster(100) or
        fu.isValidDataCluster(1) or fu.isValidDataCluster(0x0FFFFFF8))
    {
        fail("valid data cluster predicate");
        return;
    }

    arch.serial.writeString("[SK-61] fat32 parse/geometry non-x86: OK\n");
}
