/// MBR partition table parser and FAT32 filesystem driver.
///
/// Handles:
///   - MBR partition table parsing (primary partitions only)
///   - FAT32 filesystem: BPB parsing, cluster chain traversal, file listing
///   - Falls back to raw FAT32 if no MBR partition table found

const serial = @import("../arch/x86_64/serial.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");

pub const SECTOR_SIZE: u32 = 512;
pub const MAX_PARTITIONS: u32 = 4;
pub const MAX_FILES: u32 = 64;
pub const MAX_FILENAME: u32 = 256;

pub const Partition = struct {
    bootable: bool,
    type: u8,
    lba_start: u32,
    sector_count: u32,
};

pub const FileInfo = struct {
    name: [MAX_FILENAME]u8,
    name_len: u32,
    size: u32,
    first_cluster: u32,
    is_dir: bool,
};

var partitions: [MAX_PARTITIONS]Partition = @splat(.{
    .bootable = false,
    .type = 0,
    .lba_start = 0,
    .sector_count = 0,
});
var partition_count: u32 = 0;

// FAT32 state
var fat32_active: bool = false;
var fat32_lba_start: u32 = 0;
var fat32_bytes_per_sector: u16 = 0;
var fat32_sectors_per_cluster: u8 = 0;
var fat32_reserved_sectors: u16 = 0;
var fat32_num_fats: u8 = 0;
var fat32_root_cluster: u32 = 0;
var fat32_fat_start: u32 = 0;
var fat32_data_start: u32 = 0;
var fat32_total_sectors: u32 = 0;
var fat32_sector_mask: u32 = 0;
var fat32_fat_size_sectors: u32 = 0;
var write_buf_phys: u64 = 0;
var write_buf_virt: u64 = 0;
var fat32_total_data_clusters: u32 = 0;

var files: [MAX_FILES]FileInfo = @splat(.{
    .name = @splat(0),
    .name_len = 0,
    .size = 0,
    .first_cluster = 0,
    .is_dir = false,
});
var file_count: u32 = 0;

// Temp sector buffer (allocated at init)
var sector_buf_phys: u64 = 0;
var sector_buf_virt: u64 = 0;

pub fn init() void {
    serial.writeString("[fs] Initializing filesystem layer...\n");

    // Allocate sector buffer
    sector_buf_phys = pmm.allocPage() orelse return;
    sector_buf_virt = hhdm.physToVirt(sector_buf_phys);

    write_buf_phys = pmm.allocPage() orelse return;
    write_buf_virt = hhdm.physToVirt(write_buf_phys);

    if (!virtio_blk.hasActiveDisk()) {
        serial.writeString("[fs] No block device available\n");
        return;
    }

    // Read MBR (sector 0)
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    const n = virtio_blk.readSectors(0, 1, buf);
    if (n <= 0) {
        serial.writeString("[fs] Failed to read MBR\n");
        return;
    }

    // Check for MBR signature
    if (buf[510] == 0x55 and buf[511] == 0xAA) {
        parseMBR(buf);
    } else {
        serial.writeString("[fs] No MBR signature, trying raw FAT32\n");
    }

    // Try to mount FAT32 — either from first partition or raw disk
    tryMountFAT32();
}

fn parseMBR(buf: [*]const u8) void {
    partition_count = 0;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const off = 446 + i * 16;
        const ptype = buf[off + 4];
        if (ptype == 0) continue;

        const lba_start: u32 = @bitCast([4]u8{ buf[off + 8], buf[off + 9], buf[off + 10], buf[off + 11] });
        const sector_count: u32 = @bitCast([4]u8{ buf[off + 12], buf[off + 13], buf[off + 14], buf[off + 15] });

        partitions[partition_count] = .{
            .bootable = buf[off] == 0x80,
            .type = ptype,
            .lba_start = lba_start,
            .sector_count = sector_count,
        };
        partition_count += 1;

        serial.writeString("[fs] Partition ");
        serial.writeByte('0' + @as(u8, @intCast(partition_count - 1)));
        serial.writeString(": type=0x");
        writeHexByte(ptype);
        serial.writeString(" lba=");
        writeDecimal32(lba_start);
        serial.writeString(" size=");
        writeDecimal32(sector_count);
        serial.writeString(" sectors\n");
    }

    if (partition_count == 0) {
        serial.writeString("[fs] No partitions found in MBR\n");
    }
}

fn tryMountFAT32() void {
    // Try first partition if available, else raw disk
    var lba: u32 = 0;
    if (partition_count > 0) {
        // Find FAT32 partition (type 0x0B or 0x0C)
        var found = false;
        for (0..partition_count) |i| {
            if (partitions[i].type == 0x0B or partitions[i].type == 0x0C) {
                lba = partitions[i].lba_start;
                found = true;
                break;
            }
        }
        if (!found) {
            // Try first partition anyway
            lba = partitions[0].lba_start;
        }
    }

    // Read BPB (BIOS Parameter Block)
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    const n = virtio_blk.readSectors(lba, 1, buf);
    if (n <= 0) {
        serial.writeString("[fs] Failed to read BPB\n");
        return;
    }

    // Check for FAT32 signature
    const bytes_per_sector: u16 = @bitCast([2]u8{ buf[11], buf[12] });
    const sectors_per_cluster: u8 = buf[13];
    const reserved_sectors: u16 = @bitCast([2]u8{ buf[14], buf[15] });
    const num_fats: u8 = buf[16];
    const total_sectors_16: u16 = @bitCast([2]u8{ buf[19], buf[20] });
    const total_sectors_32: u32 = @bitCast([4]u8{ buf[32], buf[33], buf[34], buf[35] });
    const fat_size_32: u32 = @bitCast([4]u8{ buf[36], buf[37], buf[38], buf[39] });
    const root_cluster: u32 = @bitCast([4]u8{ buf[44], buf[45], buf[46], buf[47] });
    const fs_type: [8]u8 = @bitCast([8]u8{ buf[82], buf[83], buf[84], buf[85], buf[86], buf[87], buf[88], buf[89] });

    // Validate FAT32
    if (bytes_per_sector != 512 or sectors_per_cluster == 0 or reserved_sectors == 0) {
        serial.writeString("[fs] Not a valid FAT32 filesystem\n");
        return;
    }

    if (!(fs_type[0] == 'F' and fs_type[1] == 'A' and fs_type[2] == 'T' and fs_type[3] == '3' and fs_type[4] == '2')) {
        // Also accept no signature (some FAT32 images don't have it)
        if (buf[66] != 0x29 and buf[82] != 'F') {
            serial.writeString("[fs] Not FAT32 (bad FS type signature)\n");
            return;
        }
    }

    fat32_lba_start = lba;
    fat32_bytes_per_sector = bytes_per_sector;
    fat32_sectors_per_cluster = sectors_per_cluster;
    fat32_reserved_sectors = reserved_sectors;
    fat32_num_fats = num_fats;
    fat32_root_cluster = root_cluster;
    fat32_total_sectors = if (total_sectors_32 != 0) total_sectors_32 else total_sectors_16;
    fat32_fat_start = lba + reserved_sectors;
    fat32_data_start = fat32_fat_start + @as(u32, num_fats) * fat_size_32;
    fat32_sector_mask = sectors_per_cluster - 1;
    fat32_fat_size_sectors = fat_size_32;
    const data_sectors = fat32_total_sectors - @as(u32, reserved_sectors) - @as(u32, num_fats) * fat_size_32;
    fat32_total_data_clusters = data_sectors / @as(u32, sectors_per_cluster);
    fat32_active = true;

    serial.writeString("[fs] FAT32 mounted: ");
    writeDecimal32(fat32_total_sectors);
    serial.writeString(" sectors, cluster=");
    writeDecimal32(@as(u32, sectors_per_cluster));
    serial.writeString(" sectors, root_cluster=");
    writeDecimal32(root_cluster);
    serial.writeString("\n");

    // List root directory
    listRootDir();
}

fn clusterToLBA(cluster: u32) u32 {
    return fat32_data_start + (cluster - 2) * @as(u32, fat32_sectors_per_cluster);
}

fn getFATEntry(cluster: u32) u32 {
    const fat_offset = cluster * 4;
    const sector = fat32_fat_start + fat_offset / @as(u32, fat32_bytes_per_sector);
    const offset = fat_offset % @as(u32, fat32_bytes_per_sector);

    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    _ = virtio_blk.readSectors(sector, 1, buf);
    const result: u32 = @bitCast([4]u8{ buf[offset], buf[offset + 1], buf[offset + 2], buf[offset + 3] });
    return result & 0x0FFFFFFF;
}

fn listRootDir() void {
    if (!fat32_active) return;

    file_count = 0;
    var cluster: u32 = fat32_root_cluster;

    while (cluster >= 2 and cluster < 0x0FFFFFF8) {
        const lba = clusterToLBA(cluster);

        // Read cluster sectors into buffer
        const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
        const n = virtio_blk.readSectors(lba, 1, buf);
        if (n <= 0) break;

        // Parse directory entries (32 bytes each, 16 per sector)
        var entry_idx: u32 = 0;
        while (entry_idx < 16 and file_count < MAX_FILES) : (entry_idx += 1) {
            const entry_off = entry_idx * 32;
            const first_byte = buf[entry_off];

            if (first_byte == 0x00) break; // End of directory
            if (first_byte == 0xE5) continue; // Deleted entry
            if (buf[entry_off + 11] == 0x0F) continue; // LFN entry

            const attr = buf[entry_off + 11];
            if (attr == 0x08) continue; // Volume label

            const is_dir = (attr & 0x10) != 0;

            // Extract 8.3 name
            var fi = FileInfo{
                .name = @splat(0),
                .name_len = 0,
                .size = @bitCast([4]u8{ buf[entry_off + 28], buf[entry_off + 29], buf[entry_off + 30], buf[entry_off + 31] }),
                .first_cluster = @as(u32, @as(u16, @bitCast([2]u8{ buf[entry_off + 26], buf[entry_off + 27] }))) |
                    (@as(u32, @as(u16, @bitCast([2]u8{ buf[entry_off + 20], buf[entry_off + 21] }))) << 16),
                .is_dir = is_dir,
            };

            // Convert 8.3 name to readable format
            var ni: u32 = 0;
            for (0..8) |j| {
                const c = buf[entry_off + j];
                if (c == 0x20) break;
                fi.name[ni] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                ni += 1;
            }
            if (buf[entry_off + 8] != 0x20) {
                fi.name[ni] = '.';
                ni += 1;
                for (8..11) |j| {
                    const c = buf[entry_off + j];
                    if (c == 0x20) break;
                    fi.name[ni] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                    ni += 1;
                }
            }
            fi.name_len = ni;

            if (ni > 0) {
                files[file_count] = fi;
                file_count += 1;

                serial.writeString("[fs]   ");
                serial.writeString(fi.name[0..ni]);
                if (is_dir) serial.writeString("/");
                serial.writeString(" size=");
                writeDecimal32(fi.size);
                serial.writeString(" cluster=");
                writeDecimal32(fi.first_cluster);
                serial.writeString("\n");
            }
        }

        cluster = getFATEntry(cluster);
    }
    serial.writeString("[fs] ");
    writeDecimal32(file_count);
    serial.writeString(" files in root directory\n");
}

/// Open a file by name from the FAT32 filesystem.
/// Returns index into files array, or -1 on error.
pub fn openFile(name: []const u8) i64 {
    if (!fat32_active) return -1;
    for (0..file_count) |i| {
        const fi = files[i];
        if (fi.name_len == name.len) {
            var match = true;
            for (0..name.len) |j| {
                if (fi.name[j] != name[j]) {
                    match = false;
                    break;
                }
            }
            if (match and !fi.is_dir) return @intCast(i);
        }
    }
    return -1;
}

/// Read from an open file. Returns bytes read or -1 on error.
pub fn readFile(file_idx: u32, offset: u32, buf: [*]u8, count: u32) i64 {
    if (!fat32_active or file_idx >= file_count) return -1;
    const fi = files[file_idx];

    if (offset >= fi.size) return 0;
    const remaining = fi.size - offset;
    const to_read = if (count > remaining) remaining else count;
    if (to_read == 0) return 0;

    // Walk cluster chain to find the right cluster
    const cluster_size = @as(u32, fat32_sectors_per_cluster) * SECTOR_SIZE;
    const start_cluster_idx = offset / cluster_size;
    const offset_in_cluster = offset % cluster_size;

    var cluster: u32 = fi.first_cluster;
    var ci: u32 = 0;
    while (ci < start_cluster_idx and cluster >= 2 and cluster < 0x0FFFFFF8) {
        cluster = getFATEntry(cluster);
        ci += 1;
    }
    if (cluster < 2 or cluster >= 0x0FFFFFF8) return -1;

    // Read data from cluster chain
    var total_read: u32 = 0;
    var current_offset_in_cluster: u32 = offset_in_cluster;

    while (total_read < to_read and cluster >= 2 and cluster < 0x0FFFFFF8) {
        const lba = clusterToLBA(cluster);
        const sector_buf: [*]u8 = @ptrFromInt(sector_buf_virt);

        // Read entire cluster
        var s: u32 = 0;
        while (s < fat32_sectors_per_cluster) : (s += 1) {
            _ = virtio_blk.readSectors(lba + s, 1, sector_buf);
        }

        // Copy from cluster to output buffer
        const avail = cluster_size - current_offset_in_cluster;
        const chunk = if (total_read + avail > to_read) to_read - total_read else avail;
        @memcpy(buf[total_read .. total_read + chunk], sector_buf[current_offset_in_cluster .. current_offset_in_cluster + chunk]);
        total_read += chunk;
        current_offset_in_cluster = 0;

        cluster = getFATEntry(cluster);
    }

    return @intCast(total_read);
}

pub fn isActive() bool {
    return fat32_active;
}

pub fn getFileSize(idx: u32) u64 {
    if (idx >= file_count) return 0;
    return @intCast(files[idx].size);
}

pub fn getFileCount() u32 {
    return file_count;
}

pub fn getFileName(idx: u32) ?[]const u8 {
    if (idx >= file_count) return null;
    const len = files[idx].name_len;
    if (len == 0) return null;
    return files[idx].name[0..len];
}

pub fn setFileSize(idx: u32, size: u32) void {
    if (idx >= file_count) return;
    files[idx].size = size;
}

/// Wrapper around virtio_blk.writeSectors that disables interrupts during
/// the write. Without CLI/STI, writeSectors called from syscall context
/// prevents sysretq from returning to user space — the virtio-blk write
/// completion triggers an interrupt that corrupts the syscall return path.
fn safeWriteSectors(lba: u64, count: u32, buf: [*]const u8) i64 {
    asm volatile ("cli" ::: .{ .memory = true });
    const ret = virtio_blk.writeSectors(lba, count, buf);
    asm volatile ("sti" ::: .{ .memory = true });
    return ret;
}

fn setFATEntry(cluster: u32, value: u32) void {
    const fat_offset = cluster * 4;
    const sector = fat32_fat_start + fat_offset / @as(u32, fat32_bytes_per_sector);
    const offset = fat_offset % @as(u32, fat32_bytes_per_sector);

    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    _ = virtio_blk.readSectors(sector, 1, buf);
    buf[offset] = @truncate(value);
    buf[offset + 1] = @truncate(value >> 8);
    buf[offset + 2] = @truncate(value >> 16);
    buf[offset + 3] = (buf[offset + 3] & 0xF0) | @as(u8, @truncate(value >> 24));
    _ = safeWriteSectors(sector, 1, buf);
}

fn allocCluster() ?u32 {
    const entries_per_sector = @as(u32, fat32_bytes_per_sector) / 4;
    const total_fat_entries = fat32_fat_size_sectors * entries_per_sector;
    const max_cluster = if (fat32_total_data_clusters + 2 < total_fat_entries) fat32_total_data_clusters + 2 else total_fat_entries;

    var cluster: u32 = 2;
    while (cluster < max_cluster) : (cluster += 1) {
        const entry = getFATEntry(cluster);
        if (entry == 0) {
            setFATEntry(cluster, 0x0FFFFFFF);
            return cluster;
        }
    }
    return null;
}

fn zeroCluster(cluster: u32) void {
    const lba = clusterToLBA(cluster);
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    @memset(buf[0..SECTOR_SIZE], 0);
    var s: u32 = 0;
    while (s < fat32_sectors_per_cluster) : (s += 1) {
        _ = safeWriteSectors(lba + s, 1, buf);
    }
}

pub fn createFile(name: []const u8) i64 {
    if (!fat32_active) return -1;
    if (file_count >= MAX_FILES) return -1;
    if (name.len == 0 or name.len > 12) return -1;

    for (0..file_count) |i| {
        if (files[i].name_len == name.len) {
            var match = true;
            for (0..name.len) |j| {
                if (files[i].name[j] != name[j]) {
                    match = false;
                    break;
                }
            }
            if (match) return @intCast(i);
        }
    }

    const new_cluster = allocCluster() orelse return -1;
    zeroCluster(new_cluster);

    var basename: [8]u8 = @splat(0x20);
    var ext: [3]u8 = @splat(0x20);
    var dot_pos: usize = name.len;
    for (0..name.len) |j| {
        if (name[j] == '.') {
            dot_pos = j;
            break;
        }
    }
    for (0..if (dot_pos < 8) dot_pos else @as(usize, 8)) |j| {
        const c = name[j];
        basename[j] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    if (dot_pos < name.len) {
        const ext_start = dot_pos + 1;
        for (0..3) |j| {
            if (ext_start + j < name.len) {
                const c = name[ext_start + j];
                ext[j] = if (c >= 'a' and c <= 'z') c - 32 else c;
            }
        }
    }

    const root_lba = clusterToLBA(fat32_root_cluster);
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    _ = virtio_blk.readSectors(root_lba, 1, buf);

    var free_entry: u32 = 16;
    for (0..16) |i| {
        const off: u32 = @intCast(i * 32);
        if (buf[off] == 0x00 or buf[off] == 0xE5) {
            free_entry = @intCast(i);
            break;
        }
    }
    if (free_entry >= 16) return -1;

    const eoff = free_entry * 32;
    for (0..8) |j| buf[eoff + j] = basename[j];
    for (0..3) |j| buf[eoff + 8 + j] = ext[j];
    buf[eoff + 11] = 0x20;
    buf[eoff + 12] = 0;
    buf[eoff + 13] = 0;
    const create_time: u16 = 0;
    const create_date: u16 = 0;
    buf[eoff + 14] = @truncate(create_time);
    buf[eoff + 15] = @truncate(create_time >> 8);
    buf[eoff + 16] = @truncate(create_date);
    buf[eoff + 17] = @truncate(create_date >> 8);
    buf[eoff + 18] = @truncate(create_date);
    buf[eoff + 19] = @truncate(create_date >> 8);
    buf[eoff + 20] = @truncate(new_cluster >> 16);
    buf[eoff + 21] = @truncate(new_cluster >> 24);
    buf[eoff + 22] = @truncate(create_time);
    buf[eoff + 23] = @truncate(create_time >> 8);
    buf[eoff + 24] = @truncate(create_date);
    buf[eoff + 25] = @truncate(create_date >> 8);
    buf[eoff + 26] = @truncate(new_cluster);
    buf[eoff + 27] = @truncate(new_cluster >> 8);
    buf[eoff + 28] = 0;
    buf[eoff + 29] = 0;
    buf[eoff + 30] = 0;
    buf[eoff + 31] = 0;

    _ = safeWriteSectors(root_lba, 1, buf);

    var fi = FileInfo{
        .name = @splat(0),
        .name_len = @intCast(name.len),
        .size = 0,
        .first_cluster = new_cluster,
        .is_dir = false,
    };
    for (0..name.len) |j| fi.name[j] = name[j];
    const idx = file_count;
    files[idx] = fi;
    file_count += 1;
    return @intCast(idx);
}

pub fn writeFile(file_idx: u32, offset: u32, buf: [*]const u8, count: u32) i64 {
    if (!fat32_active or file_idx >= file_count) return -1;
    const fi = &files[file_idx];

    const cluster_size = @as(u32, fat32_sectors_per_cluster) * SECTOR_SIZE;

    // Allocate additional clusters if needed
    var needed_clusters: u32 = (offset + count + cluster_size - 1) / cluster_size;
    if (needed_clusters == 0) needed_clusters = 1;
    var current_clusters: u32 = 0;
    if (fi.size > 0) {
        current_clusters = (fi.size + cluster_size - 1) / cluster_size;
    }

    while (current_clusters < needed_clusters) : (current_clusters += 1) {
        var c: u32 = fi.first_cluster;
        if (c < 2 or c >= 0x0FFFFFF8) {
            const nc = allocCluster() orelse return -1;
            zeroCluster(nc);
            fi.first_cluster = nc;
            continue;
        }
        var last: u32 = c;
        while (c >= 2 and c < 0x0FFFFFF8) {
            last = c;
            c = getFATEntry(c);
        }
        const nc = allocCluster() orelse return -1;
        zeroCluster(nc);
        setFATEntry(last, nc);
    }

    // Write data: iterate over clusters, copying buf into the right sectors.
    // For each sector touched, read-modify-write (read the sector, overlay the
    // user data at the right offset, write it back).
    var bytes_written: u32 = 0;
    var cluster: u32 = fi.first_cluster;
    var file_offset: u32 = 0;
    const wbuf: [*]u8 = @ptrFromInt(write_buf_virt);

    while (bytes_written < count) {
        if (cluster < 2 or cluster >= 0x0FFFFFF8) break;

        const cluster_start_lba = clusterToLBA(cluster);
        const cluster_end_offset = file_offset + cluster_size;

        // Does this cluster overlap the [offset, offset+count) range?
        if (cluster_end_offset > offset and file_offset < offset + count) {
            // Compute the overlap within this cluster
            const overlap_start = if (offset > file_offset) offset - file_offset else 0;
            const overlap_end = if (offset + count < cluster_end_offset) offset + count - file_offset else cluster_size;

            var sec: u32 = 0;
            while (sec < fat32_sectors_per_cluster) : (sec += 1) {
                const sec_start = sec * SECTOR_SIZE;
                const sec_end = sec_start + SECTOR_SIZE;

                // Does this sector overlap?
                if (sec_end <= overlap_start or sec_start >= overlap_end) continue;

                const lba = cluster_start_lba + sec;

                // Determine the byte range to modify within this sector
                const mod_start = if (overlap_start > sec_start) overlap_start - sec_start else 0;
                const mod_end = if (overlap_end < sec_end) overlap_end - sec_start else SECTOR_SIZE;

                // If writing the full sector, no need to read first
                if (mod_start == 0 and mod_end == SECTOR_SIZE) {
                    @memcpy(wbuf[0..SECTOR_SIZE], buf[bytes_written .. bytes_written + SECTOR_SIZE]);
                } else {
                    // Read-modify-write
                    _ = virtio_blk.readSectors(lba, 1, wbuf);
                    @memcpy(wbuf[mod_start..mod_end], buf[bytes_written .. bytes_written + (mod_end - mod_start)]);
                }

                _ = safeWriteSectors(lba, 1, wbuf);
                bytes_written += @intCast(mod_end - mod_start);
            }
        }

        file_offset = cluster_end_offset;
        cluster = getFATEntry(cluster);
    }

    if (offset + count > fi.size) {
        fi.size = offset + count;
        updateDirEntry(file_idx);
    }

    return @intCast(bytes_written);
}

fn updateDirEntry(file_idx: u32) void {
    if (file_idx >= file_count) return;
    const fi = files[file_idx];

    const root_lba = clusterToLBA(fat32_root_cluster);
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    _ = virtio_blk.readSectors(root_lba, 1, buf);

    for (0..16) |i| {
        const off: u32 = @intCast(i * 32);
        if (buf[off] == 0x00) break;
        if (buf[off] == 0xE5) continue;
        if (buf[off + 11] == 0x0F) continue;
        if (buf[off + 11] == 0x08) continue;

        const entry_cluster = @as(u32, @as(u16, @bitCast([2]u8{ buf[off + 26], buf[off + 27] }))) |
            (@as(u32, @as(u16, @bitCast([2]u8{ buf[off + 20], buf[off + 21] }))) << 16);

        if (entry_cluster == fi.first_cluster) {
            buf[off + 28] = @truncate(fi.size);
            buf[off + 29] = @truncate(fi.size >> 8);
            buf[off + 30] = @truncate(fi.size >> 16);
            buf[off + 31] = @truncate(fi.size >> 24);
            _ = safeWriteSectors(root_lba, 1, buf);
            return;
        }
    }
}

fn writeHexByte(v: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[(v >> 4) & 0xF];
    buf[1] = hex[v & 0xF];
    serial.writeString(&buf);
}

fn writeDecimal32(v: u32) void {
    if (v == 0) {
        serial.writeString("0");
        return;
    }
    var buf: [10]u8 = undefined;
    var val = v;
    var i: usize = 0;
    while (val > 0) : (val /= 10) {
        buf[i] = @intCast(val % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    serial.writeString(buf[0..i]);
}

pub fn deleteFile(file_idx: u32) bool {
    if (!fat32_active or file_idx >= file_count) return false;
    const fi = files[file_idx];

    // Mark directory entry as deleted (0xE5)
    const root_lba = clusterToLBA(fat32_root_cluster);
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    _ = virtio_blk.readSectors(root_lba, 1, buf);

    for (0..16) |i| {
        const off: u32 = @intCast(i * 32);
        if (buf[off] == 0x00) break;
        if (buf[off] == 0xE5) continue;
        if (buf[off + 11] == 0x0F) continue;
        if (buf[off + 11] == 0x08) continue;

        const entry_cluster = @as(u32, @as(u16, @bitCast([2]u8{ buf[off + 26], buf[off + 27] }))) |
            (@as(u32, @as(u16, @bitCast([2]u8{ buf[off + 20], buf[off + 21] }))) << 16);

        if (entry_cluster == fi.first_cluster) {
            buf[off] = 0xE5;
            _ = safeWriteSectors(root_lba, 1, buf);
            break;
        }
    }

    // Free the cluster chain in FAT
    var cluster: u32 = fi.first_cluster;
    var safety: u32 = 0;
    while (cluster >= 2 and cluster < 0x0FFFFFF8 and safety < 65536) : (safety += 1) {
        const fat_offset = cluster * 4;
        const sector = fat32_fat_start + fat_offset / @as(u32, fat32_bytes_per_sector);
        const offset = fat_offset % @as(u32, fat32_bytes_per_sector);

        const fbuf: [*]u8 = @ptrFromInt(sector_buf_virt);
        _ = virtio_blk.readSectors(sector, 1, fbuf);
        const next_cluster_0 = fbuf[offset];
        const next_cluster_1 = fbuf[offset + 1];
        const next_cluster_2 = fbuf[offset + 2];
        const next_cluster_3 = fbuf[offset + 3] & 0x0F;
        const next_cluster: u32 = @as(u32, next_cluster_0) | (@as(u32, next_cluster_1) << 8) | (@as(u32, next_cluster_2) << 16) | (@as(u32, next_cluster_3) << 24);

        // Mark cluster as free (0)
        fbuf[offset] = 0;
        fbuf[offset + 1] = 0;
        fbuf[offset + 2] = 0;
        fbuf[offset + 3] = fbuf[offset + 3] & 0xF0;
        _ = safeWriteSectors(sector, 1, fbuf);

        cluster = next_cluster;
    }

    // Remove from in-memory file array
    for (file_idx..file_count - 1) |i| {
        files[i] = files[i + 1];
    }
    file_count -= 1;

    return true;
}
