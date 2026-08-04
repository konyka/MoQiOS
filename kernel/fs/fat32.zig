/// MBR partition table parser and FAT32 filesystem driver.
///
/// Handles:
///   - MBR partition table parsing (primary partitions only)
///   - FAT32 filesystem: BPB parsing, cluster chain traversal, file listing
///   - Falls back to raw FAT32 if no MBR partition table found
const serial = @import("../arch/arch.zig").serial;
const virtio_blk = @import("../drivers/virtio_blk.zig");
const block_dev = @import("../drivers/block_dev.zig");
const trim_ranges = @import("../lib/trim_ranges.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const fmt = @import("../lib/fmt.zig");
const fat_util = @import("fat32_util.zig");
const dcache = @import("dcache.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

pub const SECTOR_SIZE: u32 = 512;
pub const MAX_PARTITIONS: u32 = 4;
pub const MAX_FILES: u32 = 64;
pub const MAX_FILENAME: u32 = 256;

pub const Partition = fat_util.Partition;

pub const FileInfo = struct {
    name: [MAX_FILENAME]u8,
    name_len: u32,
    size: u32,
    first_cluster: u32,
    last_cluster: u32, // v53.36: cached last cluster for O(n) append (P3 fix)
    last_walk_cluster: u32 = 0, // v53.38: cached cluster for readFile chain walk (P1 fix)
    last_walk_idx: u32 = 0, // v53.38: cluster index of last_walk_cluster
    is_dir: bool,
    // v53.51: deleteFile tombstones the slot instead of shifting files[], so
    // indices held by open fds and writeback buffers stay stable.
    active: bool = false,
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
// v53.36: Single-sector FAT cache — 128x I/O reduction for sequential reads (P2 fix)
// v53.37: DMA-safe buffer via PMM (Critical fix — BSS not in HHDM, virtToPhys invalid)
var fat_cache_sector: u32 = 0xFFFFFFFF;
var fat_cache_phys: u64 = 0;
var fat_cache_buf_virt: u64 = 0;
var last_free_cluster: u32 = 2; // v53.38: allocCluster scan cursor (O(N) vs O(N×M))

// G5 TRIM: extents of freed clusters accumulate here and are coalesced into
// maximal contiguous sector ranges before issuing block_dev.discard. Static
// buffers (fs_lock serializes); flushed when full or at the end of a free
// loop. discard() is plain device I/O that never re-enters fat32, so the
// writeback flush rule (drop fs_lock around writeback calls) does not apply
// — it runs under fs_lock like the existing FAT/dir sector I/O.
var discard_in: [64]trim_ranges.Extent = undefined;
var discard_out: [64]trim_ranges.Extent = undefined;
var discard_count: usize = 0;

fn noteFreedCluster(cluster: u32) void {
    if (discard_count == discard_in.len) flushDiscard();
    discard_in[discard_count] = .{
        .start = clusterToLBA(cluster),
        .count = fat32_sectors_per_cluster,
    };
    discard_count += 1;
}

fn flushDiscard() void {
    const n = trim_ranges.coalesce(discard_in[0..discard_count], &discard_out);
    discard_count = 0;
    for (discard_out[0..n]) |r| {
        _ = block_dev.discard(r.start, r.count);
    }
}

var files: [MAX_FILES]FileInfo = @splat(.{
    .name = @splat(0),
    .name_len = 0,
    .size = 0,
    .first_cluster = 0,
    .last_cluster = 0,
    .is_dir = false,
});
var file_count: u32 = 0;

// Temp sector buffer (allocated at init)
var sector_buf_phys: u64 = 0;
var sector_buf_virt: u64 = 0;

// Coarse FS-wide lock (SMP fix): serializes all public entry points to
// protect global state (files[], fat_cache_*, sector_buf_virt,
// write_buf_virt, last_walk_cluster, ...). Two CPUs writing different files
// would otherwise interleave the shared bounce buffers and corrupt data.
// Lock ordering: this lock is a leaf — it is only acquired inside fat32
// public entry points, never held while calling into vfs/writeback. The
// writeback flush path (vfs → writeback → fat32WriteFlush → writeFile)
// re-enters through the public API with no fat32 lock held by the caller
// (writeback releases wb_lock before invoking the flush callback), so
// callers of writeback flush must NOT hold this lock. Taken before the
// virtio_blk io_lock; never the other way around.
var fs_lock: IrqSpinlock = .{};

pub fn init() void {
    serial.writeString("[fs] Initializing filesystem layer...\n");

    // Allocate sector buffer
    sector_buf_phys = pmm.allocPage() orelse return;
    sector_buf_virt = hhdm.physToVirt(sector_buf_phys);

    write_buf_phys = pmm.allocPage() orelse return;
    write_buf_virt = hhdm.physToVirt(write_buf_phys);

    // v53.37: FAT cache buffer — PMM-allocated for DMA safety (Critical fix)
    fat_cache_phys = pmm.allocPage() orelse return;
    fat_cache_buf_virt = hhdm.physToVirt(fat_cache_phys);

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
        const part = fat_util.parsePartition(buf, i) orelse continue;

        partitions[partition_count] = part;
        partition_count += 1;

        serial.writeString("[fs] Partition ");
        serial.writeByte('0' + @as(u8, @intCast(partition_count - 1)));
        serial.writeString(": type=0x");
        fmt.writeHex8(part.type);
        serial.writeString(" lba=");
        fmt.writeDecimal(part.lba_start);
        serial.writeString(" size=");
        fmt.writeDecimal(part.sector_count);
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
            if (fat_util.isFat32Type(partitions[i].type)) {
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

    // Parse + validate the FAT32 BPB (pure geometry math in fat32_util).
    const bpb = fat_util.parseBpb(buf, lba) orelse {
        serial.writeString("[fs] Not a valid FAT32 filesystem\n");
        return;
    };

    fat32_lba_start = lba;
    fat32_bytes_per_sector = bpb.bytes_per_sector;
    fat32_sectors_per_cluster = bpb.sectors_per_cluster;
    fat32_reserved_sectors = bpb.reserved_sectors;
    fat32_num_fats = bpb.num_fats;
    fat32_root_cluster = bpb.root_cluster;
    fat32_total_sectors = bpb.total_sectors;
    fat32_fat_start = bpb.fat_start;
    fat32_data_start = bpb.data_start;
    fat32_sector_mask = bpb.sector_mask;
    fat32_fat_size_sectors = bpb.fat_size_sectors;
    fat32_total_data_clusters = bpb.total_data_clusters;
    fat32_active = true;

    serial.writeString("[fs] FAT32 mounted: ");
    fmt.writeDecimal(fat32_total_sectors);
    serial.writeString(" sectors, cluster=");
    fmt.writeDecimal(@as(u32, bpb.sectors_per_cluster));
    serial.writeString(" sectors, root_cluster=");
    fmt.writeDecimal(bpb.root_cluster);
    serial.writeString("\n");

    // List root directory
    listRootDir();
}

fn clusterToLBA(cluster: u32) u32 {
    return fat_util.clusterToLba(fat32_data_start, fat32_sectors_per_cluster, cluster);
}

/// Read one FAT entry. Returns null on a disk read failure — the sector is
/// NOT marked cached in that case, so stale cache contents are never consumed
/// (previously the failure was ignored and the sector marked valid anyway).
fn getFATEntry(cluster: u32) ?u32 {
    const loc = fat_util.fatEntryLocation(fat32_fat_start, fat32_bytes_per_sector, cluster);

    // v53.36: Single-sector FAT cache (P2 fix — 128x I/O reduction)
    // v53.37: DMA-safe HHDM buffer (Critical fix — BSS globals not DMA-safe)
    const fbuf: [*]u8 = @ptrFromInt(fat_cache_buf_virt);
    if (loc.sector != fat_cache_sector) {
        if (virtio_blk.readSectors(loc.sector, 1, fbuf) <= 0) return null;
        fat_cache_sector = loc.sector;
    }
    return fat_util.fatEntryValue(fbuf, loc.offset);
}

fn listRootDir() void {
    if (!fat32_active) return;

    file_count = 0;
    var cluster: u32 = fat32_root_cluster;
    // SK-66: pending LFN slots in forward-scan order (last-marker first).
    var lfn_raw: [fat_util.MAX_LFN_SLOTS][32]u8 = undefined;
    var lfn_count: u32 = 0;

    root_scan: while (cluster >= 2 and cluster < 0x0FFFFFF8) {
        const base_lba = clusterToLBA(cluster);
        // SK-68: every sector in the cluster (not only the first).
        var sec: u32 = 0;
        while (sec < fat32_sectors_per_cluster) : (sec += 1) {
            const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
            const n = virtio_blk.readSectors(base_lba + sec, 1, buf);
            if (n <= 0) break :root_scan;

            var entry_idx: u32 = 0;
            while (entry_idx < 16 and file_count < MAX_FILES) : (entry_idx += 1) {
                const entry_off = entry_idx * 32;
                const first_byte = buf[entry_off];

                if (first_byte == 0x00) break :root_scan; // End of directory
                if (first_byte == 0xE5) {
                    lfn_count = 0; // orphaned LFN chain
                    continue;
                }
                const attr = buf[entry_off + 11];
                if (fat_util.isLfnAttr(attr)) {
                    if (lfn_count < fat_util.MAX_LFN_SLOTS) {
                        @memcpy(lfn_raw[lfn_count][0..32], (buf + entry_off)[0..32]);
                        lfn_count += 1;
                    } else {
                        lfn_count = 0;
                    }
                    continue;
                }
                if (fat_util.isVolumeLabelAttr(attr)) {
                    lfn_count = 0;
                    continue;
                }

                const entry = buf + entry_off;
                var fi = FileInfo{
                    .name = @splat(0),
                    .name_len = 0,
                    .size = fat_util.dirEntrySize(entry),
                    .first_cluster = fat_util.dirEntryFirstCluster(entry),
                    .last_cluster = 0,
                    .is_dir = fat_util.isDirectoryAttr(attr),
                    .active = true,
                };

                var short_name: [11]u8 = undefined;
                @memcpy(short_name[0..11], entry[0..11]);
                var ni: u32 = 0;
                if (lfn_count > 0) {
                    var ptrs: [fat_util.MAX_LFN_SLOTS][*]const u8 = undefined;
                    for (0..lfn_count) |i| ptrs[i] = &lfn_raw[i];
                    if (fat_util.assembleLfnUtf8(ptrs[0..lfn_count], &short_name, fi.name[0..])) |nlen| {
                        ni = nlen;
                    }
                    lfn_count = 0;
                }
                if (ni == 0) {
                    ni = fat_util.decode83Name(&short_name, fi.name[0..]);
                }
                fi.name_len = ni;

                if (ni > 0) {
                    files[file_count] = fi;
                    file_count += 1;

                    serial.writeString("[fs]   ");
                    serial.writeString(fi.name[0..ni]);
                    if (fi.is_dir) serial.writeString("/");
                    serial.writeString(" size=");
                    fmt.writeDecimal(fi.size);
                    serial.writeString(" cluster=");
                    fmt.writeDecimal(fi.first_cluster);
                    serial.writeString("\n");
                }
            }
        }

        cluster = getFATEntry(cluster) orelse break :root_scan;
    }
    serial.writeString("[fs] ");
    fmt.writeDecimal(file_count);
    serial.writeString(" files in root directory\n");
}

/// K1 dcache helper: full name compare against a files[] slot.
fn nameMatches(fi: *const FileInfo, name: []const u8) bool {
    if (fi.name_len != name.len) return false;
    for (name, 0..) |c, j| {
        if (fi.name[j] != c) return false;
    }
    return true;
}

/// Open a file by name from the FAT32 filesystem.
/// Returns index into files array, or -1 on error.
pub fn openFile(name: []const u8) i64 {
    if (!fat32_active) return -1;
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);

    // K1 dcache: (fat32, root_cluster, name) → files[] slot. A hit skips the
    // linear files[] scan; the slot is defensively revalidated so a stale or
    // conflicted entry degrades to the slow path instead of a wrong open.
    if (dcache.lookup(.fat32, fat32_root_cluster, name)) |idx| {
        if (idx < file_count and files[idx].active and !files[idx].is_dir and
            nameMatches(&files[idx], name))
        {
            return @intCast(idx);
        }
    }

    for (0..file_count) |i| {
        const fi = files[i];
        if (!fi.active) continue; // v53.51: skip tombstoned slots
        if (nameMatches(&fi, name) and !fi.is_dir) {
            dcache.fill(.fat32, fat32_root_cluster, name, @intCast(i));
            return @intCast(i);
        }
    }
    return -1;
}

/// Read from an open file. Returns bytes read or -1 on error.
pub fn readFile(file_idx: u32, offset: u32, buf: [*]u8, count: u32) i64 {
    if (!fat32_active or file_idx >= file_count) return -1;
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    const fi = files[file_idx];
    if (!fi.active) return -1; // v53.51: tombstoned (deleted) slot

    if (offset >= fi.size) return 0;
    const remaining = fi.size - offset;
    const to_read = if (count > remaining) remaining else count;
    if (to_read == 0) return 0;

    const page_cache = @import("page_cache.zig");
    const inode_id: u64 = 0x2000_0000_0000_0000 + @as(u64, fi.first_cluster);

    // Walk cluster chain to find the right cluster
    const cluster_size = @as(u32, fat32_sectors_per_cluster) * SECTOR_SIZE;
    const start_cluster_idx = offset / cluster_size;
    const offset_in_cluster = offset % cluster_size;

    var cluster: u32 = fi.first_cluster;
    var ci: u32 = 0;
    // v53.38: Resume from cached walk position — O(N) vs O(N²) for sequential reads
    if (fi.last_walk_cluster >= 2 and fi.last_walk_cluster < 0x0FFFFFF8 and fi.last_walk_idx <= start_cluster_idx) {
        cluster = fi.last_walk_cluster;
        ci = fi.last_walk_idx;
    }
    while (ci < start_cluster_idx and cluster >= 2 and cluster < 0x0FFFFFF8) {
        cluster = getFATEntry(cluster) orelse return -1;
        ci += 1;
    }
    // v53.38: Update walk cache for sequential read optimization
    if (cluster >= 2 and cluster < 0x0FFFFFF8) {
        files[file_idx].last_walk_cluster = cluster;
        files[file_idx].last_walk_idx = ci;
    }
    if (cluster < 2 or cluster >= 0x0FFFFFF8) return -1;

    // Read data from cluster chain
    var total_read: u32 = 0;
    var current_offset_in_cluster: u32 = offset_in_cluster;

    while (total_read < to_read and cluster >= 2 and cluster < 0x0FFFFFF8) {
        const lba = clusterToLBA(cluster);
        // v53.36: Use cluster number directly as cache key (P1 fix — prevents
        // key collision when sectors_per_cluster < 8).
        const cluster_page_idx: u64 = @as(u64, cluster);
        var chunk: u32 = 0;

        // Try page cache for this cluster (copy-out under cache_lock — a raw
        // page pointer could be freed by a concurrent eviction before memcpy).
        const cache_want = blk: {
            const avail = cluster_size - current_offset_in_cluster;
            break :blk if (total_read + avail > to_read) to_read - total_read else avail;
        };
        if (page_cache.copyPage(inode_id, cluster_page_idx, current_offset_in_cluster, buf + total_read, cache_want)) {
            chunk = cache_want;
        } else {
            // Cache miss — read from disk
            if (fat32_sectors_per_cluster <= 8) {
                // v53.50: Use insertPageOwned to avoid cache_lock→pmm.lock nested lock.
                // Allocate page outside cache_lock, read directly into it, transfer ownership.
                const tmp_phys = pmm.allocPage();
                if (tmp_phys) |tp| {
                    const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(tp));
                    _ = virtio_blk.readSectors(lba, fat32_sectors_per_cluster, tmp);
                    const avail = cluster_size - current_offset_in_cluster;
                    chunk = if (total_read + avail > to_read) to_read - total_read else avail;
                    @memcpy(buf[total_read .. total_read + chunk], tmp[current_offset_in_cluster .. current_offset_in_cluster + chunk]);
                    if (page_cache.insertPageOwned(inode_id, cluster_page_idx, tp, cluster_size) == null) {
                        pmm.freePage(tp); // Cache full
                    }
                } else {
                    // OOM fallback: use global buffer without caching
                    const sector_buf: [*]u8 = @ptrFromInt(sector_buf_virt);
                    _ = virtio_blk.readSectors(lba, fat32_sectors_per_cluster, sector_buf);
                    const avail = cluster_size - current_offset_in_cluster;
                    chunk = if (total_read + avail > to_read) to_read - total_read else avail;
                    @memcpy(buf[total_read .. total_read + chunk], sector_buf[current_offset_in_cluster .. current_offset_in_cluster + chunk]);
                }
            } else {
                // Cluster > 4KB — read only needed sectors to avoid buffer overflow
                const sector_buf: [*]u8 = @ptrFromInt(sector_buf_virt);
                const sector_in_cluster = current_offset_in_cluster / SECTOR_SIZE;
                const offset_in_sector = current_offset_in_cluster % SECTOR_SIZE;
                const sectors_to_read = @min(fat32_sectors_per_cluster - sector_in_cluster, 8);
                _ = virtio_blk.readSectors(lba + sector_in_cluster, sectors_to_read, sector_buf);
                const buf_avail = sectors_to_read * SECTOR_SIZE - offset_in_sector;
                const avail = @min(cluster_size - current_offset_in_cluster, buf_avail);
                chunk = if (total_read + avail > to_read) to_read - total_read else avail;
                @memcpy(buf[total_read .. total_read + chunk], sector_buf[offset_in_sector .. offset_in_sector + chunk]);
            }
        }
        total_read += chunk;
        // v53.36: Advance offset within cluster; only advance to next cluster
        // when current cluster fully consumed (C1 fix — prevents data loss for
        // clusters > 4KB where only part of cluster is read per iteration).
        current_offset_in_cluster += chunk;
        if (current_offset_in_cluster >= cluster_size) {
            current_offset_in_cluster = 0;
            cluster = getFATEntry(cluster) orelse break;
        }
    }

    return @intCast(total_read);
}

pub fn getFirstCluster(file_idx: u32) u32 {
    if (file_idx >= MAX_FILES) return 0;
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    return files[file_idx].first_cluster;
}

pub fn isActive() bool {
    return fat32_active;
}

pub fn getFileSize(idx: u32) u64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (idx >= file_count) return 0;
    return @intCast(files[idx].size);
}

pub fn getFileCount() u32 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    return file_count;
}

pub fn getFileName(idx: u32) ?[]const u8 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (idx >= file_count) return null;
    const len = files[idx].name_len;
    if (len == 0) return null;
    return files[idx].name[0..len];
}

pub fn setFileSize(idx: u32, size: u32) void {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
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

/// Flush callback for writeback invalidation on deleteFile: route the staged
/// extent back through writeFile using the slot that staged it.
fn writebackFlush(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32) bool {
    return writeFile(file_idx, @intCast(byte_offset), data, len) == len;
}

/// Write one FAT entry. Returns false when the backing sector cannot be read
/// on a cache miss — mirroring getFATEntry, the stale cache contents must not
/// be modified and written back over an unread sector.
fn setFATEntry(cluster: u32, value: u32) bool {
    const fat_offset = cluster * 4;
    const sector = fat32_fat_start + fat_offset / @as(u32, fat32_bytes_per_sector);
    const offset = fat_offset % @as(u32, fat32_bytes_per_sector);

    // v53.37: Use FAT cache directly — avoid redundant sector read (P1 perf fix).
    // Previously read sector_buf + wrote + invalidated cache → 2N reads for N allocations.
    // Now: cache hit → modify in-place (0 reads); cache miss → read into cache (1 read).
    // v53.37: DMA-safe HHDM buffer (Critical fix — BSS globals not DMA-safe)
    const fbuf: [*]u8 = @ptrFromInt(fat_cache_buf_virt);
    if (sector != fat_cache_sector) {
        if (virtio_blk.readSectors(sector, 1, fbuf) <= 0) return false;
        fat_cache_sector = sector;
    }
    fbuf[offset] = @truncate(value);
    fbuf[offset + 1] = @truncate(value >> 8);
    fbuf[offset + 2] = @truncate(value >> 16);
    fbuf[offset + 3] = (fbuf[offset + 3] & 0xF0) | @as(u8, @truncate(value >> 24));
    _ = safeWriteSectors(sector, 1, fbuf);
    // Cache stays valid — no invalidation needed
    return true;
}

fn allocCluster() ?u32 {
    const entries_per_sector = @as(u32, fat32_bytes_per_sector) / 4;
    const total_fat_entries = fat32_fat_size_sectors * entries_per_sector;
    const max_cluster = if (fat32_total_data_clusters + 2 < total_fat_entries) fat32_total_data_clusters + 2 else total_fat_entries;

    // v53.38: Resume scan from cursor — O(N) amortized vs O(N×M) from cluster 2
    var cluster: u32 = last_free_cluster;
    var scanned: u32 = 0;
    while (scanned < max_cluster) : (scanned += 1) {
        if (cluster >= max_cluster) cluster = 2;
        const entry = getFATEntry(cluster) orelse return null; // fail closed on I/O error
        if (entry == 0) {
            if (!setFATEntry(cluster, 0x0FFFFFFF)) return null;
            last_free_cluster = cluster + 1;
            return cluster;
        }
        cluster += 1;
    }
    return null;
}

fn zeroCluster(cluster: u32) void {
    const lba = clusterToLBA(cluster);
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    // v53.37: Multi-sector write for spc<=8 (P2 perf fix, same pattern as P4 writeFile)
    if (fat32_sectors_per_cluster <= 8) {
        const cluster_size = @as(u32, fat32_sectors_per_cluster) * SECTOR_SIZE;
        @memset(buf[0..cluster_size], 0);
        _ = safeWriteSectors(lba, fat32_sectors_per_cluster, buf);
    } else {
        @memset(buf[0..SECTOR_SIZE], 0);
        var s: u32 = 0;
        while (s < fat32_sectors_per_cluster) : (s += 1) {
            _ = safeWriteSectors(lba + s, 1, buf);
        }
    }
}

/// SK-69: start of a free directory-entry run (may span sectors/clusters).
const DirPlace = struct {
    cluster: u32,
    sector_in_cluster: u32,
    entry_index: u32,
};

/// SK-68: walk every sector of the root cluster chain.
fn shortNameTakenInRoot(short_name: *const [11]u8) bool {
    var cluster: u32 = fat32_root_cluster;
    var safety: u32 = 0;
    while (cluster >= 2 and cluster < 0x0FFFFFF8 and safety < 65536) : (safety += 1) {
        const base_lba = clusterToLBA(cluster);
        var sec: u32 = 0;
        while (sec < fat32_sectors_per_cluster) : (sec += 1) {
            const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
            if (virtio_blk.readSectors(base_lba + sec, 1, buf) <= 0) return true; // fail closed
            if (fat_util.shortNameTaken(buf, short_name)) return true;
            if (fat_util.sectorHasDirEnd(buf)) return false;
        }
        cluster = getFATEntry(cluster) orelse return true; // fail closed on I/O error
    }
    return false;
}

/// SK-69: find `need` consecutive free slots, allowing the run to cross sector
/// and cluster boundaries (required for long LFN chains).
fn findFreeRunInRoot(need: u32) ?DirPlace {
    if (need == 0) return null;
    var cluster: u32 = fat32_root_cluster;
    var safety: u32 = 0;
    var in_run = false;
    var run_cluster: u32 = 0;
    var run_sec: u32 = 0;
    var run_entry: u32 = 0;
    var run_len: u32 = 0;

    while (cluster >= 2 and cluster < 0x0FFFFFF8 and safety < 65536) : (safety += 1) {
        const base_lba = clusterToLBA(cluster);
        var sec: u32 = 0;
        while (sec < fat32_sectors_per_cluster) : (sec += 1) {
            const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
            if (virtio_blk.readSectors(base_lba + sec, 1, buf) <= 0) return null;
            var ent: u32 = 0;
            while (ent < 16) : (ent += 1) {
                const first = buf[ent * 32];
                const free = first == 0x00 or first == 0xE5;
                if (free) {
                    if (!in_run) {
                        in_run = true;
                        run_cluster = cluster;
                        run_sec = sec;
                        run_entry = ent;
                        run_len = 0;
                    }
                    run_len += 1;
                    if (run_len >= need) {
                        return .{
                            .cluster = run_cluster,
                            .sector_in_cluster = run_sec,
                            .entry_index = run_entry,
                        };
                    }
                } else {
                    in_run = false;
                    run_len = 0;
                }
            }
        }
        cluster = getFATEntry(cluster) orelse return null;
    }
    return null;
}

/// Append a zeroed cluster to the root directory chain (when no free run exists).
fn growRootDir() bool {
    var cluster: u32 = fat32_root_cluster;
    var last: u32 = cluster;
    var safety: u32 = 0;
    while (cluster >= 2 and cluster < 0x0FFFFFF8 and safety < 65536) : (safety += 1) {
        last = cluster;
        cluster = getFATEntry(cluster) orelse return false;
    }
    const nc = allocCluster() orelse return false;
    zeroCluster(nc);
    if (!setFATEntry(last, nc)) return false;
    return true;
}

/// Advance one directory entry within the root chain.
fn advanceRootPos(cluster: *u32, sec: *u32, ent: *u32) bool {
    ent.* += 1;
    if (ent.* < 16) return true;
    ent.* = 0;
    sec.* += 1;
    if (sec.* < fat32_sectors_per_cluster) return true;
    sec.* = 0;
    const next = getFATEntry(cluster.*) orelse return false;
    if (next < 2 or next >= 0x0FFFFFF8) return false;
    cluster.* = next;
    return true;
}

/// Write consecutive 32-byte directory entries starting at `place`,
/// spanning sectors/clusters as needed (SK-69).
fn writeRootEntryRun(place: DirPlace, slots: []const [32]u8) bool {
    if (slots.len == 0) return true;
    var cluster = place.cluster;
    var sec = place.sector_in_cluster;
    var ent = place.entry_index;
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    var cur_lba: u32 = clusterToLBA(cluster) + sec;
    if (virtio_blk.readSectors(cur_lba, 1, buf) <= 0) return false;
    var dirty = false;

    var i: u32 = 0;
    while (i < slots.len) : (i += 1) {
        @memcpy((buf + ent * 32)[0..32], slots[i][0..32]);
        dirty = true;
        if (i + 1 == slots.len) break;
        const prev_cluster = cluster;
        const prev_sec = sec;
        if (!advanceRootPos(&cluster, &sec, &ent)) return false;
        if (cluster != prev_cluster or sec != prev_sec) {
            if (dirty) {
                if (safeWriteSectors(cur_lba, 1, buf) <= 0) return false;
                dirty = false;
            }
            cur_lba = clusterToLBA(cluster) + sec;
            if (virtio_blk.readSectors(cur_lba, 1, buf) <= 0) return false;
        }
    }
    if (dirty) {
        if (safeWriteSectors(cur_lba, 1, buf) <= 0) return false;
    }
    return true;
}

pub fn createFile(name: []const u8) i64 {
    if (!fat32_active) return -1;
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    // K1 dcache: createFile may reuse a tombstoned files[] slot under a
    // different name, so per-slot tracking is untrustworthy — flush all fat32
    // entries (they only ever cover the root directory). Unconditional, even
    // when this call creates nothing: a spurious drop costs only a re-scan.
    defer dcache.invalidateFs(.fat32);
    if (name.len == 0 or name.len >= MAX_FILENAME) return -1;

    // v53.51: deleteFile tombstones slots — reuse the first inactive one.
    var free_slot: ?u32 = null;
    for (0..file_count) |i| {
        if (!files[i].active) {
            if (free_slot == null) free_slot = @as(u32, @intCast(i));
            continue;
        }
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
    if (free_slot == null and file_count >= MAX_FILES) return -1;

    const new_cluster = allocCluster() orelse return -1;
    zeroCluster(new_cluster);

    // SK-67/68/69: short 8.3, or LFN chain (+ cross-sector placement).
    var short_name: [11]u8 = undefined;
    var lfn_slots: [fat_util.MAX_LFN_SLOTS][32]u8 = undefined;
    var lfn_count: u32 = 0;
    if (fat_util.fits83Name(name)) {
        fat_util.encode83Name(name, &short_name);
    } else {
        var suffix: u8 = 1;
        while (suffix <= 9) : (suffix += 1) {
            fat_util.make83Alias(name, suffix, &short_name);
            if (!shortNameTakenInRoot(&short_name)) break;
            if (suffix == 9) {
                _ = setFATEntry(new_cluster, 0);
                return -1;
            }
        }
        lfn_count = fat_util.buildLfnEntries(name, &short_name, lfn_slots[0..]) orelse {
            _ = setFATEntry(new_cluster, 0);
            return -1;
        };
    }

    const need = lfn_count + 1;
    var place = findFreeRunInRoot(need);
    if (place == null) {
        if (!growRootDir()) {
            _ = setFATEntry(new_cluster, 0);
            return -1;
        }
        place = findFreeRunInRoot(need);
    }
    const dest = place orelse {
        _ = setFATEntry(new_cluster, 0);
        return -1;
    };

    // Pack LFN slots + short entry into one contiguous write run.
    var write_slots: [fat_util.MAX_LFN_SLOTS + 1][32]u8 = undefined;
    for (0..lfn_count) |i| {
        write_slots[i] = lfn_slots[i];
    }
    var short_ent: [32]u8 = @splat(0);
    @memcpy(short_ent[0..11], short_name[0..11]);
    short_ent[11] = fat_util.ATTR_ARCHIVE;
    fat_util.setDirEntryFirstCluster(&short_ent, new_cluster);
    fat_util.setDirEntrySize(&short_ent, 0);
    write_slots[lfn_count] = short_ent;

    if (!writeRootEntryRun(dest, write_slots[0 .. need])) {
        _ = setFATEntry(new_cluster, 0);
        return -1;
    }

    var fi = FileInfo{
        .name = @splat(0),
        .name_len = @intCast(name.len),
        .size = 0,
        .first_cluster = new_cluster,
        .last_cluster = new_cluster,
        .is_dir = false,
        .active = true,
    };
    @memcpy(fi.name[0..name.len], name);
    const idx = free_slot orelse file_count;
    files[idx] = fi;
    if (idx == file_count) file_count += 1;
    return @intCast(idx);
}

pub fn writeFile(file_idx: u32, offset: u32, buf: [*]const u8, count: u32) i64 {
    if (!fat32_active or file_idx >= file_count) return -1;
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    const fi = &files[file_idx];
    if (!fi.active) return -1; // v53.51: tombstoned (deleted) slot

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
            fi.last_cluster = nc;
            continue;
        }
        // v53.36: Use cached last_cluster to avoid O(n²) chain traversal (P3 fix)
        var last: u32 = fi.last_cluster;
        if (last < 2 or last >= 0x0FFFFFF8) {
            last = c;
            while (c >= 2 and c < 0x0FFFFFF8) {
                last = c;
                c = getFATEntry(c) orelse return -1;
            }
        }
        const nc = allocCluster() orelse return -1;
        zeroCluster(nc);
        if (!setFATEntry(last, nc)) return -1;
        fi.last_cluster = nc;
    }

    // Write data: iterate over clusters, copying buf into the right sectors.
    // For each sector touched, read-modify-write (read the sector, overlay the
    // user data at the right offset, write it back).
    var bytes_written: u32 = 0;
    var cluster: u32 = fi.first_cluster;
    var file_offset: u32 = 0;
    var ci: u32 = 0;
    const wbuf: [*]u8 = @ptrFromInt(write_buf_virt);

    // v53.40: Resume from cached walk position — O(n) vs O(n²) for sequential writes
    const start_cluster_idx = offset / cluster_size;
    if (fi.last_walk_cluster >= 2 and fi.last_walk_cluster < 0x0FFFFFF8 and fi.last_walk_idx <= start_cluster_idx) {
        cluster = fi.last_walk_cluster;
        ci = fi.last_walk_idx;
        file_offset = ci * cluster_size;
    }
    // Fast-forward to the first overlapping cluster
    while (ci < start_cluster_idx and cluster >= 2 and cluster < 0x0FFFFFF8) {
        cluster = getFATEntry(cluster) orelse return -1;
        ci += 1;
        file_offset += cluster_size;
    }
    // Update walk cache
    if (cluster >= 2 and cluster < 0x0FFFFFF8) {
        files[file_idx].last_walk_cluster = cluster;
        files[file_idx].last_walk_idx = ci;
    }

    write_loop: while (bytes_written < count) {
        if (cluster < 2 or cluster >= 0x0FFFFFF8) break;

        const cluster_start_lba = clusterToLBA(cluster);
        const cluster_end_offset = file_offset + cluster_size;

        // Does this cluster overlap the [offset, offset+count) range?
        if (cluster_end_offset > offset and file_offset < offset + count) {
            // Compute the overlap within this cluster
            const overlap_start = if (offset > file_offset) offset - file_offset else 0;
            const overlap_end = if (offset + count < cluster_end_offset) offset + count - file_offset else cluster_size;

            // v53.36: Full cluster write — single multi-sector I/O (P4 fix, 87.5% I/O reduction)
            // Each arm stops on a failed write rather than counting bytes that
            // never reached the disk; the writeback cache uses the returned count
            // to decide whether the buffer can be dropped.
            if (overlap_start == 0 and overlap_end == cluster_size and fat32_sectors_per_cluster <= 8) {
                @memcpy(wbuf[0..cluster_size], buf[bytes_written .. bytes_written + cluster_size]);
                if (safeWriteSectors(cluster_start_lba, fat32_sectors_per_cluster, wbuf) <= 0) break;
                bytes_written += cluster_size;
            } else if (fat32_sectors_per_cluster <= 8) {
                // v53.40: Batch partial cluster write — read entire cluster, modify overlap, write back
                // Reduces N sector I/Os to 2 cluster I/Os (read + write)
                if (virtio_blk.readSectors(cluster_start_lba, fat32_sectors_per_cluster, wbuf) <= 0) break;
                @memcpy(wbuf[overlap_start..overlap_end], buf[bytes_written .. bytes_written + (overlap_end - overlap_start)]);
                if (safeWriteSectors(cluster_start_lba, fat32_sectors_per_cluster, wbuf) <= 0) break;
                bytes_written += overlap_end - overlap_start;
            } else {
                // Partial cluster write — per-sector read-modify-write (spc > 8)
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
                        if (virtio_blk.readSectors(lba, 1, wbuf) <= 0) break :write_loop;
                        @memcpy(wbuf[mod_start..mod_end], buf[bytes_written .. bytes_written + (mod_end - mod_start)]);
                    }

                    if (safeWriteSectors(lba, 1, wbuf) <= 0) break :write_loop;
                    bytes_written += @intCast(mod_end - mod_start);
                }
            }
        }

        file_offset = cluster_end_offset;
        cluster = getFATEntry(cluster) orelse break :write_loop;
        ci += 1;
        // v53.40: Update walk cache
        if (cluster >= 2 and cluster < 0x0FFFFFF8) {
            files[file_idx].last_walk_cluster = cluster;
            files[file_idx].last_walk_idx = ci;
        }
    }

    // Grow to what was actually written, not to what was requested: a loop that
    // stopped early would otherwise publish a size covering bytes never written.
    if (offset + bytes_written > fi.size) {
        fi.size = offset + bytes_written;
        updateDirEntry(file_idx);
    }

    // v53.51: Invalidate page_cache for this inode after the write loop. The
    // data reached the disk synchronously, so any cached cluster pages are
    // stale — readFile consults the cache, and without this a reopen+read
    // returned the pre-write cluster contents. Same precedent as
    // ext2.writeFile (one invalidateInode, no per-cluster bookkeeping).
    if (bytes_written > 0) {
        const page_cache = @import("page_cache.zig");
        page_cache.invalidateInode(0x2000_0000_0000_0000 + @as(u64, fi.first_cluster));
    }

    return @intCast(bytes_written);
}

/// H1: write one mmap-owned 4KiB cache page back for a MAP_SHARED mapping,
/// keyed by first cluster (the page-cache flush callback has no open slot).
///
/// Walks the existing cluster chain only — a mapping can never extend a file
/// (the fault path clamps at the mmap-time size), so clusters are never
/// allocated and bytes past the chain end are dropped. Never invalidates the
/// page cache (the flush loop owns those entries) and never touches the
/// directory entry/i_size.
pub fn writePageByInode(first_cluster: u32, page_idx: u64, data: *const [4096]u8) bool {
    if (!fat32_active) return false;
    const page_cache = @import("page_cache.zig");
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);

    const cluster_size: u64 = @as(u64, fat32_sectors_per_cluster) * SECTOR_SIZE;
    const base: u64 = page_idx * 4096;
    const end: u64 = base + 4096;
    const src: [*]const u8 = data;
    const wbuf: [*]u8 = @ptrFromInt(write_buf_virt);

    var cluster: u32 = first_cluster;
    var file_offset: u64 = 0;
    while (cluster >= 2 and cluster < 0x0FFFFFF8) {
        const cluster_end = file_offset + cluster_size;
        if (file_offset >= end) break;

        if (cluster_end > base and file_offset < end) {
            const overlap_start: u64 = if (base > file_offset) base - file_offset else 0;
            const overlap_end: u64 = @min(end - file_offset, cluster_size);
            const src_off: u64 = file_offset + overlap_start - base;

            if (overlap_start == 0 and overlap_end == cluster_size and fat32_sectors_per_cluster <= 8) {
                @memcpy(wbuf[0..cluster_size], src[src_off .. src_off + cluster_size]);
                if (safeWriteSectors(clusterToLBA(cluster), fat32_sectors_per_cluster, wbuf) <= 0) return false;
            } else if (fat32_sectors_per_cluster <= 8) {
                if (virtio_blk.readSectors(clusterToLBA(cluster), fat32_sectors_per_cluster, wbuf) <= 0) return false;
                @memcpy(wbuf[overlap_start..overlap_end], src[src_off .. src_off + (overlap_end - overlap_start)]);
                if (safeWriteSectors(clusterToLBA(cluster), fat32_sectors_per_cluster, wbuf) <= 0) return false;
            } else {
                // Partial cluster, large-spc: per-sector read-modify-write.
                var sec: u32 = 0;
                while (sec < fat32_sectors_per_cluster) : (sec += 1) {
                    const sec_start: u64 = @as(u64, sec) * SECTOR_SIZE;
                    const sec_end: u64 = sec_start + SECTOR_SIZE;
                    if (sec_end <= overlap_start or sec_start >= overlap_end) continue;
                    const mod_start = @max(overlap_start, sec_start);
                    const mod_end = @min(overlap_end, sec_end);
                    const lba = clusterToLBA(cluster) + sec;
                    if (mod_start == sec_start and mod_end == sec_end) {
                        @memcpy(wbuf[0..SECTOR_SIZE], src[src_off + sec_start - overlap_start ..][0..SECTOR_SIZE]);
                    } else {
                        if (virtio_blk.readSectors(lba, 1, wbuf) <= 0) return false;
                        @memcpy(wbuf[mod_start - sec_start .. mod_end - sec_start], src[src_off + mod_start - overlap_start .. src_off + mod_end - overlap_start]);
                    }
                    if (safeWriteSectors(lba, 1, wbuf) <= 0) return false;
                }
            }
            // Retire the read-path cache entry for this cluster (readFile
            // keys the cache by cluster number) — it now holds stale
            // pre-writeback bytes.
            page_cache.invalidatePage(0x2000_0000_0000_0000 + @as(u64, first_cluster), cluster);
        }

        file_offset = cluster_end;
        cluster = getFATEntry(cluster) orelse break;
    }
    return true;
}

fn updateDirEntry(file_idx: u32) void {
    if (file_idx >= file_count) return;
    const fi = files[file_idx];

    // Walk the full root cluster chain — createFile places entries anywhere
    // in the chain via findFreeRunInRoot, not only in the first sector.
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    var cluster: u32 = fat32_root_cluster;
    var safety: u32 = 0;
    scan: while (cluster >= 2 and cluster < 0x0FFFFFF8 and safety < 65536) : (safety += 1) {
        const base_lba = clusterToLBA(cluster);
        var sec: u32 = 0;
        while (sec < fat32_sectors_per_cluster) : (sec += 1) {
            const lba = base_lba + sec;
            if (virtio_blk.readSectors(lba, 1, buf) <= 0) break :scan;

            for (0..16) |i| {
                const off: u32 = @intCast(i * 32);
                if (buf[off] == 0x00) break :scan;
                if (buf[off] == 0xE5) continue;
                const attr = buf[off + 11];
                if (fat_util.isLfnAttr(attr) or fat_util.isVolumeLabelAttr(attr)) continue;

                const entry = buf + off;
                if (fat_util.dirEntryFirstCluster(entry) == fi.first_cluster) {
                    fat_util.setDirEntrySize(entry, fi.size);
                    _ = safeWriteSectors(lba, 1, buf);
                    return;
                }
            }
        }
        cluster = getFATEntry(cluster) orelse break :scan;
    }
}

/// Truncate a file to the given length. Frees the clusters beyond the new
/// size and updates the on-disk directory entry. The file keeps at least one
/// cluster (the same invariant createFile establishes), so the directory
/// entry's start-cluster field never needs rewriting.
pub fn truncateFile(file_idx: u32, new_size: u32) bool {
    if (!fat32_active or file_idx >= file_count) return false;
    var flags = fs_lock.acquire();
    if (!files[file_idx].active) {
        fs_lock.release(flags);
        return false;
    }
    const fi = files[file_idx];

    if (new_size >= fi.size) {
        // Growing: just update the size (clusters are allocated on write).
        if (new_size > fi.size) {
            files[file_idx].size = new_size;
            updateDirEntry(file_idx);
        }
        fs_lock.release(flags);
        return true;
    }

    // Flush+drop writeback extents staged for this inode BEFORE the cluster
    // chain is freed — a later flush would write into freed clusters. The
    // flush callback re-enters writeFile, which acquires fs_lock, so the lock
    // must be dropped around the writeback call (see deleteFile).
    const writeback = @import("writeback.zig");
    const wb_inode: u64 = 0x2000_0000_0000_0000 + @as(u64, fi.first_cluster);
    fs_lock.release(flags);
    _ = writeback.invalidateFile(wb_inode, .fat32, writebackFlush);
    flags = fs_lock.acquire();
    // The slot may have been reused while the lock was dropped.
    if (!files[file_idx].active or files[file_idx].first_cluster != fi.first_cluster) {
        fs_lock.release(flags);
        return false;
    }

    const cluster_size = @as(u32, fat32_sectors_per_cluster) * SECTOR_SIZE;
    var keep: u32 = (new_size + cluster_size - 1) / cluster_size;
    if (keep == 0) keep = 1; // createFile invariant: a file always owns >= 1 cluster

    var cluster: u32 = fi.first_cluster;
    var ci: u32 = 0;
    var safety: u32 = 0;
    var last_kept: u32 = 0;
    while (cluster >= 2 and cluster < 0x0FFFFFF8 and safety < 65536) : (safety += 1) {
        const next = getFATEntry(cluster) orelse break;
        if (ci < keep) {
            last_kept = cluster;
        } else {
            if (!setFATEntry(cluster, 0)) break;
            noteFreedCluster(cluster); // G5: batch a discard extent
        }
        cluster = next;
        ci += 1;
    }
    flushDiscard(); // G5: issue coalesced discards for the freed tail
    // Terminate the chain at the last kept cluster.
    if (last_kept >= 2) {
        if (!setFATEntry(last_kept, 0x0FFFFFFF)) {
            fs_lock.release(flags);
            return false;
        }
    }

    files[file_idx].size = new_size;
    if (last_kept >= 2) files[file_idx].last_cluster = last_kept;
    // The cached chain-walk position may point past the freed tail.
    files[file_idx].last_walk_cluster = 0;
    files[file_idx].last_walk_idx = 0;
    updateDirEntry(file_idx);

    const page_cache = @import("page_cache.zig");
    page_cache.invalidateInode(wb_inode);
    fs_lock.release(flags);
    return true;
}

pub fn deleteFile(file_idx: u32) bool {
    if (!fat32_active or file_idx >= file_count) return false;
    var flags = fs_lock.acquire();
    // K1 dcache: deleting tombstones a slot that createFile may later reuse
    // for a different name — flush all fat32 entries (root-only anyway) on
    // every path, including the bail-outs after the 0xE5 write below.
    defer dcache.invalidateFs(.fat32);
    const fi = files[file_idx];
    if (!fi.active) { // v53.51: already tombstoned
        fs_lock.release(flags);
        return false;
    }

    // Mark directory entry as deleted (0xE5)
    // Walk the full root cluster chain — createFile places entries anywhere
    // in the chain via findFreeRunInRoot, not only in the first sector.
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    var dir_cluster: u32 = fat32_root_cluster;
    var dir_safety: u32 = 0;
    scan: while (dir_cluster >= 2 and dir_cluster < 0x0FFFFFF8 and dir_safety < 65536) : (dir_safety += 1) {
        const base_lba = clusterToLBA(dir_cluster);
        var sec: u32 = 0;
        while (sec < fat32_sectors_per_cluster) : (sec += 1) {
            const lba = base_lba + sec;
            if (virtio_blk.readSectors(lba, 1, buf) <= 0) break :scan;

            for (0..16) |i| {
                const off: u32 = @intCast(i * 32);
                if (buf[off] == 0x00) break :scan;
                if (buf[off] == 0xE5) continue;
                const attr = buf[off + 11];
                if (fat_util.isLfnAttr(attr) or fat_util.isVolumeLabelAttr(attr)) continue;

                const entry = buf + off;
                if (fat_util.dirEntryFirstCluster(entry) == fi.first_cluster) {
                    buf[off] = 0xE5;
                    _ = safeWriteSectors(lba, 1, buf);
                    break :scan;
                }
            }
        }
        dir_cluster = getFATEntry(dir_cluster) orelse break :scan;
    }

    // v53.51: Flush+drop writeback extents staged for this inode BEFORE the
    // cluster chain is freed — a later flush would write into freed clusters.
    // The flush callback re-enters writeFile, which acquires fs_lock, so the
    // lock must be dropped around the writeback call (see fs_lock note).
    const writeback = @import("writeback.zig");
    const wb_inode: u64 = 0x2000_0000_0000_0000 + @as(u64, fi.first_cluster);
    fs_lock.release(flags);
    _ = writeback.invalidateFile(wb_inode, .fat32, writebackFlush);
    flags = fs_lock.acquire();
    // The slot may have been reused while the lock was dropped; bail out if
    // it no longer refers to the file being deleted.
    if (!files[file_idx].active or files[file_idx].first_cluster != fi.first_cluster) {
        fs_lock.release(flags);
        return false;
    }

    // Free the cluster chain in FAT
    // v53.38: Use getFATEntry/setFATEntry for FAT cache reuse (P3 fix — N reads → ceil(N/128))
    var cluster: u32 = fi.first_cluster;
    var safety: u32 = 0;
    while (cluster >= 2 and cluster < 0x0FFFFFF8 and safety < 65536) : (safety += 1) {
        const next_cluster = getFATEntry(cluster) orelse break;
        if (!setFATEntry(cluster, 0)) break;
        noteFreedCluster(cluster); // G5: batch a discard extent
        cluster = next_cluster;
    }
    flushDiscard(); // G5: issue coalesced discards for the freed chain
    // No cache invalidation needed — setFATEntry keeps cache consistent

    // v53.51: Tombstone the slot instead of shifting files[]. Shifting moved
    // every later entry down one index, so dirty writeback buffers and open
    // fds keyed by slot index silently pointed at the WRONG file. The slot is
    // reused by createFile once tombstoned.
    const page_cache = @import("page_cache.zig");
    page_cache.invalidateInode(wb_inode);
    files[file_idx] = .{
        .name = @splat(0),
        .name_len = 0,
        .size = 0,
        .first_cluster = 0,
        .last_cluster = 0,
        .is_dir = false,
        .active = false,
    };

    fs_lock.release(flags);
    return true;
}
