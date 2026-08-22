/// ext2 filesystem driver (read-write).
///
/// Supports:
///   - Superblock parsing
///   - Block group descriptor table
///   - Inode read/write (direct blocks + single indirect)
///   - Directory entry parsing and creation
///   - File read/write via block indirection
///   - File creation (allocInode + addDirEntry)
///   - Block allocation from bitmap
///
/// Designed for ext2 with 1024-byte blocks (revision 0 / "good old ext2").
const serial = @import("../arch/arch.zig").serial;
const virtio_blk = @import("../drivers/virtio_blk.zig");
const block_dev = @import("../drivers/block_dev.zig");
const trim_ranges = @import("../lib/trim_ranges.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const eu = @import("ext2_util.zig");
const dcache = @import("dcache.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const SECTOR_SIZE: u32 = 512;
const MAX_OPEN_FILES: u32 = 16;
const MAX_FILENAME: u32 = 256;

// On-disk structures + pure geometry live in ext2_util (SK-63).
const Ext2Superblock = eu.Ext2Superblock;
const Ext2GroupDesc = eu.Ext2GroupDesc;
const Ext2Inode = eu.Ext2Inode;
const Ext2DirEntry = eu.Ext2DirEntry;
const EXT2_INODE_DIRECT = eu.EXT2_INODE_DIRECT;

// ─── Driver state ─────────────────────────────────────────────────────────

var active: bool = false;

// Static buffer for long symlink targets (avoid returning slice to stack/temp buffer)
var symlink_buf: [256]u8 = undefined;

var sb: Ext2Superblock = undefined;
var block_size: u32 = 0;
var groups_count: u32 = 0;
var inodes_per_group: u32 = 0;
var inode_size: u32 = 0;
var first_data_block: u32 = 0;

// v53.15: Batch depth counter — when > 0, freeBlock uses writeBlockBatch (cache-only,
// no sync write-through) and skips writeGroupDescs/writeSuperblock. Callers increment
// before batch block-freeing, then defer-flush cacheFlush+writeGroupDescs+writeSuperblock.
// Depth counter (not bool) supports nested batch contexts and is SMP-tolerant.
var batch_free_depth: u32 = 0;

// G5 TRIM: extents of freed data blocks accumulate here and are coalesced
// into maximal contiguous sector ranges before issuing block_dev.discard.
// Static buffers (fs_lock serializes). noteFreedBlock flushes when the
// buffer fills or outside a batch; batch callers flush in their defer.
// discard() is plain device I/O that never re-enters ext2, so the writeback
// flush rule (drop fs_lock around writeback calls) does not apply — it runs
// under fs_lock like the rest of the FS's sector I/O.
var discard_in: [64]trim_ranges.Extent = undefined;
var discard_out: [64]trim_ranges.Extent = undefined;
var discard_count: usize = 0;

fn noteFreedBlock(block_num: u32) void {
    const spb: u32 = block_size / SECTOR_SIZE; // sectors per block
    if (discard_count == discard_in.len) flushDiscard();
    discard_in[discard_count] = .{
        .start = DISK_LBA_OFFSET + @as(u64, block_num) * spb,
        .count = spb,
    };
    discard_count += 1;
    if (batch_free_depth == 0) flushDiscard();
}

fn flushDiscard() void {
    const n = trim_ranges.coalesce(discard_in[0..discard_count], &discard_out);
    discard_count = 0;
    for (discard_out[0..n]) |r| {
        _ = block_dev.discard(r.start, r.count);
    }
}

const DISK_LBA_OFFSET: u64 = 32768;

var group_descs_phys: u64 = 0;
var group_descs_virt: u64 = 0;

var sector_buf_phys: u64 = 0;
var sector_buf_virt: u64 = 0;

// v53.38: DMA-safe I/O buffer for readBlockUncached/writeBlockUncached (Critical fix)
// BSS globals (cache[].data, zero_block_buf, ensure_ind_buf) are at
// 0xFFFFFFFF80xxxxxx — outside HHDM, virtToPhys returns invalid physical address.
// All block I/O now goes through this PMM-allocated HHDM-mapped buffer.
var io_buf_phys: u64 = 0;
var io_buf_virt: u64 = 0;

pub const Ext2File = struct {
    inode_num: u32,
    inode: Ext2Inode,
    offset: u32,
    /// Cross-process references (fork/clone). closeFile frees only at 0,
    /// so a parent closing its fd cannot dangle the child's open-file index.
    ref_count: u32 = 1,
};

var open_files: [MAX_OPEN_FILES]Ext2File = undefined;
var open_count: u32 = 0;

// Coarse FS-wide lock (SMP fix): serializes all public entry points to
// protect global state (open_files[], block cache, io_buf_virt,
// batch_free_depth, sb/group_descs, ...). Two CPUs writing different files
// would otherwise interleave shared buffers and bitmap/counter updates and
// corrupt the filesystem.
// Lock ordering: this lock is a leaf — it is only acquired inside ext2
// public entry points, never held while calling into vfs/writeback. The
// writeback flush path (vfs → writeback → ext2WriteFlush → writeFile)
// re-enters through the public API with no ext2 lock held by the caller
// (writeback releases wb_lock before invoking the flush callback), so
// callers of writeback flush must NOT hold this lock. Taken before the
// virtio_blk io_lock; never the other way around.
// Functions called from inside other locked entry points have private
// *Unlocked variants (the lock is not recursive).
var fs_lock: IrqSpinlock = .{};

// ─── Open file path table (v52.0: for execveat dirfd resolution) ──────────
var open_file_paths: [MAX_OPEN_FILES][128]u8 = @splat(@splat(0));

// ─── Initialization ───────────────────────────────────────────────────────

pub fn init() void {
    sector_buf_phys = pmm.allocPage() orelse return;
    sector_buf_virt = hhdm.physToVirt(sector_buf_phys);

    // Read superblock (at byte offset 1024 = sector 2)
    const sb_sector: u64 = 1024 / SECTOR_SIZE;
    if (!readSectors(sb_sector, 2)) return;

    const sb_ptr: [*]const u8 = @ptrFromInt(sector_buf_virt);
    sb = eu.parseSuperblock(sb_ptr) orelse {
        serial.writeString("[ext2] bad magic\n");
        return;
    };

    const geo = eu.deriveGeometry(&sb) orelse {
        serial.writeString("[ext2] bad geometry\n");
        return;
    };

    block_size = geo.block_size;

    // v53.38: Allocate DMA-safe I/O buffer (must fit block_size, max 4KB per page)
    if (block_size > 4096) {
        serial.writeString("[ext2] block_size > 4KB unsupported with DMA-safe I/O\n");
        return;
    }
    io_buf_phys = pmm.allocPage() orelse return;
    io_buf_virt = hhdm.physToVirt(io_buf_phys);

    groups_count = geo.groups_count;
    inodes_per_group = geo.inodes_per_group;
    inode_size = geo.inode_size;
    first_data_block = geo.first_data_block;

    // Read block group descriptor table (at block first_data_block + 1)
    const bgdt_block = eu.bgdtBlock(first_data_block);
    const bgdt_size = groups_count * @sizeOf(Ext2GroupDesc);
    const bgdt_blocks = (bgdt_size + block_size - 1) / block_size;
    const bgdt_sectors = bgdt_blocks * (block_size / SECTOR_SIZE);
    const bgdt_sector = bgdt_block * (block_size / SECTOR_SIZE);

    // One page holds 128 descriptors, so a volume with more block groups than
    // that needs a larger table; reading it into a single page would run off
    // the end of the allocation.
    const bgdt_pages = (bgdt_size + 4095) / 4096;
    group_descs_phys = pmm.allocContiguous(bgdt_pages) orelse return;
    group_descs_virt = hhdm.physToVirt(group_descs_phys);

    const gd_buf: [*]u8 = @ptrFromInt(group_descs_virt);
    if (!readSectorRun(bgdt_sector, bgdt_sectors, gd_buf)) return;

    active = true;

    serial.writeString("[ext2] mounted\n");
}

pub fn isActive() bool {
    return active;
}

// ─── Sector I/O ───────────────────────────────────────────────────────────

fn readSectors(lba: u64, count: u32) bool {
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    const n = virtio_blk.readSectors(DISK_LBA_OFFSET + lba, count, buf);
    return n > 0;
}

/// Read `count` sectors, splitting into transfers the driver accepts (128 max).
fn readSectorRun(lba: u64, count: u32, dest: [*]u8) bool {
    var done: u32 = 0;
    while (done < count) {
        const chunk = @min(count - done, @as(u32, 128));
        if (!readSectorsToBuf(lba + done, chunk, dest + done * SECTOR_SIZE)) return false;
        done += chunk;
    }
    return true;
}

fn readSectorsToBuf(lba: u64, count: u32, dest: [*]u8) bool {
    const n = virtio_blk.readSectors(DISK_LBA_OFFSET + lba, count, dest);
    return n > 0;
}

// ─── Block I/O ─────────────────────────────────────────────────────────────

/// Read a block from disk (uncached, direct I/O).
fn readBlockUncached(block_num: u32, buf: [*]u8) bool {
    const lba = @as(u64, block_num) * (block_size / SECTOR_SIZE);
    // v53.38: DMA via HHDM-mapped buffer — buf may be BSS/stack (not DMA-safe)
    const dma_buf: [*]u8 = @ptrFromInt(io_buf_virt);
    if (!readSectorsToBuf(lba, block_size / SECTOR_SIZE, dma_buf)) return false;
    @memcpy(buf[0..block_size], dma_buf[0..block_size]);
    return true;
}

/// v53.39: Direct DMA read for DMA-safe buffers (PMM/HHDM allocated).
/// Skips io_buf_virt intermediate copy — caller must ensure buf is DMA-safe.
fn readBlockDirect(block_num: u32, buf: [*]u8) bool {
    const lba = @as(u64, block_num) * (block_size / SECTOR_SIZE);
    return readSectorsToBuf(lba, block_size / SECTOR_SIZE, buf);
}

/// Read a block through the cache (all existing callers use this).
fn readBlock(block_num: u32, buf: [*]u8) bool {
    return readBlockCached(block_num, buf);
}

// ─── Block cache (hash-indexed) ──────────────────────────────────────────

const CACHE_ENTRIES: usize = 64;
const CACHE_BLOCK_SIZE: usize = 1024; // must match block_size for revision 0

const CacheEntry = struct {
    block_num: u32 = 0,
    valid: bool = false,
    dirty: bool = false,
    data: [CACHE_BLOCK_SIZE]u8 align(8) = @splat(0),
    hash_next: ?u8 = null, // chain link in hash bucket
};

var cache: [CACHE_ENTRIES]CacheEntry = @splat(.{});

// v53.21: Static zero buffer for block zeroing — eliminates allocPage/freePage/memset
// per allocBlock call and avoids cache pollution (writeBlockUncached doesn't touch cache)
const zero_block_buf: [4096]u8 = @splat(0);
// v53.38: sb_io_buf removed — writeSuperblock now uses DMA-safe io_buf_virt
// v53.23: Static buffers for ensureBlock indirect block I/O — eliminates allocPage/freePage per call
var ensure_ind_buf: [3][4096]u8 align(8) = undefined;
var cache_hash: [CACHE_ENTRIES]?u8 = @splat(null); // hash buckets
var cache_next: usize = 0; // clock hand for replacement
var cache_hits: u64 = 0;
var cache_misses: u64 = 0;
var last_alloc_word: u32 = 0; // v53.31: allocBlock bitmap scan cursor (O(n) vs O(n²))

fn cacheHashFn(block_num: u32) usize {
    // Mix bits for better distribution
    var h = block_num;
    h ^= h >> 16;
    h *%= 0x45d9f3b;
    h ^= h >> 16;
    return @intCast(h % CACHE_ENTRIES);
}

/// O(1) hash-based cache lookup.
fn cacheLookup(block_num: u32) ?usize {
    const bucket = cacheHashFn(block_num);
    var idx = cache_hash[bucket];
    while (idx) |i| {
        if (cache[i].valid and cache[i].block_num == block_num) return i;
        idx = cache[i].hash_next;
    }
    return null;
}

/// Insert a cache entry into the hash table.
fn cacheHashInsert(slot: usize) void {
    const bucket = cacheHashFn(cache[slot].block_num);
    cache[slot].hash_next = cache_hash[bucket];
    cache_hash[bucket] = @intCast(slot);
}

/// Remove a cache entry from the hash table (for eviction).
fn cacheHashRemove(slot: usize) void {
    const bucket = cacheHashFn(cache[slot].block_num);
    var prev: ?u8 = null;
    var idx = cache_hash[bucket];
    while (idx) |i| {
        if (i == slot) {
            if (prev) |p| {
                cache[p].hash_next = cache[slot].hash_next;
            } else {
                cache_hash[bucket] = cache[slot].hash_next;
            }
            cache[slot].hash_next = null;
            return;
        }
        prev = i;
        idx = cache[i].hash_next;
    }
}

/// Read a block through the cache. On miss, reads from disk and caches.
fn readBlockCached(block_num: u32, buf: [*]u8) bool {
    if (block_size != CACHE_BLOCK_SIZE) return readBlockUncached(block_num, buf);

    if (cacheLookup(block_num)) |idx| {
        @memcpy(buf[0..block_size], cache[idx].data[0..block_size]);
        cache_hits += 1;
        return true;
    }

    cache_misses += 1;

    if (!readBlockUncached(block_num, buf)) return false;

    // Store in cache (overwrite slot at clock hand)
    const slot = cache_next;
    cache_next = (cache_next + 1) % CACHE_ENTRIES;

    // Remove old entry from hash table if it was valid
    if (cache[slot].valid) {
        cacheHashRemove(slot);
        // v53.15: Write back dirty entry on eviction (fixes latent data-loss bug
        // and enables write-back mode for batch freeBlock)
        if (cache[slot].dirty) {
            if (writeBlockUncached(cache[slot].block_num, &cache[slot].data)) {
                cache[slot].dirty = false;
            } else {
                // v53.18: Writeback failed — re-insert old entry, skip caching
                // v53.19: buf already filled at L290, no need to re-read
                cacheHashInsert(slot);
                return true;
            }
        }
    }

    cache[slot].block_num = block_num;
    cache[slot].valid = true;
    cache[slot].dirty = false;
    @memcpy(cache[slot].data[0..block_size], buf[0..block_size]);

    // Insert new entry into hash table
    cacheHashInsert(slot);
    return true;
}

/// Write a block to disk and update the cache.
fn writeBlockCached(block_num: u32, buf: [*]const u8) bool {
    if (block_size == CACHE_BLOCK_SIZE) {
        if (cacheLookup(block_num)) |idx| {
            @memcpy(cache[idx].data[0..block_size], buf[0..block_size]);
            cache[idx].dirty = false;
        } else {
            const slot = cache_next;
            cache_next = (cache_next + 1) % CACHE_ENTRIES;
            if (cache[slot].valid) {
                cacheHashRemove(slot);
                // v53.16: Write back dirty entry on eviction (same as readBlockCached/writeBlockBatch)
                if (cache[slot].dirty) {
                    if (writeBlockUncached(cache[slot].block_num, &cache[slot].data)) {
                        cache[slot].dirty = false;
                    } else {
                        // v53.18: Writeback failed — re-insert old entry, skip caching
                        cacheHashInsert(slot);
                        return writeBlockUncached(block_num, buf);
                    }
                }
            }
            cache[slot].block_num = block_num;
            cache[slot].valid = true;
            cache[slot].dirty = false;
            @memcpy(cache[slot].data[0..block_size], buf[0..block_size]);
            cacheHashInsert(slot);
        }
    }
    return writeBlockUncached(block_num, buf);
}

/// v53.15: Write a block to cache only (mark dirty, no synchronous write-through).
/// Used by freeBlock in batch mode to coalesce bitmap writes. Caller must call
/// cacheFlush() to persist dirty entries.
fn writeBlockBatch(block_num: u32, buf: [*]const u8) bool {
    if (block_size != CACHE_BLOCK_SIZE) {
        return writeBlockUncached(block_num, buf);
    }
    if (cacheLookup(block_num)) |idx| {
        @memcpy(cache[idx].data[0..block_size], buf[0..block_size]);
        cache[idx].dirty = true;
        return true;
    }
    // Not in cache — insert new entry marked dirty
    const slot = cache_next;
    cache_next = (cache_next + 1) % CACHE_ENTRIES;
    if (cache[slot].valid) {
        cacheHashRemove(slot);
        if (cache[slot].dirty) {
            if (writeBlockUncached(cache[slot].block_num, &cache[slot].data)) {
                cache[slot].dirty = false;
            } else {
                // v53.18: Writeback failed — re-insert old entry, fall back to sync write
                cacheHashInsert(slot);
                return writeBlockUncached(block_num, buf);
            }
        }
    }
    cache[slot].block_num = block_num;
    cache[slot].valid = true;
    cache[slot].dirty = true;
    @memcpy(cache[slot].data[0..block_size], buf[0..block_size]);
    cacheHashInsert(slot);
    return true;
}

/// Flush all dirty cache entries to disk.
pub fn cacheFlush() void {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    cacheFlushUnlocked();
}

/// Lock-free cacheFlush for callers that already hold fs_lock.
fn cacheFlushUnlocked() void {
    for (0..CACHE_ENTRIES) |i| {
        if (cache[i].valid and cache[i].dirty) {
            if (writeBlockUncached(cache[i].block_num, &cache[i].data)) {
                cache[i].dirty = false;
            }
        }
    }
}

/// v53.17: Write a block using batch mode (cache-only dirty) when in batch context,
/// otherwise synchronous write-through. Used by writeInode and truncate*IndirectTree.
fn writeBlockMaybeBatch(block_num: u32, buf: [*]const u8) bool {
    if (batch_free_depth > 0) {
        return writeBlockBatch(block_num, buf);
    }
    return writeBlock(block_num, buf);
}

/// Return a read-only pointer to a cached block's data (zero-copy lookup).
/// Returns null on cache miss. Caller must not hold the pointer across
/// any other cache operation (eviction may invalidate it).
fn cacheLookupPtr(block_num: u32) ?[*]const u8 {
    if (cacheLookup(block_num)) |idx| {
        return &cache[idx].data;
    }
    return null;
}

pub fn cacheStats() struct { hits: u64, misses: u64 } {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    return .{ .hits = cache_hits, .misses = cache_misses };
}

// ─── Inode operations ─────────────────────────────────────────────────────

/// Block group holding `inode_num`, or null if the number is out of range.
///
/// Inode numbers reach us from on-disk directory entries, so a corrupt or
/// hostile image can name any inode. Indexing the descriptor table with the
/// derived group would then read past the table, and inode 0 would underflow.
fn groupForInode(inode_num: u32) ?u32 {
    if (inode_num == 0 or inodes_per_group == 0) return null;
    const group = (inode_num - 1) / inodes_per_group;
    if (group >= groups_count) return null;
    return group;
}

/// Block group holding `block_num`, or null if the number is out of range.
/// Block numbers come from on-disk inode block pointers.
fn groupForBlock(block_num: u32) ?u32 {
    if (block_num < first_data_block or sb.blocks_per_group == 0) return null;
    const group = (block_num - first_data_block) / sb.blocks_per_group;
    if (group >= groups_count) return null;
    return group;
}

fn readInode(inode_num: u32, out: *Ext2Inode) bool {
    const gds: [*]const Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const group = groupForInode(inode_num) orelse return false;
    const loc = eu.inodeLocation(inode_num, inodes_per_group, inode_size, block_size, gds[group].bg_inode_table);
    const target_block = loc.target_block;
    const offset_in_block = loc.offset_in_block;
    const copy_len = loc.copy_len;

    // `inode_size` is the on-disk *stride* between inodes (256 on rev>=1
    // filesystems), but our `Ext2Inode` only models the 128-byte base inode.
    // Clamp the copy to the struct size so we never overflow `out` (the extra
    // bytes of a 256-byte inode are extended fields we don't use).
    const out_bytes: [*]u8 = @ptrCast(out);

    // Try zero-copy cache lookup first, fall back to sector_buf_virt
    const buf: [*]const u8 = cacheLookupPtr(target_block) orelse blk: {
        const tmp: [*]u8 = @ptrFromInt(sector_buf_virt);
        if (!readBlock(target_block, tmp)) return false;
        break :blk tmp;
    };

    if (offset_in_block + copy_len > block_size) {
        // Inode straddles a block boundary — read the second block too.
        const buf2: [*]const u8 = cacheLookupPtr(target_block + 1) orelse blk: {
            const buf2_phys = pmm.allocPage() orelse return false;
            defer pmm.freePage(buf2_phys);
            const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf2_phys));
            if (!readBlock(target_block + 1, tmp)) return false;
            break :blk cacheLookupPtr(target_block + 1) orelse return false;
        };

        const first_part = block_size - offset_in_block;
        @memcpy(out_bytes[0..first_part], buf[offset_in_block .. offset_in_block + first_part]);
        @memcpy(out_bytes[first_part..copy_len], buf2[0 .. copy_len - first_part]);
    } else {
        @memcpy(out_bytes[0..copy_len], buf[offset_in_block .. offset_in_block + copy_len]);
    }
    return true;
}

// ─── Directory operations ─────────────────────────────────────────────────

pub fn openFile(name: []const u8) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -1;

    // Start from root inode (2)
    const result = walkPath(2, name);
    if (result >= 0) {
        // v52.0: store path for execveat dirfd resolution
        const idx: usize = @intCast(result);
        const copy_len = @min(name.len, 127);
        @memcpy(open_file_paths[idx][0..copy_len], name[0..copy_len]);
        open_file_paths[idx][copy_len] = 0;
    }
    return result;
}

fn walkPath(start_inode: u32, path: []const u8) i64 {
    return walkPathInner(start_inode, path, 0);
}

/// Inner walkPath with symlink depth tracking (max 8 levels).
fn walkPathInner(start_inode: u32, path: []const u8, depth: u32) i64 {
    if (depth > 8) return -40; // ELOOP: too many symlinks

    var current_inode = start_inode;
    var pos: u32 = 0;

    while (pos < path.len) {
        // Skip leading slashes
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos >= path.len) break;

        // Find end of component
        const start = pos;
        while (pos < path.len and path[pos] != '/') pos += 1;
        const component = path[start..pos];
        const is_last = (pos >= path.len);

        // Read inode
        var inode: Ext2Inode = undefined;
        if (!readInode(current_inode, &inode)) return -1;

        // Must be a directory
        if (!eu.isDirectory(inode.mode)) return -1;

        // Search directory entries for component (K1: dcache hit skips the scan)
        const found = findDirEntryCached(current_inode, &inode, component) orelse return -1;

        // Check if the found entry is a symlink
        var found_inode: Ext2Inode = undefined;
        if (readInode(found, &found_inode) and eu.isSymlink(found_inode.mode)) {
            // It's a symlink — read target
            const target = readSymlinkTarget(&found_inode) orelse return -5;

            // Resolve from root if absolute, or from current dir if relative
            const new_start: u32 = if (target.len > 0 and target[0] == '/') 2 else current_inode;
            if (is_last) {
                // Final component: resolve symlink target and open it
                return walkPathInner(new_start, target, depth + 1);
            } else {
                // Intermediate: resolve symlink, then continue with remaining path
                const remaining = path[pos..];
                // First resolve symlink to get intermediate inode
                const resolved_fd = walkPathInner(new_start, target, depth + 1);
                if (resolved_fd < 0) return resolved_fd;
                // Get the inode from the opened file, then close it
                const resolved_inode = open_files[@intCast(resolved_fd)].inode_num;
                closeFileUnlocked(@intCast(resolved_fd)); // v52.1 fix: use closeFile to also clear path
                return walkPathInner(resolved_inode, remaining, depth + 1);
            }
        }

        current_inode = found;
    }

    // Open the file
    if (current_inode == start_inode) return -1; // path was just "/"

    var inode: Ext2Inode = undefined;
    if (!readInode(current_inode, &inode)) return -1;

    // Allocate slot
    for (0..MAX_OPEN_FILES) |i| {
        if (i >= open_count or open_files[i].inode_num == 0) {
            open_files[i] = .{
                .inode_num = current_inode,
                .inode = inode,
                .offset = 0,
            };
            if (i >= open_count) open_count = @intCast(i + 1);
            return @intCast(i);
        }
    }
    return -1;
}

/// Read the target of a symlink inode.
/// Short symlinks: inline in i_block. Long symlinks: in data block → static buffer.
fn readSymlinkTarget(inode: *const Ext2Inode) ?[]const u8 {
    const size = inode.size;
    if (size == 0) return null;

    // Short symlink: target stored inline in i_block (up to 60 bytes)
    if (inode.blocks == 0) {
        const block_bytes: [*]const u8 = @ptrCast(&inode.block);
        return block_bytes[0..size];
    }

    // Long symlink: target stored in data block — copy to static buffer
    const phys_block = inode.block[0];
    if (phys_block == 0) return null;

    const buf_phys = pmm.allocPage() orelse return null;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
    if (!readBlock(phys_block, buf)) return null;

    const copy_len = @min(size, @as(u32, 255));
    @memcpy(symlink_buf[0..copy_len], buf[0..copy_len]);
    return symlink_buf[0..copy_len];
}

/// Resolve a path to its parent directory inode and the final filename component.
/// Resolves symlinks in intermediate directory components (v50.0).
/// Returns (parent_inode_num, filename) or null on failure.
fn resolveParent(path: []const u8) ?struct { parent: u32, name: []const u8 } {
    // Find the last '/' to split parent path from filename
    var last_slash: usize = 0;
    for (0..path.len) |i| {
        if (path[i] == '/') last_slash = i + 1;
    }

    const filename = path[last_slash..];
    if (filename.len == 0) return null; // trailing '/' or empty

    // Walk to parent directory
    var parent_inode: u32 = 2; // start from root
    if (last_slash > 0) {
        const parent_path = path[0 .. last_slash - 1]; // strip trailing '/'
        var pos: usize = 0;

        while (pos < parent_path.len) {
            while (pos < parent_path.len and parent_path[pos] == '/') pos += 1;
            if (pos >= parent_path.len) break;

            const start = pos;
            while (pos < parent_path.len and parent_path[pos] != '/') pos += 1;
            const component = parent_path[start..pos];

            var inode: Ext2Inode = undefined;
            if (!readInode(parent_inode, &inode)) return null;
            if (!eu.isDirectory(inode.mode)) return null;

            const dir_inode = parent_inode; // directory containing this component
            parent_inode = findDirEntryCached(dir_inode, &inode, component) orelse return null;

            // v52.2: resolve symlinks in intermediate components (no fd allocation)
            var found_inode: Ext2Inode = undefined;
            if (readInode(parent_inode, &found_inode) and
                eu.isSymlink(found_inode.mode))
            {
                if (readSymlinkTarget(&found_inode)) |target| {
                    const new_start: u32 = if (target.len > 0 and target[0] == '/') 2 else dir_inode;
                    const resolved = walkPathToInodeResolve(new_start, target, 1) orelse return null;
                    parent_inode = resolved;
                } else {
                    return null;
                }
            }
        }
    }

    return .{ .parent = parent_inode, .name = filename };
}

/// K1 dcache: probe (parent_inode_num, name) first; a hit skips the directory
/// block reads entirely. On a miss, run the slow scan and fill the cache on
/// success (positive entries only). Caller holds fs_lock; the dcache lock is
/// a leaf taken briefly inside lookup/fill and never held across I/O.
fn findDirEntryCached(dir_inode_num: u32, inode: *const Ext2Inode, name: []const u8) ?u32 {
    if (dcache.lookup(.ext2, dir_inode_num, name)) |ino| return ino;
    const found = findDirEntry(inode, name) orelse return null;
    dcache.fill(.ext2, dir_inode_num, name, found);
    return found;
}

fn findDirEntry(inode: *const Ext2Inode, name: []const u8) ?u32 {
    const dir_size = inode.size;
    var offset: u32 = 0;

    while (offset < dir_size) {
        const block_num = offset / block_size;
        const phys_block = resolveBlock(inode, block_num);

        if (phys_block == 0) {
            offset += block_size;
            continue;
        }

        // Try zero-copy cache first, fall back to allocPage + readBlock
        const buf: [*]const u8 = cacheLookupPtr(phys_block) orelse blk: {
            const buf_phys = pmm.allocPage() orelse return null;
            defer pmm.freePage(buf_phys);
            const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
            if (!readBlock(phys_block, tmp)) return null;
            // readBlockCached stores it; now get zero-copy pointer
            break :blk cacheLookupPtr(phys_block) orelse return null;
        };

        var pos: u32 = 0;
        while (pos < block_size and offset + pos < dir_size) {
            const entry = eu.readDirEntry(buf, pos, block_size) orelse break;

            if (entry.inode != 0 and entry.name_len == name.len) {
                const entry_name = buf[entry.name_pos..][0..entry.name_len];
                if (eu.namesEqual(entry_name, name)) return entry.inode;
            }

            pos += entry.rec_len;
        }
        offset += block_size;
    }
    return null;
}

// ─── Block resolution (direct + single/double/triple indirect) ─────────────

/// Load one u32 pointer from an indirect block. Cache hit is zero-copy;
/// miss allocates a temp page, reads via `readBlock` (which populates cache),
/// then returns the entry. Returns 0 on missing block / I/O failure.
fn loadIndirectPtr(block_num: u32, index: u32) u32 {
    if (block_num == 0) return 0;
    if (cacheLookupPtr(block_num)) |buf| {
        const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
        return ptrs[index];
    }
    const buf_phys = pmm.allocPage() orelse return 0;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
    if (!readBlock(block_num, buf)) return 0;
    const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
    return ptrs[index];
}

/// SK-64: compose `classifyLogicalBlock` + cached pointer walks. Addressing
/// math matches `eu.resolveLogicalPure`; only the pointer-table source differs
/// (block cache / disk vs in-memory tables).
fn resolveBlock(inode: *const Ext2Inode, logical_block: u32) u32 {
    const ppb = eu.ptrsPerBlock(block_size);
    switch (eu.classifyLogicalBlock(logical_block, ppb)) {
        .direct => |i| return inode.block[i],
        .single => |i| return loadIndirectPtr(inode.block[12], i),
        .double => |d| {
            const single = loadIndirectPtr(inode.block[13], d.idx1);
            return loadIndirectPtr(single, d.idx2);
        },
        .triple => |t| {
            const dbl = loadIndirectPtr(inode.block[14], t.idx1);
            const single = loadIndirectPtr(dbl, t.idx2);
            return loadIndirectPtr(single, t.idx3);
        },
        .out_of_range => return 0,
    }
}

// ─── File read ─────────────────────────────────────────────────────────────

pub fn readFile(file_idx: u32, offset: u32, buf: [*]u8, count: u32) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= open_count) return -1;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return -1;

    const file_size = f.inode.size;
    if (offset >= file_size) return 0;

    const remaining = file_size - offset;
    const to_read = if (count > remaining) remaining else count;
    if (to_read == 0) return 0;

    var read_total: u32 = 0;
    var current_offset = offset;
    const page_cache = @import("page_cache.zig");
    const inode_id: u64 = 0x3000_0000_0000_0000 + @as(u64, f.inode_num);

    while (read_total < to_read) {
        const logical_block = current_offset / block_size;
        const block_offset = current_offset % block_size;
        const chunk = @min(to_read - read_total, block_size - block_offset);

        // Try page cache first (with sequential prefetch).
        // v53.51: copy-out under cache_lock — a raw page pointer could be
        // freed by a concurrent clock eviction before the memcpy.
        const page_idx = logical_block; // page_offset in pages
        if (page_cache.copyPageAndRecord(inode_id, page_idx, block_offset, buf + read_total, chunk)) |pf_count| {
            if (pf_count > 0) {
                prefetchPages(&f.inode, inode_id, page_idx + 1, pf_count);
            }
        } else {
            // Cache miss — read from disk
            const phys_block = resolveBlock(&f.inode, logical_block);
            if (phys_block == 0) break;
            const tmp_phys = pmm.allocPage() orelse break;
            const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(tmp_phys));
            // v53.28: Use readBlockUncached to avoid polluting ext2 block cache with data blocks
            // v53.39: Use readBlockDirect — tmp is PMM/HHDM allocated (DMA-safe), skip io_buf copy
            if (!readBlockDirect(phys_block, tmp)) {
                pmm.freePage(tmp_phys);
                break;
            }
            // v53.33: Zero remaining bytes — readBlockUncached reads block_size bytes,
            // but page_cache stores 4096-byte pages. Without zeroing, garbage data
            // from the physical page contaminates the cache entry.
            // v53.34: Zero-fill moved into insertPage (data_len parameter).
            @memcpy(buf[read_total .. read_total + chunk], tmp[block_offset .. block_offset + chunk]);
            // v53.42: Transfer page ownership to cache — avoids redundant allocPage+memcpy+freePage
            if (page_cache.insertPageOwned(inode_id, page_idx, tmp_phys, block_size) == null) {
                pmm.freePage(tmp_phys); // Cache full — couldn't insert
            }
            // Record access and prefetch on sequential pattern
            const pf_count = page_cache.recordAccess(inode_id, page_idx);
            if (pf_count > 0) {
                prefetchPages(&f.inode, inode_id, page_idx + 1, pf_count);
            }
        }
        read_total += chunk;
        current_offset += chunk;
    }

    return if (read_total == 0) -1 else @intCast(read_total);
}

/// Prefetch sequential pages into the page cache.
/// Reads up to `count` pages starting from `start_page` for the given inode.
/// Skips pages that are already cached. Best-effort: stops on first I/O error.
fn prefetchPages(inode: *const Ext2Inode, inode_id: u64, start_page: u64, count: u32) void {
    const page_cache = @import("page_cache.zig");
    const total_pages = (inode.size + block_size - 1) / block_size;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const pg = start_page + @as(u64, i);
        if (pg >= total_pages) break;
        // Skip if already cached
        if (page_cache.isCached(inode_id, pg)) continue;
        // Resolve physical block and read
        const phys_block = resolveBlock(inode, @intCast(pg));
        if (phys_block == 0) break;
        const tmp_phys = pmm.allocPage() orelse break;
        const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(tmp_phys));
        // v53.28: Use readBlockUncached to avoid polluting ext2 block cache with data blocks
        // v53.39: Use readBlockDirect — tmp is PMM/HHDM allocated (DMA-safe), skip io_buf copy
        if (!readBlockDirect(phys_block, tmp)) {
            pmm.freePage(tmp_phys);
            break;
        }
        // v53.42: Transfer page ownership to cache — avoids redundant allocPage+memcpy+freePage
        if (page_cache.insertPageOwned(inode_id, pg, tmp_phys, block_size) == null) {
            pmm.freePage(tmp_phys); // Cache full — couldn't insert
        }
    }
}

/// Best-effort page prefetch for an already-open ext2 regular file.
/// The descriptor offset is not involved or modified.
pub fn prefetchFilePages(file_idx: u32, start_page: u64, count: u32) void {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= open_count) return;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return;
    prefetchPages(&f.inode, 0x3000_0000_0000_0000 + @as(u64, f.inode_num), start_page, count);
}

pub fn getInodeNum(file_idx: u32) u32 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= MAX_OPEN_FILES) return 0;
    return open_files[file_idx].inode_num;
}

pub fn getFileSize(file_idx: u32) u64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= open_count) return 0;
    return open_files[file_idx].inode.size;
}

/// Read the authoritative on-disk size for an inode without requiring an
/// open-file slot. Used by truncate-style limits before mutating the inode.
pub fn getInodeSize(inode_num: u32) ?u64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active or inode_num == 0) return null;
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return null;
    return inode.size;
}

/// Re-read the on-disk inode and refresh the slot's cached size. Each open
/// slot keeps its own inode copy, so a write through one slot never reaches
/// the others' inode.size — concurrent fds would see a stale EOF without
/// this. Returns the refreshed size (cached value on read failure).
pub fn refreshSize(file_idx: u32) u64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= open_count) return 0;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return 0;
    var disk_inode: Ext2Inode = undefined;
    if (readInode(f.inode_num, &disk_inode)) {
        f.inode.size = disk_inode.size;
    }
    return f.inode.size;
}

pub fn closeFile(file_idx: u32) void {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    closeFileUnlocked(file_idx);
}

/// Lock-free closeFile for callers that already hold fs_lock.
fn closeFileUnlocked(file_idx: u32) void {
    if (file_idx >= open_count) return;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return;
    // Shared across fork/clone: drop one reference, free only at zero.
    if (f.ref_count > 1) {
        f.ref_count -= 1;
        return;
    }
    f.ref_count = 0;
    f.inode_num = 0;
    // v52.3: clear full path to prevent stale data leak
    @memset(open_file_paths[file_idx][0..128], 0);
}

/// Add a reference to an open file slot (fork/clone fd-table copy).
pub fn retainFile(file_idx: u32) void {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= open_count) return;
    if (open_files[file_idx].inode_num == 0) return;
    open_files[file_idx].ref_count += 1;
}

// ─── Directory listing ─────────────────────────────────────────────────────

pub fn listDir(path: []const u8, callback: *const fn ([*]const u8, u32) void) void {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return;

    const inode_num = if (path.len == 0 or (path.len == 1 and path[0] == '/'))
        @as(u32, 2)
    else blk: {
        const r = walkPath(2, path);
        if (r < 0) break :blk @as(u32, 0);
        const inum = open_files[@intCast(r)].inode_num;
        closeFileUnlocked(@intCast(r)); // v52.1 fix: close fd to avoid leak
        break :blk inum;
    };
    if (inode_num == 0) return;

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return;
    if (!eu.isDirectory(inode.mode)) return;

    const dir_size = inode.size;
    var offset: u32 = 0;

    while (offset < dir_size) {
        const block_num = offset / block_size;
        const phys_block = resolveBlock(&inode, block_num);
        if (phys_block == 0) break;

        // Zero-copy cache lookup, fall back to allocPage
        const buf: [*]const u8 = cacheLookupPtr(phys_block) orelse blk: {
            const buf_phys = pmm.allocPage() orelse break :blk null;
            defer pmm.freePage(buf_phys);
            const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
            if (!readBlock(phys_block, tmp)) break :blk null;
            break :blk cacheLookupPtr(phys_block) orelse break :blk null;
        } orelse break;

        var pos: u32 = 0;
        while (pos < block_size) {
            const entry = eu.readDirEntry(buf, pos, block_size) orelse break;

            if (entry.inode != 0 and entry.name_len > 0) {
                callback(buf + entry.name_pos, entry.name_len);
            }

            pos += entry.rec_len;
            if (pos >= block_size) break;
        }
        offset += block_size;
    }
}

pub fn getFileName(file_idx: u32) ?[]const u8 {
    _ = file_idx;
    return null; // ext2 doesn't store name in inode
}

/// List directory entries of root (inode 2) into a buffer.
/// Writes filenames separated by '\n'. Returns bytes written.
pub fn listDirRoot(buf: []u8) usize {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return 0;
    return listDirInode(2, buf);
}

fn listDirInode(inode_num: u32, buf: []u8) usize {
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return 0;
    if (!eu.isDirectory(inode.mode)) return 0;

    const dir_size = inode.size;
    if (dir_size == 0 or dir_size > 65536) return 0;

    const blk: [*]u8 = @ptrFromInt(sector_buf_virt);

    var offset: u32 = 0;
    var pos: usize = 0;

    while (offset < dir_size) {
        const block_num = offset / block_size;
        const phys_block = resolveBlock(&inode, block_num);
        if (phys_block == 0) break;
        if (!readBlock(phys_block, blk)) break;

        var bpos: u32 = 0;
        while (bpos < block_size) {
            const entry = eu.readDirEntry(blk, bpos, block_size) orelse break;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name = blk + entry.name_pos;
                const name_len: usize = entry.name_len;
                if (pos + name_len + 1 <= buf.len) {
                    @memcpy(buf[pos .. pos + name_len], name[0..name_len]);
                    pos += name_len;
                    buf[pos] = '\n';
                    pos += 1;
                }
            }

            bpos += entry.rec_len;
            if (bpos >= block_size) break;
        }
        offset += block_size;
    }
    return pos;
}

/// Read directory entries starting from `offset` byte position within the directory.
/// Returns entries as (name, name_len, inode_num, file_type, next_offset) tuples.
/// `out_offset` is updated to the next offset for subsequent reads.
/// Returns the number of entries written to the output arrays.
pub fn readDirEntries(file_idx: u32, start_offset: u32, names: [*][256]u8, name_lens: [*]u32, inodes: [*]u32, file_types: [*]u8, next_offsets: [*]u32, max_entries: u32) struct { count: u32, new_offset: u32 } {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return .{ .count = 0, .new_offset = start_offset };
    if (file_idx >= open_count) return .{ .count = 0, .new_offset = start_offset };
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return .{ .count = 0, .new_offset = start_offset };
    if (!eu.isDirectory(f.inode.mode)) return .{ .count = 0, .new_offset = start_offset };

    const dir_size = f.inode.size;
    if (start_offset >= dir_size) return .{ .count = 0, .new_offset = start_offset };

    var offset = start_offset;
    var count: u32 = 0;

    while (offset < dir_size and count < max_entries) {
        const block_num = offset / block_size;
        const phys_block = resolveBlock(&f.inode, block_num);
        if (phys_block == 0) break;

        // v53.50: Zero-copy cache lookup — avoids per-call allocPage/freePage.
        // Same pattern as findDirEntry: cache hit → direct pointer; cache miss →
        // alloc temp page, readBlock inserts into cache, get pointer, free temp.
        var buf: [*]const u8 = undefined;
        if (cacheLookupPtr(phys_block)) |cached| {
            buf = cached;
        } else {
            const buf_phys = pmm.allocPage() orelse break;
            defer pmm.freePage(buf_phys);
            const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
            if (!readBlock(phys_block, tmp)) break;
            buf = cacheLookupPtr(phys_block) orelse break;
        }

        const pos_in_block = offset % block_size;
        var pos: u32 = pos_in_block;

        while (pos < block_size and count < max_entries) {
            const entry = eu.readDirEntry(buf, pos, block_size) orelse break;

            if (entry.inode != 0 and entry.name_len > 0) {
                // v53.3: copy name data to caller's output array
                const nlen: usize = @intCast(entry.name_len);
                @memcpy(names[count][0..nlen], buf[entry.name_pos..][0..nlen]);
                name_lens[count] = entry.name_len;
                inodes[count] = entry.inode;
                file_types[count] = entry.file_type;
                const next_off = offset - pos_in_block + pos + entry.rec_len;
                next_offsets[count] = next_off;
                count += 1;
            }

            const new_pos = pos + entry.rec_len;
            offset = offset - pos_in_block + new_pos;
            pos = new_pos;
            if (pos >= block_size) break;
        }

        // Move to next block boundary
        offset = (offset / block_size + 1) * block_size;
    }

    return .{ .count = count, .new_offset = offset };
}

fn freeSingleIndirectTree(block_num: u32, ptrs_per_block: u32) bool {
    const phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(block_num, buf)) return false;

    const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
    for (0..ptrs_per_block) |idx| {
        if (ptrs[idx] != 0) freeBlock(ptrs[idx]);
    }
    freeBlock(block_num);
    return true;
}

fn truncateSingleIndirectTree(block_num: u32, keep_blocks: u32, ptrs_per_block: u32) bool {
    if (keep_blocks >= ptrs_per_block) return true;
    if (keep_blocks == 0) return freeSingleIndirectTree(block_num, ptrs_per_block);

    const phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(block_num, buf)) return false;

    const ptrs: [*]u32 = @ptrCast(@alignCast(buf));
    for (keep_blocks..ptrs_per_block) |idx| {
        if (ptrs[idx] != 0) {
            freeBlock(ptrs[idx]);
            ptrs[idx] = 0;
        }
    }
    return writeBlockMaybeBatch(block_num, buf);
}

fn freeDoubleIndirectTree(block_num: u32, ptrs_per_block: u32) bool {
    const phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(block_num, buf)) return false;

    const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
    for (0..ptrs_per_block) |idx| {
        if (ptrs[idx] != 0 and !freeSingleIndirectTree(ptrs[idx], ptrs_per_block)) return false;
    }
    freeBlock(block_num);
    return true;
}

fn truncateDoubleIndirectTree(block_num: u32, keep_blocks: u32, ptrs_per_block: u32) bool {
    const capacity = ptrs_per_block * ptrs_per_block;
    if (keep_blocks >= capacity) return true;
    if (keep_blocks == 0) return freeDoubleIndirectTree(block_num, ptrs_per_block);

    const phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(block_num, buf)) return false;

    const ptrs: [*]u32 = @ptrCast(@alignCast(buf));
    const keep_tree = keep_blocks / ptrs_per_block;
    const keep_in_tree = keep_blocks % ptrs_per_block;
    var first_free_tree = keep_tree;

    if (keep_in_tree > 0) {
        if (ptrs[keep_tree] != 0 and !truncateSingleIndirectTree(ptrs[keep_tree], keep_in_tree, ptrs_per_block)) return false;
        first_free_tree = keep_tree + 1;
    }

    for (first_free_tree..ptrs_per_block) |idx| {
        if (ptrs[idx] != 0) {
            if (!freeSingleIndirectTree(ptrs[idx], ptrs_per_block)) return false;
            ptrs[idx] = 0;
        }
    }
    return writeBlockMaybeBatch(block_num, buf);
}

fn freeTripleIndirectTree(block_num: u32, ptrs_per_block: u32) bool {
    const phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(block_num, buf)) return false;

    const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
    for (0..ptrs_per_block) |idx| {
        if (ptrs[idx] != 0 and !freeDoubleIndirectTree(ptrs[idx], ptrs_per_block)) return false;
    }
    freeBlock(block_num);
    return true;
}

fn truncateTripleIndirectTree(block_num: u32, keep_blocks: u32, ptrs_per_block: u32) bool {
    const dbl_capacity = ptrs_per_block * ptrs_per_block;
    const capacity = dbl_capacity * ptrs_per_block;
    if (keep_blocks >= capacity) return true;
    if (keep_blocks == 0) return freeTripleIndirectTree(block_num, ptrs_per_block);

    const phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(block_num, buf)) return false;

    const ptrs: [*]u32 = @ptrCast(@alignCast(buf));
    const keep_tree = keep_blocks / dbl_capacity;
    const keep_in_tree = keep_blocks % dbl_capacity;
    var first_free_tree = keep_tree;

    if (keep_in_tree > 0) {
        if (ptrs[keep_tree] != 0 and !truncateDoubleIndirectTree(ptrs[keep_tree], keep_in_tree, ptrs_per_block)) return false;
        first_free_tree = keep_tree + 1;
    }

    for (first_free_tree..ptrs_per_block) |idx| {
        if (ptrs[idx] != 0) {
            if (!freeDoubleIndirectTree(ptrs[idx], ptrs_per_block)) return false;
            ptrs[idx] = 0;
        }
    }
    return writeBlockMaybeBatch(block_num, buf);
}

/// Flush callback for writeback invalidation on truncate/unlink: route the
/// staged extent back through writeFile using the slot that staged it.
fn writebackFlush(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32) bool {
    return writeFile(file_idx, @intCast(byte_offset), data, len) == len;
}

/// Flush + drop all writeback extents staged for `inode_num`. Must be called
/// before truncate/unlink frees blocks: a dirty extent flushed afterwards
/// would regrow a truncated file or write into a freed inode. fs_lock is
/// dropped around the call because the flush callback re-enters writeFile,
/// which acquires fs_lock (not recursive).
fn invalidateWriteback(inode_num: u32, flags: *u64) void {
    const writeback = @import("writeback.zig");
    const wb_inode: u64 = 0x3000_0000_0000_0000 + @as(u64, inode_num);
    fs_lock.release(flags.*);
    _ = writeback.invalidateFile(wb_inode, .ext2, writebackFlush);
    flags.* = fs_lock.acquire();
}

/// Truncate a file to the given length. Frees blocks beyond the new size.
pub fn truncateFile(file_idx: u32, new_size: u32) bool {
    var flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return false;
    if (file_idx >= open_count) return false;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return false;

    if (new_size >= f.inode.size) {
        // Growing: just update size (blocks will be allocated on write)
        f.inode.size = new_size;
        _ = writeInode(f.inode_num, &f.inode);
        return true;
    }

    // v53.51: flush+drop staged writeback extents before freeing blocks.
    const inode_num = f.inode_num;
    invalidateWriteback(inode_num, &flags);
    // fs_lock was dropped — make sure the slot still refers to the same inode.
    if (f.inode_num != inode_num) return false;

    // Shrinking: free blocks beyond new_size
    // v53.15: Batch mode — defer cacheFlush+writeGroupDescs+writeSuperblock
    batch_free_depth += 1;
    defer {
        batch_free_depth -= 1;
        if (batch_free_depth == 0) {
            cacheFlushUnlocked();
            writeGroupDescs();
            writeSuperblock();
            flushDiscard(); // G5: issue coalesced discards for batched frees
        }
    }
    const new_blocks_needed = if (new_size == 0) 0 else (new_size + block_size - 1) / block_size;
    const ptrs_per_block = block_size / 4;
    const page_cache = @import("page_cache.zig");
    page_cache.invalidateInode(0x3000_0000_0000_0000 + @as(u64, f.inode_num));

    // Free direct blocks beyond needed
    for (new_blocks_needed..EXT2_INODE_DIRECT) |i| {
        if (i < EXT2_INODE_DIRECT and f.inode.block[i] != 0) {
            freeBlock(f.inode.block[i]);
            f.inode.block[i] = 0;
        }
    }

    // Trim single, double, and triple indirect tails with shared boundary logic.
    const single_base = EXT2_INODE_DIRECT;
    const dbl_base = EXT2_INODE_DIRECT + ptrs_per_block;
    const tri_base = dbl_base + ptrs_per_block * ptrs_per_block;

    if (f.inode.block[12] != 0 and new_blocks_needed < dbl_base) {
        const keep = if (new_blocks_needed <= single_base) 0 else new_blocks_needed - single_base;
        if (!truncateSingleIndirectTree(f.inode.block[12], keep, ptrs_per_block)) return false;
        if (keep == 0) f.inode.block[12] = 0;
    }

    if (f.inode.block[13] != 0) {
        const keep = if (new_blocks_needed <= dbl_base) 0 else new_blocks_needed - dbl_base;
        if (!truncateDoubleIndirectTree(f.inode.block[13], keep, ptrs_per_block)) return false;
        if (keep == 0) f.inode.block[13] = 0;
    }

    if (f.inode.block[14] != 0) {
        const keep = if (new_blocks_needed <= tri_base) 0 else new_blocks_needed - tri_base;
        if (!truncateTripleIndirectTree(f.inode.block[14], keep, ptrs_per_block)) return false;
        if (keep == 0) f.inode.block[14] = 0;
    }

    f.inode.size = new_size;
    f.inode.blocks = new_blocks_needed * (block_size / 512);
    if (!writeInode(f.inode_num, &f.inode)) return false; // v53.4: check writeInode result
    return true;
}

/// Truncate a file by inode number (v53.3: for truncate syscall).
/// Works directly on disk inode without going through open_files table.
pub fn truncateByInode(inode_num: u32, new_size: u32) bool {
    var flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return false;
    if (inode_num == 0) return false;

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return false;

    if (new_size >= inode.size) {
        // Growing: just update size (blocks allocated on write)
        inode.size = new_size;
        if (!writeInode(inode_num, &inode)) return false; // v53.4: check writeInode result
        return true;
    }

    // v53.51: flush+drop staged writeback extents before freeing blocks.
    invalidateWriteback(inode_num, &flags);

    // v53.15: Batch mode — defer cacheFlush+writeGroupDescs+writeSuperblock
    batch_free_depth += 1;
    defer {
        batch_free_depth -= 1;
        if (batch_free_depth == 0) {
            cacheFlushUnlocked();
            writeGroupDescs();
            writeSuperblock();
            flushDiscard(); // G5: issue coalesced discards for batched frees
        }
    }
    // v53.4: invalidate page cache for this inode before freeing blocks
    const page_cache = @import("page_cache.zig");
    page_cache.invalidateInode(0x3000_0000_0000_0000 + @as(u64, inode_num));

    const new_blocks_needed = if (new_size == 0) @as(u32, 0) else @as(u32, (new_size + block_size - 1) / block_size);
    const ptrs_per_block = block_size / 4;

    // Free direct blocks beyond needed
    for (new_blocks_needed..EXT2_INODE_DIRECT) |i| {
        if (i < EXT2_INODE_DIRECT and inode.block[i] != 0) {
            freeBlock(inode.block[i]);
            inode.block[i] = 0;
        }
    }

    const single_base = EXT2_INODE_DIRECT;
    const dbl_base = EXT2_INODE_DIRECT + ptrs_per_block;
    const tri_base = dbl_base + ptrs_per_block * ptrs_per_block;

    if (inode.block[12] != 0 and new_blocks_needed < dbl_base) {
        const keep = if (new_blocks_needed <= single_base) 0 else new_blocks_needed - single_base;
        if (!truncateSingleIndirectTree(inode.block[12], keep, ptrs_per_block)) return false;
        if (keep == 0) inode.block[12] = 0;
    }

    if (inode.block[13] != 0) {
        const keep = if (new_blocks_needed <= dbl_base) 0 else new_blocks_needed - dbl_base;
        if (!truncateDoubleIndirectTree(inode.block[13], keep, ptrs_per_block)) return false;
        if (keep == 0) inode.block[13] = 0;
    }

    if (inode.block[14] != 0) {
        const keep = if (new_blocks_needed <= tri_base) 0 else new_blocks_needed - tri_base;
        if (!truncateTripleIndirectTree(inode.block[14], keep, ptrs_per_block)) return false;
        if (keep == 0) inode.block[14] = 0;
    }

    inode.size = new_size;
    inode.blocks = new_blocks_needed * (block_size / 512);
    if (!writeInode(inode_num, &inode)) return false; // v53.4: check writeInode result
    return true;
}

/// Rename a file: remove old entry from source dir, add entry in dest dir.
/// Supports cross-directory rename (old_path and new_path can be in different dirs).
pub fn renameFile(old_path: []const u8, new_path: []const u8) bool {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return false;

    // Resolve source: parent dir + old filename
    const old_resolved = resolveParent(old_path) orelse return false;
    const old_parent_inode = old_resolved.parent;
    const old_filename = old_resolved.name;

    // Resolve destination: parent dir + new filename
    const new_resolved = resolveParent(new_path) orelse return false;
    const new_parent_inode = new_resolved.parent;
    const new_filename = new_resolved.name;

    // Find the file's inode
    var old_parent_ino_data: Ext2Inode = undefined;
    if (!readInode(old_parent_inode, &old_parent_ino_data)) return false;
    const file_inode_num = findDirEntryCached(old_parent_inode, &old_parent_ino_data, old_filename) orelse return false;

    // Read file inode to get file_type
    var file_inode: Ext2Inode = undefined;
    if (!readInode(file_inode_num, &file_inode)) return false;
    const file_type: u8 = if (eu.isDirectory(file_inode.mode)) 2 else 1;

    // If destination exists, remove it first (overwrite semantics)
    var new_parent_inode_data: Ext2Inode = undefined;
    if (readInode(new_parent_inode, &new_parent_inode_data)) {
        if (findDirEntryCached(new_parent_inode, &new_parent_inode_data, new_filename)) |_| {
            _ = removeDirEntry(new_parent_inode, new_filename);
        }
    }

    // Remove old directory entry
    if (!removeDirEntry(old_parent_inode, old_filename)) return false;

    // Add new directory entry (possibly in a different directory)
    if (!addDirEntry(new_parent_inode, file_inode_num, new_filename, file_type)) return false;

    serial.writeString("[ext2] renamed to: ");
    serial.writeString(new_filename);
    serial.writeString("\n");
    return true;
}

// ─── Write support ──────────────────────────────────────────────────────────

fn writeBlockUncached(block_num: u32, buf: [*]const u8) bool {
    const lba = @as(u64, block_num) * (block_size / SECTOR_SIZE);
    // v53.38: DMA via HHDM-mapped buffer — buf may be BSS/stack (not DMA-safe)
    const dma_buf: [*]u8 = @ptrFromInt(io_buf_virt);
    @memcpy(dma_buf[0..block_size], buf[0..block_size]);
    const n = virtio_blk.writeSectors(DISK_LBA_OFFSET + lba, block_size / SECTOR_SIZE, dma_buf);
    return n > 0;
}

/// Write a block to disk and update cache (write-through).
fn writeBlock(block_num: u32, buf: [*]const u8) bool {
    return writeBlockCached(block_num, buf);
}

fn writeInode(inode_num: u32, inode: *const Ext2Inode) bool {
    const gds: [*]const Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const group = groupForInode(inode_num) orelse return false;
    const loc = eu.inodeLocation(inode_num, inodes_per_group, inode_size, block_size, gds[group].bg_inode_table);
    const target_block = loc.target_block;
    const offset_in_block = loc.offset_in_block;
    const copy_len = loc.copy_len;

    const inode_bytes: [*]const u8 = @ptrCast(inode);

    // v53.22: Zero-copy path — if inode table block is cached, modify directly
    // (eliminates allocPage/freePage + 2 memcpy per call; ~102K calls for 100MB file)
    if (cacheLookup(target_block)) |idx| {
        if (offset_in_block + copy_len <= block_size) {
            @memcpy(cache[idx].data[offset_in_block .. offset_in_block + copy_len], inode_bytes[0..copy_len]);
            if (batch_free_depth > 0) {
                cache[idx].dirty = true;
            } else {
                if (writeBlockUncached(target_block, &cache[idx].data)) {
                    cache[idx].dirty = false;
                } else {
                    cache[idx].dirty = true;
                }
            }
            return true;
        }
        // Inode straddles block boundary — fall through to allocPage path
    }

    // Fallback: alloc-page-read-modify-write
    const buf_phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    if (!readBlock(target_block, buf)) return false;

    if (offset_in_block + copy_len <= block_size) {
        @memcpy(buf[offset_in_block .. offset_in_block + copy_len], inode_bytes[0..copy_len]);
        if (!writeBlockMaybeBatch(target_block, buf)) return false;
    } else {
        // Inode straddles a block boundary
        const first_part = block_size - offset_in_block;
        @memcpy(buf[offset_in_block .. offset_in_block + first_part], inode_bytes[0..first_part]);
        if (!writeBlockMaybeBatch(target_block, buf)) return false;

        const buf2_phys = pmm.allocPage() orelse return false;
        defer pmm.freePage(buf2_phys);
        const buf2: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf2_phys));
        if (!readBlock(target_block + 1, buf2)) return false;
        @memcpy(buf2[0 .. copy_len - first_part], inode_bytes[first_part..copy_len]);
        if (!writeBlockMaybeBatch(target_block + 1, buf2)) return false;
    }
    return true;
}

/// Allocate a data block from the block bitmap of the given group.
/// Returns block number, or 0 on failure.
fn allocBlock(group: u32, skip_zero: bool) u32 {
    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];

    if (gd.bg_free_blocks_count == 0) return 0;

    const bitmap_block = gd.bg_block_bitmap;
    const total_blocks_in_group = if (group < groups_count - 1) sb.blocks_per_group else sb.blocks_count - group * sb.blocks_per_group;
    const first_block = group * sb.blocks_per_group + first_data_block;

    // v53.20: Zero-copy path — if bitmap block is cached, scan/modify directly
    if (cacheLookup(bitmap_block)) |idx| {
        const words: [*]u64 = @ptrCast(@alignCast(&cache[idx].data));
        const total_bytes = (total_blocks_in_group + 7) / 8;
        const total_words = (total_bytes + 7) / 8;
        var w: u32 = last_alloc_word;
        var scanned: u32 = 0;
        while (scanned < total_words) : (scanned += 1) {
            if (w >= total_words) w = 0;
            const inv = ~words[w];
            if (inv == 0) {
                w += 1;
                continue;
            }
            const bit = @ctz(inv);
            const i = w * 64 + @as(u32, bit);
            if (i >= total_blocks_in_group) {
                w += 1;
                continue;
            }
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(i % 8);
            cache[idx].data[byte_idx] |= @as(u8, 1) << bit_idx;
            // v53.23: Batch mode — defer bitmap write to cacheFlush (matches freeBlock pattern)
            if (batch_free_depth > 0) {
                cache[idx].dirty = true;
            } else {
                if (!writeBlockUncached(bitmap_block, &cache[idx].data)) {
                    // v53.21: Roll back bit — block stays free, matching fallback behavior
                    cache[idx].data[byte_idx] &= ~(@as(u8, 1) << bit_idx);
                    return 0;
                }
                cache[idx].dirty = false;
            }
            gd.bg_free_blocks_count -= 1;
            sb.free_blocks_count -= 1;
            // v53.22: Skip expensive disk flushes during batch operations
            if (batch_free_depth == 0) {
                writeGroupDescs();
                writeSuperblock();
            }
            // v53.21: Static zero buffer — no allocPage/freePage/memset, no cache pollution
            // v53.24: Skip zeroing when caller will overwrite entire block (full-block writes)
            const block_num = first_block + i;
            if (!skip_zero) {
                // v53.52: if the zeroing write fails, the block still holds
                // stale data — refuse to hand it out. The bitmap bit/counters
                // stay set (rolling back would need another write that may
                // fail too), so the block leaks until fsck; that is strictly
                // safer than publishing dirty data.
                if (!writeBlockUncached(block_num, zero_block_buf[0..block_size].ptr)) return 0;
            }
            last_alloc_word = w;
            return block_num;
        }
        return 0;
    }

    // Not cached — fall back to alloc-page-read-modify-write
    const buf_phys = pmm.allocPage() orelse return 0;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    if (!readBlock(bitmap_block, buf)) return 0;

    // Scan bitmap for a free bit (0 = free) using 64-bit word scanning.
    // Inverted word + @ctz skips 64 used blocks per iteration.
    const words: [*]const u64 = @ptrCast(@alignCast(buf));
    const total_bytes = (total_blocks_in_group + 7) / 8;
    const total_words = (total_bytes + 7) / 8;
    var w: u32 = last_alloc_word;
    var scanned: u32 = 0;
    while (scanned < total_words) : (scanned += 1) {
        if (w >= total_words) w = 0;
        const inv = ~words[w]; // flip: 1 = free
        if (inv == 0) {
            w += 1;
            continue;
        } // all 64 blocks used
        const bit = @ctz(inv);
        const i = w * 64 + @as(u32, bit);
        if (i >= total_blocks_in_group) {
            w += 1;
            continue;
        }
        // Found a free block — mark as used
        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(i % 8);
        buf[byte_idx] |= @as(u8, 1) << bit_idx;
        if (!writeBlock(bitmap_block, buf)) return 0;

        // Update group descriptor and superblock free block count
        gd.bg_free_blocks_count -= 1;
        sb.free_blocks_count -= 1;
        // v53.22: Skip expensive disk flushes during batch operations
        if (batch_free_depth == 0) {
            writeGroupDescs();
            writeSuperblock();
        }

        // v53.21: Static zero buffer — no allocPage/freePage/memset, no cache pollution
        // v53.24: Skip zeroing when caller will overwrite entire block (full-block writes)
        const block_num = first_block + i;
        if (!skip_zero) {
            // v53.52: same policy as the zero-copy path above — on a failed
            // zeroing write, leak the block (bitmap stays set) rather than
            // hand out stale data.
            if (!writeBlockUncached(block_num, zero_block_buf[0..block_size].ptr)) return 0;
        }

        last_alloc_word = w;
        return block_num;
    }
    return 0;
}

/// v53.30: Zero-copy indirect block access helper.
/// On cache hit: directly accesses cache[idx].data (0 memcpy, ~337MB saved for 100MB write).
/// On cache miss: reads to provided buffer (readBlock inserts into cache for future calls).
const IndirectRef = struct {
    ptrs: [*]u32,
    cache_idx: ?usize, // non-null = zero-copy cache path
    block_num: u32,
};

fn getIndirectMutable(block_num: u32, is_new: bool, buf: [*]u8) ?IndirectRef {
    if (cacheLookup(block_num)) |idx| {
        return .{ .ptrs = @ptrCast(@alignCast(&cache[idx].data)), .cache_idx = idx, .block_num = block_num };
    }
    if (is_new) {
        @memset(buf[0..block_size], 0);
    } else {
        if (!readBlock(block_num, buf)) return null;
    }
    return .{ .ptrs = @ptrCast(@alignCast(buf)), .cache_idx = null, .block_num = block_num };
}

/// v53.52: returns false when the indirect block could not be persisted.
/// On a cache-path write failure the entry stays dirty so a later cacheFlush
/// can retry; callers treat false as allocation/persistence failure.
fn flushIndirect(ref: IndirectRef) bool {
    if (ref.cache_idx) |idx| {
        if (batch_free_depth > 0) {
            cache[idx].dirty = true;
        } else {
            if (!writeBlockUncached(ref.block_num, &cache[idx].data)) {
                cache[idx].dirty = true; // keep dirty for a later cacheFlush retry
                return false;
            }
            cache[idx].dirty = false;
        }
    } else {
        if (!writeBlockMaybeBatch(ref.block_num, @ptrCast(ref.ptrs))) return false;
    }
    return true;
}

/// v53.30: Re-validate cache reference after a potentially cache-evicting operation
/// (e.g., allocBlock fallback path calls readBlock which may evict cache entries).
/// If the cache entry was evicted, re-reads the block to buf and switches to buffer-backed.
fn revalidateIndirect(ref: *IndirectRef, buf: [*]u8) bool {
    if (ref.cache_idx) |idx| {
        if (!cache[idx].valid or cache[idx].block_num != ref.block_num) {
            if (!readBlock(ref.block_num, buf)) return false;
            ref.* = .{ .ptrs = @ptrCast(@alignCast(buf)), .cache_idx = null, .block_num = ref.block_num };
        }
    }
    return true;
}

/// Ensure `inode.block[root_idx]` holds an indirect root (always zero-filled).
/// Returns `{block, is_new}` or null on allocation failure.
fn ensureIndirectRoot(inode: *Ext2Inode, root_idx: u32) ?struct { block: u32, is_new: bool } {
    if (inode.block[root_idx] != 0) return .{ .block = inode.block[root_idx], .is_new = false };
    // v53.25: indirect block — always zero on disk
    const blk = allocBlock(0, false);
    if (blk == 0) return null;
    inode.block[root_idx] = blk;
    inode.blocks += block_size / 512;
    return .{ .block = blk, .is_new = true };
}

/// Ensure `parent.ptrs[index]` points at a child indirect block (zero-filled).
fn ensureChildIndirect(
    parent: *IndirectRef,
    parent_buf: [*]u8,
    index: u32,
    inode: *Ext2Inode,
) ?struct { block: u32, is_new: bool } {
    if (parent.ptrs[index] != 0) return .{ .block = parent.ptrs[index], .is_new = false };
    const blk = allocBlock(0, false);
    if (blk == 0) return null;
    if (!revalidateIndirect(parent, parent_buf)) return null;
    parent.ptrs[index] = blk;
    inode.blocks += block_size / 512;
    // v53.52: on flush failure the new child pointer may never reach the
    // disk — report failure; the freshly allocated child block leaks until
    // fsck (same policy as allocBlock zeroing failures).
    if (!flushIndirect(parent.*)) return null;
    return .{ .block = blk, .is_new = true };
}

/// Ensure `ref.ptrs[index]` holds a data block (`skip_zero` honoured).
fn ensureDataPtr(
    ref: *IndirectRef,
    buf: [*]u8,
    index: u32,
    inode: *Ext2Inode,
    skip_zero: bool,
) u32 {
    if (ref.ptrs[index] != 0) return ref.ptrs[index];
    const blk = allocBlock(0, skip_zero);
    if (blk == 0) return 0;
    if (!revalidateIndirect(ref, buf)) return 0;
    ref.ptrs[index] = blk;
    inode.blocks += block_size / 512;
    // v53.52: on flush failure the new data pointer may never reach the disk
    // — report failure; the allocated block leaks until fsck (same policy as
    // allocBlock zeroing failures).
    if (!flushIndirect(ref.*)) return 0;
    return blk;
}

/// SK-65: same allocation semantics as before, but addressing comes from
/// `classifyLogicalBlock` (shared with `resolveBlock`) and the repeated
/// ensure-root / ensure-child / ensure-data patterns are factored once.
fn ensureBlock(inode: *Ext2Inode, inode_num: u32, logical_block: u32, skip_zero: bool) u32 {
    const ppb = eu.ptrsPerBlock(block_size);
    switch (eu.classifyLogicalBlock(logical_block, ppb)) {
        .direct => |i| {
            if (inode.block[i] != 0) return inode.block[i];
            const blk = allocBlock(0, skip_zero); // allocate from group 0 for simplicity
            if (blk == 0) return 0;
            inode.block[i] = blk;
            inode.blocks += block_size / 512;
            _ = writeInode(inode_num, inode);
            return blk;
        },
        .single => |i| {
            const root = ensureIndirectRoot(inode, 12) orelse return 0;
            const buf: [*]u8 = &ensure_ind_buf[0];
            var ref = getIndirectMutable(root.block, root.is_new, buf) orelse return 0;
            const result = ensureDataPtr(&ref, buf, i, inode, skip_zero);
            if (result == 0) return 0;
            _ = writeInode(inode_num, inode);
            return result;
        },
        .double => |d| {
            const root = ensureIndirectRoot(inode, 13) orelse return 0;
            const buf: [*]u8 = &ensure_ind_buf[0];
            var dib_ref = getIndirectMutable(root.block, root.is_new, buf) orelse return 0;
            const child = ensureChildIndirect(&dib_ref, buf, d.idx1, inode) orelse return 0;
            const si_buf: [*]u8 = &ensure_ind_buf[1];
            var si_ref = getIndirectMutable(child.block, child.is_new, si_buf) orelse return 0;
            const result = ensureDataPtr(&si_ref, si_buf, d.idx2, inode, skip_zero);
            if (result == 0) return 0;
            _ = writeInode(inode_num, inode);
            return result;
        },
        .triple => |t| {
            const root = ensureIndirectRoot(inode, 14) orelse return 0;
            const tib_buf: [*]u8 = &ensure_ind_buf[0];
            var tib_ref = getIndirectMutable(root.block, root.is_new, tib_buf) orelse return 0;
            const dib = ensureChildIndirect(&tib_ref, tib_buf, t.idx1, inode) orelse return 0;
            const dib_buf: [*]u8 = &ensure_ind_buf[1];
            var dib_ref = getIndirectMutable(dib.block, dib.is_new, dib_buf) orelse return 0;
            const sib = ensureChildIndirect(&dib_ref, dib_buf, t.idx2, inode) orelse return 0;
            const sib_buf: [*]u8 = &ensure_ind_buf[2];
            var sib_ref = getIndirectMutable(sib.block, sib.is_new, sib_buf) orelse return 0;
            const result = ensureDataPtr(&sib_ref, sib_buf, t.idx3, inode, skip_zero);
            if (result == 0) return 0;
            _ = writeInode(inode_num, inode);
            return result;
        },
        .out_of_range => return 0,
    }
}

/// Write data to an ext2 file at the given offset.
/// Returns bytes written, or -1 on error.
pub fn writeFile(file_idx: u32, offset: u32, buf: [*]const u8, count: u32) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -1;
    if (file_idx >= open_count) return -1;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return -1;

    var written: u32 = 0;
    var current_offset = offset;
    // v53.22: Batch mode — defer cacheFlush+writeGroupDescs+writeSuperblock
    batch_free_depth += 1;
    defer {
        batch_free_depth -= 1;
        if (batch_free_depth == 0) {
            cacheFlushUnlocked();
            writeGroupDescs();
            writeSuperblock();
            flushDiscard(); // G5: issue coalesced discards for batched frees
        }
    }
    const page_cache = @import("page_cache.zig");
    const inode_id: u64 = 0x3000_0000_0000_0000 + @as(u64, f.inode_num);

    while (written < count) {
        const logical_block = current_offset / block_size;
        const block_offset = current_offset % block_size;
        const chunk = @min(count - written, block_size - block_offset);

        // v53.24: Skip zeroing new blocks for full-block writes (writeFile overwrites entirely)
        const is_full_block = (block_offset == 0 and chunk == block_size);
        const phys_block = ensureBlock(&f.inode, f.inode_num, logical_block, is_full_block);
        if (phys_block == 0) break;

        if (is_full_block) {
            // v53.29: Direct write from source buffer — eliminates ~100MB intermediate
            // memcpy for 100MB sequential write (buf is kernel buffer in HHDM, DMA-safe).
            // Stop at the first failed block: counting it would report bytes that
            // never reached the disk and let the writeback cache drop them.
            if (!writeBlockUncached(phys_block, buf + written)) break;
        } else {
            // Partial write - need existing block data for read-modify-write
            var block_data: [4096]u8 = undefined;
            // v53.51: copy-out under cache_lock (raw page pointer could be
            // freed by a concurrent eviction before the memcpy).
            // v53.32: Only copy block_size bytes, not full PAGE_SIZE (4096).
            // block_size is typically 1024, saves 3072 bytes per partial write.
            if (!page_cache.copyPage(inode_id, logical_block, 0, &block_data, block_size)) {
                // v53.23: Use readBlockUncached to avoid polluting cache with data blocks
                if (!readBlockUncached(phys_block, &block_data)) break;
            }
            @memcpy(block_data[block_offset .. block_offset + chunk], buf[written .. written + chunk]);
            if (!writeBlockUncached(phys_block, &block_data)) break;
        }

        written += chunk;
        current_offset += chunk;
    }

    if (written == 0) return -1;

    // v53.27: Invalidate page_cache for this inode after write loop.
    // writeBlockUncached already wrote new data to disk synchronously, so any
    // cached entries are stale. One invalidateInode (1 lock) replaces per-block
    // updateIfCached (102K locks for 100MB write). Also fixes SMP TOCTOU race:
    // stale entries inserted by concurrent readFile during the loop are removed.
    page_cache.invalidateInode(inode_id);

    // Update file size if we extended the file. A failed inode write leaves the
    // on-disk size stale, which would strand the data we just wrote, so report
    // it rather than claiming the write completed.
    const new_end = offset + written;
    if (new_end > f.inode.size) {
        f.inode.size = new_end;
        if (!writeInode(f.inode_num, &f.inode)) return -1;
    }

    return @intCast(written);
}

/// H1: write one mmap-owned 4KiB cache page back for a MAP_SHARED mapping,
/// keyed by inode number (the page-cache flush callback has no open slot).
///
/// Unlike writeFile this never invalidates the page cache — the flush loop
/// owns those entries and invalidating mid-flush would drop the inode's other
/// dirty mmap pages — and never grows i_size: bytes past EOF in the last
/// partial page are discarded (Linux semantics). Pages wholly past EOF are a
/// no-op success (they cannot be reached via the fault path's EOF clamp, but
/// be safe).
pub fn writePageByInode(inode_num: u32, page_idx: u64, data: *const [4096]u8) bool {
    const page_cache = @import("page_cache.zig");
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return false;

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return false;

    const base: u64 = page_idx * 4096;
    if (base >= inode.size) return true;
    var end: u64 = base + 4096;
    if (end > inode.size) end = inode.size;

    // Same batching discipline as writeFile: bitmap/group-desc/superblock
    // writes (from ensureBlock allocations in sparse holes) are deferred to
    // the outermost exit.
    batch_free_depth += 1;
    defer {
        batch_free_depth -= 1;
        if (batch_free_depth == 0) {
            cacheFlushUnlocked();
            writeGroupDescs();
            writeSuperblock();
            flushDiscard();
        }
    }

    var off = base;
    while (off < end) {
        const logical_block: u32 = @intCast(off / block_size);
        const block_offset: u32 = @intCast(off % block_size);
        const chunk: u32 = @intCast(@min(end - off, block_size - block_offset));

        // Sparse hole inside the file: allocate (zeroed) so the write lands.
        const phys_block = ensureBlock(&inode, inode_num, logical_block, false);
        if (phys_block == 0) return false;

        const src: [*]const u8 = @ptrCast(data);
        if (chunk == block_size) {
            if (!writeBlockUncached(phys_block, src + (off - base))) return false;
        } else {
            // Partial block (straddles i_size): read-modify-write, persisting
            // only the bytes below EOF.
            var block_data: [4096]u8 = undefined;
            if (!readBlockUncached(phys_block, &block_data)) return false;
            @memcpy(block_data[block_offset .. block_offset + chunk], src[off - base .. off - base + chunk]);
            if (!writeBlockUncached(phys_block, &block_data)) return false;
        }
        // Retire the read-path cache entry for this block: readFile keys the
        // page cache per logical block (unflagged namespace), and a stale
        // entry populated before this writeback would keep serving the old
        // bytes to read()/pread() even though the disk now has the new ones.
        page_cache.invalidatePage(0x3000_0000_0000_0000 + @as(u64, inode_num), logical_block);
        off += chunk;
    }
    return true;
}

// ─── Inode allocation ──────────────────────────────────────────────────────

/// Allocate an inode from the bitmap of the given group.
/// Returns inode number (1-based), or 0 on failure.
fn allocInode(group: u32) u32 {
    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];

    if (gd.bg_free_inodes_count == 0) return 0;

    const bitmap_block = gd.bg_inode_bitmap;

    // v53.40: Zero-copy path — if bitmap block is cached, scan/modify directly
    if (cacheLookup(bitmap_block)) |idx| {
        const total_inodes_in_group = if (group < groups_count - 1) inodes_per_group else sb.inodes_count - group * inodes_per_group;
        const words: [*]u64 = @ptrCast(@alignCast(&cache[idx].data));
        const total_bytes = (total_inodes_in_group + 7) / 8;
        const total_words = (total_bytes + 7) / 8;
        var w: u32 = 0;
        while (w < total_words) : (w += 1) {
            const inv = ~words[w];
            if (inv == 0) continue;
            const bit = @ctz(inv);
            const i = w * 64 + @as(u32, bit);
            if (i >= total_inodes_in_group) break;
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(i % 8);
            cache[idx].data[byte_idx] |= @as(u8, 1) << bit_idx;
            if (batch_free_depth > 0) {
                cache[idx].dirty = true;
            } else {
                if (!writeBlockUncached(bitmap_block, &cache[idx].data)) {
                    cache[idx].data[byte_idx] &= ~(@as(u8, 1) << bit_idx);
                    return 0;
                }
                cache[idx].dirty = false;
            }
            gd.bg_free_inodes_count -= 1;
            sb.free_inodes_count -= 1;
            if (batch_free_depth == 0) {
                writeGroupDescs();
                writeSuperblock();
            }
            return group * inodes_per_group + i + 1;
        }
        return 0;
    }

    // Not cached — fall back to alloc-page-read-modify-write
    const buf_phys = pmm.allocPage() orelse return 0;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    if (!readBlock(bitmap_block, buf)) return 0;

    const total_inodes_in_group = if (group < groups_count - 1) inodes_per_group else sb.inodes_count - group * inodes_per_group;

    // Scan bitmap for a free inode (0 = free) using 64-bit word scanning.
    const words: [*]const u64 = @ptrCast(@alignCast(buf));
    const total_bytes = (total_inodes_in_group + 7) / 8;
    const total_words = (total_bytes + 7) / 8;
    var w: u32 = 0;
    while (w < total_words) : (w += 1) {
        const inv = ~words[w];
        if (inv == 0) continue;
        const bit = @ctz(inv);
        const i = w * 64 + @as(u32, bit);
        if (i >= total_inodes_in_group) break;
        // Found a free inode — mark as used
        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(i % 8);
        buf[byte_idx] |= @as(u8, 1) << bit_idx;
        if (!writeBlock(bitmap_block, buf)) return 0;

        // Update group descriptor
        gd.bg_free_inodes_count -= 1;
        writeGroupDescs();

        // Update superblock
        sb.free_inodes_count -= 1;
        writeSuperblock();

        // Inode numbers are 1-based
        return group * inodes_per_group + i + 1;
    }
    return 0;
}

/// Write group descriptor table back to disk.
fn writeGroupDescs() void {
    const gds: [*]const u8 = @ptrFromInt(group_descs_virt);
    const bgdt_block = first_data_block + 1;
    const bgdt_sectors = ((groups_count * @sizeOf(Ext2GroupDesc)) + SECTOR_SIZE - 1) / SECTOR_SIZE;
    const bgdt_lba = @as(u64, bgdt_block) * (block_size / SECTOR_SIZE);
    _ = virtio_blk.writeSectors(DISK_LBA_OFFSET + bgdt_lba, bgdt_sectors, gds);
}

/// Write superblock back to disk.
fn writeSuperblock() void {
    const sb_lba: u64 = 1024 / SECTOR_SIZE;
    // v53.38: Use DMA-safe io_buf instead of BSS sb_io_buf (Critical fix)
    const dma_buf: [*]u8 = @ptrFromInt(io_buf_virt);
    if (!readSectorsToBuf(sb_lba, 2, dma_buf)) return;
    @memcpy(dma_buf[0..@sizeOf(Ext2Superblock)], @as([*]const u8, @ptrCast(&sb))[0..@sizeOf(Ext2Superblock)]);
    _ = virtio_blk.writeSectors(DISK_LBA_OFFSET + sb_lba, 2, dma_buf);
}

// ─── Create file ────────────────────────────────────────────────────────────

/// Create a new file in the root directory of the ext2 filesystem.
/// Returns file index (>= 0) on success, -1 on failure.
pub fn createFile(name: []const u8) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -1;

    // Check if file already exists — reuse walkPath (known working)
    const existing_idx = walkPath(2, name);
    if (existing_idx >= 0) {
        return existing_idx;
    }

    // Resolve parent directory and filename
    const resolved = resolveParent(name) orelse return -1;
    const parent_inode_num = resolved.parent;
    const filename = resolved.name;

    // Allocate a new inode (from group 0)
    const new_inode_num = allocInode(0);
    if (new_inode_num == 0) return -1;

    // Initialize the new inode as a regular file
    var new_inode: Ext2Inode = undefined;
    @memset(@as([*]u8, @ptrCast(&new_inode))[0..@sizeOf(Ext2Inode)], 0);
    new_inode.mode = 0x81A4; // regular file, 0644 permissions
    new_inode.links_count = 1;
    new_inode.blocks = 0;
    new_inode.size = 0;
    new_inode.block = @splat(0);

    if (!writeInode(new_inode_num, &new_inode)) {
        freeInode(new_inode_num);
        return -1;
    }

    // Add directory entry to parent directory
    if (!addDirEntry(parent_inode_num, new_inode_num, filename, 1)) { // file_type=1 (regular file)
        freeInode(new_inode_num);
        return -1;
    }

    // Open the new file
    for (0..MAX_OPEN_FILES) |i| {
        if (i >= open_count or open_files[i].inode_num == 0) {
            open_files[i] = .{
                .inode_num = new_inode_num,
                .inode = new_inode,
                .offset = 0,
            };
            // v52.0: store path
            const copy_len = @min(name.len, 127);
            @memcpy(open_file_paths[i][0..copy_len], name[0..copy_len]);
            open_file_paths[i][copy_len] = 0;
            if (i >= open_count) open_count = @intCast(i + 1);
            return @intCast(i);
        }
    }
    return -1;
}

/// Add a directory entry to a directory inode.
/// Simple approach: try to split last entry in last block, else allocate new block.
fn addDirEntry(dir_inode_num: u32, target_inode: u32, entry_name: []const u8, file_type: u8) bool {
    // K1 dcache: the directory's contents change here — drop every cached
    // lookup keyed by this directory, and every entry keyed by the child
    // inode as a parent (it may be a directory whose contents are being
    // abandoned, and its inode number can be reused after a later free).
    // Unconditional (even on failure paths): wrong hits are corruption,
    // spurious drops are just a re-scan. Covers createFile/createDir/
    // renameFile/createHardlink/createSymlink, which all add via this.
    defer {
        dcache.invalidateParent(.ext2, dir_inode_num);
        dcache.invalidateParent(.ext2, target_inode);
    }
    var dir_inode: Ext2Inode = undefined;
    if (!readInode(dir_inode_num, &dir_inode)) return false;

    const aligned_len = (@as(u16, @sizeOf(Ext2DirEntry)) + @as(u16, @intCast(entry_name.len)) + 3) & ~@as(u16, 3);

    const buf_phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    // Try to split the last entry in the last block (common fast path)
    const dir_size = dir_inode.size;
    if (dir_size > 0) {
        const last_block = (dir_size - 1) / block_size;
        const phys_block = resolveBlock(&dir_inode, last_block);
        if (phys_block != 0 and readBlock(phys_block, buf)) {
            // Walk to the last entry in this block
            var pos: u32 = 0;
            var last_pos: u32 = 0;
            var last_view: ?eu.DirEntryView = null;
            while (pos < block_size) {
                const view = eu.readDirEntry(buf, pos, block_size) orelse break;
                last_pos = pos;
                last_view = view;
                const next = pos + view.rec_len;
                if (next >= block_size) break;
                pos = next;
            }

            // Check if the last entry has wasted space we can split. `rec_len`
            // is at least the header plus the name (readDirEntry rejects
            // anything smaller), so the subtraction below cannot wrap.
            if (last_view) |last_entry| {
                const actual_len = (@as(u16, @sizeOf(Ext2DirEntry)) + @as(u16, last_entry.name_len) + 3) & ~@as(u16, 3);
                const wasted = if (last_entry.rec_len > actual_len) last_entry.rec_len - actual_len else 0;

                if (wasted >= aligned_len) {
                    // Shrink the last entry
                    const last_hdr: *Ext2DirEntry = @ptrCast(@alignCast(buf + last_pos));
                    last_hdr.rec_len = actual_len;

                    // Create new entry in the freed space
                    const new_pos = last_pos + actual_len;
                    const new_entry: *Ext2DirEntry = @ptrCast(@alignCast(buf + new_pos));
                    new_entry.inode = target_inode;
                    new_entry.rec_len = @intCast(wasted);
                    new_entry.name_len = @intCast(entry_name.len);
                    new_entry.file_type = file_type;
                    @memcpy(buf[new_pos + @sizeOf(Ext2DirEntry) .. new_pos + @sizeOf(Ext2DirEntry) + entry_name.len], entry_name);

                    return writeBlock(phys_block, buf);
                }
            }
        }
    }

    // No space to split — allocate a new block
    const new_block = allocBlock(0, false);
    if (new_block == 0) return false;

    // Add block to directory inode
    const next_logical = dir_size / block_size;
    if (next_logical >= EXT2_INODE_DIRECT) { // only direct blocks for dirs
        freeBlock(new_block);
        return false;
    }
    dir_inode.block[next_logical] = new_block;
    dir_inode.blocks += block_size / 512;
    dir_inode.size += block_size;

    // Write the new entry into the fresh block
    @memset(buf[0..block_size], 0);
    const new_entry: *Ext2DirEntry = @ptrCast(@alignCast(buf));
    new_entry.inode = target_inode;
    new_entry.rec_len = @intCast(block_size); // spans rest of block
    new_entry.name_len = @intCast(entry_name.len);
    new_entry.file_type = file_type;
    @memcpy(buf[@sizeOf(Ext2DirEntry) .. @sizeOf(Ext2DirEntry) + entry_name.len], entry_name);

    if (!writeBlock(new_block, buf)) {
        freeBlock(new_block);
        return false;
    }
    return writeInode(dir_inode_num, &dir_inode);
}

// ─── Directory creation ────────────────────────────────────────────────────

/// Create a new directory in the ext2 filesystem.
/// Supports multi-level paths (e.g., "testdir/subdir").
/// Returns file index (>= 0) on success, 0 if already exists, -1 on failure.
pub fn createDir(name: []const u8) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -1;

    // Check if already exists
    const existing_idx = walkPath(2, name);
    if (existing_idx >= 0) {
        // Already exists — return 0 (idempotent mkdir)
        return 0;
    }

    // Resolve parent directory and directory name
    const resolved = resolveParent(name) orelse return -1;
    const parent_inode_num = resolved.parent;
    const dirname = resolved.name;

    // Allocate a new inode (from group 0)
    const new_inode_num = allocInode(0);
    if (new_inode_num == 0) return -1;

    // Initialize as a directory inode
    var new_inode: Ext2Inode = undefined;
    @memset(@as([*]u8, @ptrCast(&new_inode))[0..@sizeOf(Ext2Inode)], 0);
    new_inode.mode = 0x41FF; // directory, 0777 permissions
    new_inode.links_count = 2; // "." + parent's entry
    new_inode.blocks = 0;
    new_inode.size = 0;
    new_inode.block = @splat(0);

    // Allocate a data block for the directory entries (. and ..)
    const dir_block = allocBlock(0, false);
    if (dir_block == 0) return -1;

    new_inode.block[0] = dir_block;
    new_inode.blocks = block_size / 512;
    new_inode.size = block_size;

    // Write "." and ".." entries into the new directory block
    const buf_phys = pmm.allocPage() orelse return -1;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
    @memset(buf[0..block_size], 0);

    // "." entry: inode=this, rec_len=12, name_len=1, type=2 (dir)
    const dot: *Ext2DirEntry = @ptrCast(@alignCast(buf));
    dot.inode = new_inode_num;
    dot.rec_len = 12;
    dot.name_len = 1;
    dot.file_type = 2;
    buf[@sizeOf(Ext2DirEntry)] = '.';

    // ".." entry: inode=parent, rec_len=rest of block, name_len=2, type=2
    const dotdot: *Ext2DirEntry = @ptrCast(@alignCast(buf + 12));
    dotdot.inode = parent_inode_num;
    dotdot.rec_len = @intCast(block_size - 12);
    dotdot.name_len = 2;
    dotdot.file_type = 2;
    buf[12 + @sizeOf(Ext2DirEntry)] = '.';
    buf[12 + @sizeOf(Ext2DirEntry) + 1] = '.';

    if (!writeBlock(dir_block, buf)) return -1;

    // Write the new inode
    if (!writeInode(new_inode_num, &new_inode)) return -1;

    // Add entry to parent directory
    if (!addDirEntry(parent_inode_num, new_inode_num, dirname, 2)) return -1; // file_type=2 (dir)

    // Increment parent links count (for ".." pointing to parent)
    var parent_inode: Ext2Inode = undefined;
    if (readInode(parent_inode_num, &parent_inode)) {
        parent_inode.links_count += 1;
        _ = writeInode(parent_inode_num, &parent_inode);
    }

    // Open the new directory (as a file-like handle)
    for (0..MAX_OPEN_FILES) |i| {
        if (i >= open_count or open_files[i].inode_num == 0) {
            open_files[i] = .{
                .inode_num = new_inode_num,
                .inode = new_inode,
                .offset = 0,
            };
            // v52.0: store path
            const copy_len = @min(name.len, 127);
            @memcpy(open_file_paths[i][0..copy_len], name[0..copy_len]);
            open_file_paths[i][copy_len] = 0;
            if (i >= open_count) open_count = @intCast(i + 1);
            return @intCast(i);
        }
    }
    return -1;
}

// ─── Block / inode deallocation ────────────────────────────────────────────

/// Mark a data block as free in the bitmap.
/// v53.15: When batch_free_depth > 0, uses writeBlockBatch (cache-only dirty) and
/// skips writeGroupDescs/writeSuperblock. Caller must cacheFlush+writeGroupDescs+writeSuperblock.
fn freeBlock(block_num: u32) void {
    // v53.22: Invalidate cache entry for freed data block
    // (prevents stale data when block is reallocated + frees cache slot for reuse)
    if (cacheLookup(block_num)) |cidx| {
        cacheHashRemove(cidx);
        cache[cidx].valid = false;
    }
    const group = groupForBlock(block_num) orelse return;
    const index = (block_num - first_data_block) % sb.blocks_per_group;

    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];
    const bitmap_block = gd.bg_block_bitmap;

    const byte_idx = index / 8;
    const bit_idx: u3 = @intCast(index % 8);

    // v53.19: Zero-copy path — if bitmap block is cached, modify directly in cache
    // (eliminates allocPage/freePage + 2 memcpy per call; ~25K calls for 100MB file)
    if (cacheLookup(bitmap_block)) |idx| {
        cache[idx].data[byte_idx] &= ~(@as(u8, 1) << bit_idx);
        if (batch_free_depth > 0) {
            cache[idx].dirty = true;
        } else {
            if (writeBlockUncached(bitmap_block, &cache[idx].data)) {
                cache[idx].dirty = false;
            } else {
                // v53.20: Writeback failed — mark dirty for retry + return early
                // to avoid incrementing counters when bitmap write failed
                cache[idx].dirty = true;
                return;
            }
        }
    } else {
        // Not cached — fall back to alloc-page-read-modify-write
        const buf_phys = pmm.allocPage() orelse return;
        defer pmm.freePage(buf_phys);
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

        if (!readBlock(bitmap_block, buf)) return;
        buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);

        if (batch_free_depth > 0) {
            if (!writeBlockBatch(bitmap_block, buf)) return;
        } else {
            if (!writeBlock(bitmap_block, buf)) return;
        }
    }

    gd.bg_free_blocks_count += 1;
    sb.free_blocks_count += 1;

    noteFreedBlock(block_num); // G5: batch a discard extent for the freed block

    // v53.15: Skip expensive disk flushes during batch operations (caller flushes at end)
    if (batch_free_depth == 0) {
        writeGroupDescs();
        writeSuperblock();
    }
}

/// Mark an inode as free in the bitmap.
fn freeInode(inode_num: u32) void {
    const group = groupForInode(inode_num) orelse return;
    const index = (inode_num - 1) % inodes_per_group;

    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];
    const bitmap_block = gd.bg_inode_bitmap;

    const byte_idx = index / 8;
    const bit_idx: u3 = @intCast(index % 8);

    // v53.19: Zero-copy path — if bitmap block is cached, modify directly in cache
    if (cacheLookup(bitmap_block)) |idx| {
        cache[idx].data[byte_idx] &= ~(@as(u8, 1) << bit_idx);
        if (batch_free_depth > 0) {
            cache[idx].dirty = true;
        } else {
            if (writeBlockUncached(bitmap_block, &cache[idx].data)) {
                cache[idx].dirty = false;
            } else {
                // v53.20: Writeback failed — mark dirty for retry + return early
                cache[idx].dirty = true;
                return;
            }
        }
    } else {
        // Not cached — fall back to alloc-page-read-modify-write
        const buf_phys = pmm.allocPage() orelse return;
        defer pmm.freePage(buf_phys);
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

        if (!readBlock(bitmap_block, buf)) return;
        buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);

        if (batch_free_depth > 0) {
            if (!writeBlockBatch(bitmap_block, buf)) return;
        } else {
            if (!writeBlock(bitmap_block, buf)) return;
        }
    }

    gd.bg_free_inodes_count += 1;
    sb.free_inodes_count += 1;

    // v53.16: Skip flushes during batch operations (caller flushes at end)
    if (batch_free_depth == 0) {
        writeGroupDescs();
        writeSuperblock();
    }
}

// ─── Directory entry removal ───────────────────────────────────────────────

/// Remove a named entry from a parent directory.
/// Merges the deleted entry's rec_len into the previous entry if possible.
fn removeDirEntry(parent_inode_num: u32, name: []const u8) bool {
    // K1 dcache: unconditional invalidation of the parent directory's cached
    // lookups (conservative — also on failure paths), plus the removed child's
    // inode as a parent once known (it may be a directory being abandoned).
    // Covers unlinkFile and renameFile, which both remove via this.
    var removed_inode: u32 = 0;
    defer {
        dcache.invalidateParent(.ext2, parent_inode_num);
        if (removed_inode != 0) dcache.invalidateParent(.ext2, removed_inode);
    }
    var parent_inode: Ext2Inode = undefined;
    if (!readInode(parent_inode_num, &parent_inode)) return false;

    const dir_size = parent_inode.size;
    var offset: u32 = 0;

    const buf_phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    while (offset < dir_size) {
        const block_num = offset / block_size;
        const phys_block = resolveBlock(&parent_inode, block_num);

        if (phys_block == 0) {
            offset += block_size;
            continue;
        }
        if (!readBlock(phys_block, buf)) return false;

        var pos: u32 = 0;
        var prev_pos: u32 = 0xFFFF_FFFF; // sentinel: no previous entry

        while (pos < block_size and offset + pos < dir_size) {
            // Validate before the struct cast: `readDirEntry` establishes both
            // 4-alignment and that the record lies inside the block.
            const view = eu.readDirEntry(buf, pos, block_size) orelse break;

            if (view.inode != 0 and view.name_len == name.len) {
                const entry_name = buf[view.name_pos .. view.name_pos + name.len];
                var match = true;
                for (name, 0..) |c, j| {
                    if (entry_name[j] != c) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    removed_inode = view.inode; // K1: invalidate child-as-parent too
                    // Found — remove by merging with previous or zeroing inode
                    if (prev_pos != 0xFFFF_FFFF) {
                        const prev: *Ext2DirEntry = @ptrCast(@alignCast(buf + prev_pos));
                        prev.rec_len += view.rec_len;
                    } else {
                        // First entry in block — just zero inode
                        const entry: *Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
                        entry.inode = 0;
                    }

                    if (!writeBlock(phys_block, buf)) return false;
                    return true;
                }
            }

            prev_pos = pos;
            pos += view.rec_len;
        }
        offset += block_size;
    }

    return false; // not found
}

// ─── File unlink ────────────────────────────────────────────────────────────

/// Unlink (delete) a file from the ext2 filesystem.
/// Supports multi-level paths, hardlinks, and symlinks (v50.0).
pub fn unlinkFile(path: []const u8) bool {
    var flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return false;

    // Resolve parent directory and filename
    const resolved = resolveParent(path) orelse return false;
    const parent_inode_num = resolved.parent;
    const filename = resolved.name;

    // Find the file's inode number via findDirEntry on parent
    var parent_inode: Ext2Inode = undefined;
    if (!readInode(parent_inode_num, &parent_inode)) return false;
    const file_inode_num = findDirEntryCached(parent_inode_num, &parent_inode, filename) orelse return false;

    // Read file inode
    var file_inode: Ext2Inode = undefined;
    if (!readInode(file_inode_num, &file_inode)) return false;

    const is_symlink = (eu.isSymlink(file_inode.mode));

    // v50.0: decrement links_count for hardlinked files
    if (file_inode.links_count > 1) {
        file_inode.links_count -= 1;
        _ = writeInode(file_inode_num, &file_inode);
    } else {
        // Last link: free data blocks
        // v53.51: flush+drop staged writeback extents BEFORE the inode's blocks
        // are freed — a later flush would write into a freed inode.
        invalidateWriteback(file_inode_num, &flags);
        // v53.15: Batch mode — defer cacheFlush+writeGroupDescs+writeSuperblock
        batch_free_depth += 1;
        defer {
            batch_free_depth -= 1;
            if (batch_free_depth == 0) {
                cacheFlushUnlocked();
                writeGroupDescs();
                writeSuperblock();
                flushDiscard(); // G5: issue coalesced discards for batched frees
            }
        }
        // v53.5: invalidate page cache before freeing blocks
        const page_cache = @import("page_cache.zig");
        page_cache.invalidateInode(0x3000_0000_0000_0000 + @as(u64, file_inode_num));

        if (is_symlink and file_inode.blocks == 0) {
            // Short symlink: target inline in i_block, no data blocks to free
        } else if (is_symlink) {
            // Long symlink: only block[0] is used
            if (file_inode.block[0] != 0) {
                freeBlock(file_inode.block[0]);
            }
        } else {
            // Regular file: free direct blocks (0-11)
            for (0..EXT2_INODE_DIRECT) |i| {
                if (file_inode.block[i] != 0) {
                    freeBlock(file_inode.block[i]);
                }
            }

            // v53.18: Use helper functions instead of inlined code — fixes orelse break
            // silent space leak on OOM (helper functions use orelse return false)
            const ptrs_per_block = block_size / 4;
            if (file_inode.block[12] != 0) {
                if (!freeSingleIndirectTree(file_inode.block[12], ptrs_per_block)) return false;
            }

            // Free double indirect block (block[13]) and all blocks it points to
            if (file_inode.block[13] != 0) {
                if (!freeDoubleIndirectTree(file_inode.block[13], ptrs_per_block)) return false;
            }

            // v53.5: Free triple indirect block (block[14]) and all blocks it points to
            if (file_inode.block[14] != 0) {
                if (!freeTripleIndirectTree(file_inode.block[14], ptrs_per_block)) return false;
            }
        }

        // Free the inode
        freeInode(file_inode_num);
    }

    // Remove directory entry from parent
    if (!removeDirEntry(parent_inode_num, filename)) return false;

    serial.writeString("[ext2] unlinked: ");
    serial.writeString(filename);
    serial.writeString("\n");
    return true;
}

// ─── Hard link creation ────────────────────────────────────────────────────

/// Create a hard link: newpath → same inode as oldpath.
/// Returns 0 on success, -errno on failure.
pub fn createHardlink(oldpath: []const u8, newpath: []const u8) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5; // EIO

    // 1. Resolve oldpath to its inode number (v52.1: use symlink-resolving version)
    const old_inode = walkPathToInodeUnlocked(oldpath) orelse return -2; // ENOENT

    // Read the old inode to check it's not a directory
    var old_inode_data: Ext2Inode = undefined;
    if (!readInode(old_inode, &old_inode_data)) return -5;

    if (eu.isDirectory(old_inode_data.mode)) return -1; // EPERM: cannot hardlink directories

    // 2. Resolve newpath's parent directory + filename
    const resolved = resolveParent(newpath) orelse return -2;
    if (resolved.name.len == 0) return -2;

    // Check that newpath doesn't already exist
    var parent_check: Ext2Inode = undefined;
    if (readInode(resolved.parent, &parent_check)) {
        if (findDirEntryCached(resolved.parent, &parent_check, resolved.name) != null) return -17; // EEXIST
    }

    // 3. Add directory entry pointing to old_inode with same file_type
    const ft: u8 = if (eu.isDirectory(old_inode_data.mode)) 2 else 1;
    if (!addDirEntry(resolved.parent, old_inode, resolved.name, ft)) return -28; // ENOSPC

    // 4. Increment links_count
    old_inode_data.links_count +|= 1;
    _ = writeInode(old_inode, &old_inode_data);

    return 0;
}

// ─── Symbolic link creation ────────────────────────────────────────────────

/// Create a symbolic link: linkpath → target.
/// Returns 0 on success, -errno on failure.
pub fn createSymlink(target: []const u8, linkpath: []const u8) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;

    // 1. Resolve linkpath's parent directory + filename
    const resolved = resolveParent(linkpath) orelse return -2;
    if (resolved.name.len == 0) return -2;

    // Check that linkpath doesn't already exist
    var parent_check: Ext2Inode = undefined;
    if (readInode(resolved.parent, &parent_check)) {
        if (findDirEntryCached(resolved.parent, &parent_check, resolved.name) != null) return -17; // EEXIST
    }

    // 2. Allocate a new inode for the symlink
    const new_inode_num = allocInode(0);
    if (new_inode_num == 0) return -28; // ENOSPC

    var new_inode: Ext2Inode = undefined;
    // Zero the inode first
    const inode_bytes: [*]u8 = @ptrCast(&new_inode);
    @memset(inode_bytes[0..@sizeOf(Ext2Inode)], 0);
    // ext2 stores mode as u16 with permission bits; symlink = 0xA000
    new_inode.mode = 0xA1FF; // S_IFLNK | 0777
    new_inode.size = @intCast(target.len);
    new_inode.links_count = 1;

    // For short symlinks (≤ 60 bytes), store target inline in i_block
    if (target.len <= EXT2_INODE_DIRECT * 4) { // 12 * 4 = 48 bytes, but ext2 allows up to 60
        const block_bytes: [*]u8 = @ptrCast(&new_inode.block);
        @memcpy(block_bytes[0..target.len], target);
        new_inode.blocks = 0;
    } else {
        // Long symlink: allocate a data block and store target there
        const data_block = allocBlock(0, false);
        if (data_block == 0) return -28;
        const buf_phys = pmm.allocPage() orelse return -12;
        defer pmm.freePage(buf_phys);
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
        @memset(buf[0..block_size], 0);
        @memcpy(buf[0..target.len], target);
        if (!writeBlock(data_block, buf)) return -5;
        new_inode.block[0] = data_block;
        new_inode.blocks = @intCast(block_size / 512);
    }

    // 3. Write the new inode
    if (!writeInode(new_inode_num, &new_inode)) return -5;

    // 4. Add directory entry: file_type = 7 (EXT2_FT_SYMLINK)
    if (!addDirEntry(resolved.parent, new_inode_num, resolved.name, 7)) return -28;

    return 0;
}

/// Resolve a path to its inode number (public for xattr/chown/chmod dispatch).
/// Resolves symlinks in intermediate path components (v52.2 fix: no fd allocation).
pub fn walkPathToInodePublic(path: []const u8) ?u32 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    return walkPathToInodeUnlocked(path);
}

/// Lock-free walkPathToInodePublic for callers that already hold fs_lock.
fn walkPathToInodeUnlocked(path: []const u8) ?u32 {
    return walkPathToInodeResolve(2, path, 0);
}

/// Resolve a path to its inode number WITHOUT following the final component symlink.
/// Used by lchown, lstat, etc. Intermediate symlinks ARE resolved.
pub fn walkPathToInodeNoFollow(path: []const u8) ?u32 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    return walkPathToInodeNoFollowUnlocked(path);
}

/// Lock-free walkPathToInodeNoFollow for callers that already hold fs_lock.
fn walkPathToInodeNoFollowUnlocked(path: []const u8) ?u32 {
    return walkPathToInodeResolveNoFollow(2, path, 0);
}

/// Like walkPathToInodeResolve, but the final component is NOT followed if symlink.
fn walkPathToInodeResolveNoFollow(start_inode: u32, path: []const u8, depth: u32) ?u32 {
    if (depth > 8) return null;

    var current_inode = start_inode;
    var pos: u32 = 0;

    while (pos < path.len) {
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos >= path.len) break;

        const start = pos;
        while (pos < path.len and path[pos] != '/') pos += 1;
        const component = path[start..pos];
        const is_last = (pos >= path.len);

        var inode: Ext2Inode = undefined;
        if (!readInode(current_inode, &inode)) return null;
        if (!eu.isDirectory(inode.mode)) return null;

        const found = findDirEntryCached(current_inode, &inode, component) orelse return null;

        // Check if symlink — resolve for intermediate, but NOT for final component
        var found_inode: Ext2Inode = undefined;
        if (readInode(found, &found_inode) and eu.isSymlink(found_inode.mode)) {
            if (is_last) {
                // lchown/lstat: return the symlink inode itself
                return found;
            }
            const target = readSymlinkTarget(&found_inode) orelse return null;
            const new_start: u32 = if (target.len > 0 and target[0] == '/') 2 else current_inode;
            const resolved = walkPathToInodeResolveNoFollow(new_start, target, depth + 1) orelse return null;
            current_inode = resolved;
        } else {
            current_inode = found;
        }
    }

    return current_inode;
}

/// Walk path to inode with symlink resolution, without allocating fd slots.
/// Returns inode number or null on failure.
fn walkPathToInodeResolve(start_inode: u32, path: []const u8, depth: u32) ?u32 {
    if (depth > 8) return null; // ELOOP equivalent

    var current_inode = start_inode;
    var pos: u32 = 0;

    while (pos < path.len) {
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos >= path.len) break;

        const start = pos;
        while (pos < path.len and path[pos] != '/') pos += 1;
        const component = path[start..pos];

        var inode: Ext2Inode = undefined;
        if (!readInode(current_inode, &inode)) return null;
        if (!eu.isDirectory(inode.mode)) return null; // not a directory

        const found = findDirEntryCached(current_inode, &inode, component) orelse return null;

        // Check if symlink
        var found_inode: Ext2Inode = undefined;
        if (readInode(found, &found_inode) and eu.isSymlink(found_inode.mode)) {
            const target = readSymlinkTarget(&found_inode) orelse return null;
            const new_start: u32 = if (target.len > 0 and target[0] == '/') 2 else current_inode;
            const resolved = walkPathToInodeResolve(new_start, target, depth + 1) orelse return null;
            current_inode = resolved;
        } else {
            current_inode = found;
        }
    }

    return current_inode;
}

// ─── Public symlink target read (v50.0) ────────────────────────────────────

/// Read symlink target by path. Returns target slice or null.
/// Uses static symlink_buf for long symlinks (caller must copy before next call).
pub fn readSymlinkByPath(path: []const u8) ?[]const u8 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return null;

    // Resolve parent and find the entry
    const resolved = resolveParent(path) orelse return null;
    var parent_inode: Ext2Inode = undefined;
    if (!readInode(resolved.parent, &parent_inode)) return null;
    const entry_inode_num = findDirEntryCached(resolved.parent, &parent_inode, resolved.name) orelse return null;

    // Read the entry's inode and check it's a symlink
    var entry_inode: Ext2Inode = undefined;
    if (!readInode(entry_inode_num, &entry_inode)) return null;
    if (!eu.isSymlink(entry_inode.mode)) return null; // not a symlink

    return readSymlinkTarget(&entry_inode);
}

// ─── chown/chmod inode persistence (v51.0) ─────────────────────────────────

/// Set owner (uid/gid) for a path. Returns 0 on success, -errno on failure.
/// Pass -1 (0xFFFF) to leave uid or gid unchanged.
pub fn setOwner(path: []const u8, uid: u16, gid: u16) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5; // EIO

    const inode_num = walkPathToInodeUnlocked(path) orelse return -2; // ENOENT
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    if (uid != 0xFFFF) inode.uid = uid;
    if (gid != 0xFFFF) inode.gid = gid;
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Set owner without following final symlink (for lchown).
pub fn setOwnerNoFollow(path: []const u8, uid: u16, gid: u16) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;

    const inode_num = walkPathToInodeNoFollowUnlocked(path) orelse return -2;
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    if (uid != 0xFFFF) inode.uid = uid;
    if (gid != 0xFFFF) inode.gid = gid;
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Set owner (uid/gid) for an inode by number. Used by fchown via fd→inode mapping.
pub fn setOwnerByInode(inode_num: u32, uid: u16, gid: u16) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    if (uid != 0xFFFF) inode.uid = uid;
    if (gid != 0xFFFF) inode.gid = gid;
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Set permission mode for a path. Returns 0 on success, -errno on failure.
/// mode is the lower 12 bits (file type preserved).
pub fn setMode(path: []const u8, new_mode: u16) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;

    const inode_num = walkPathToInodeUnlocked(path) orelse return -2;
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    // Preserve file type bits (upper 4), replace permission bits (lower 12)
    inode.mode = (inode.mode & 0xF000) | (new_mode & 0x0FFF);
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Set permission mode for an inode by number. Used by fchmod via fd→inode mapping.
pub fn setModeByInode(inode_num: u32, new_mode: u16) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    inode.mode = (inode.mode & 0xF000) | (new_mode & 0x0FFF);
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Get inode number from an open ext2 file index.
pub fn getInodeNumFromOpen(file_idx: u32) u32 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= MAX_OPEN_FILES) return 0;
    return open_files[file_idx].inode_num;
}

// ─── Extended Attributes (xattr) (v52.0) ───────────────────────────────────

const EXT2_XATTR_MAGIC: u32 = 0xEA020000;
const XATTR_USER_PREFIX: u8 = 1; // "user." namespace

const Ext2XattrHeader = extern struct {
    h_magic: u32,
    h_refcount: u32,
    h_blocks: u32,
    h_hash: u32,
    h_reserved: [4]u32,
};

const Ext2XattrEntry = extern struct {
    e_name_len: u8,
    e_name_index: u8,
    e_value_offs: u16,
    e_value_block: u32,
    e_value_size: u32,
    e_hash: u32,
    // e_name follows (e_name_len bytes, NOT null-terminated in struct)
};

/// Set extended attribute on an inode.
/// Returns 0 on success, -errno on failure.
/// Uses standard ext2 xattr layout: entries grow forward from header,
/// values grow backward from end of block (v52.3 fix).
pub fn setXattr(inode_num: u32, name: []const u8, value: []const u8) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;
    if (name.len == 0 or name.len > 255 or value.len > block_size) return -22;

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    // If inode has no EA block yet, allocate one
    var ea_block: u32 = inode.file_acl;
    if (ea_block == 0) {
        // v52.6: allocate memory page BEFORE disk block to avoid leaking on OOM
        const init_phys = pmm.allocPage() orelse return -12;
        const init_buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(init_phys));
        const group = (inode_num - 1) / inodes_per_group;
        ea_block = allocBlock(group, false);
        if (ea_block == 0) {
            pmm.freePage(init_phys);
            return -28;
        }
        // Initialize EA block with header
        @memset(init_buf[0..block_size], 0);
        const init_hdr: *Ext2XattrHeader = @ptrCast(@alignCast(init_buf));
        init_hdr.h_magic = EXT2_XATTR_MAGIC;
        init_hdr.h_refcount = 1;
        init_hdr.h_blocks = 1;
        if (!writeBlock(ea_block, init_buf)) {
            pmm.freePage(init_phys);
            // Roll back: free the allocated disk block
            inode.file_acl = 0;
            freeBlock(ea_block);
            return -5;
        }
        pmm.freePage(init_phys);
        // Only write inode AFTER EA block is successfully initialized
        inode.file_acl = ea_block;
        if (!writeInode(inode_num, &inode)) {
            freeBlock(ea_block); // v52.7: rollback disk block on writeInode failure
            return -5;
        }
    }

    // Read existing EA block
    const phys = pmm.allocPage() orelse return -12;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(ea_block, buf)) return -5;

    const hdr: *Ext2XattrHeader = @ptrCast(@alignCast(buf));
    if (hdr.h_magic != EXT2_XATTR_MAGIC) return -5;

    // Find end of entries area and search for existing entry
    var entry_off: usize = @sizeOf(Ext2XattrHeader);
    var entries_end: usize = @sizeOf(Ext2XattrHeader);
    var found_off: usize = 0;
    while (entry_off < block_size) {
        if (buf[entry_off] == 0 and buf[entry_off + 1] == 0) break;
        const entry: *Ext2XattrEntry = @ptrCast(@alignCast(buf + entry_off));
        if (entry.e_name_len == 0) break;
        // Skip tombstones — but don't match them as existing
        if (entry.e_name_index == 0) {
            const esz = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
            entry_off = (entry_off + esz + 3) & ~@as(usize, 3);
            entries_end = entry_off;
            continue;
        }
        const ename = buf[entry_off + @sizeOf(Ext2XattrEntry) ..][0..entry.e_name_len];
        if (entry.e_name_index == XATTR_USER_PREFIX and eql(ename, name)) {
            found_off = entry_off;
            // Don't break — continue scanning to find entries_end
        }
        const esz = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
        entry_off = (entry_off + esz + 3) & ~@as(usize, 3);
        entries_end = entry_off;
    }

    // Compute min value offset (lowest value position in the block)
    // Values grow backward from block_size, so the first value starts at block_size - size
    var min_value_off: usize = block_size;
    entry_off = @sizeOf(Ext2XattrHeader);
    while (entry_off < entries_end) {
        if (buf[entry_off] == 0 and buf[entry_off + 1] == 0) break;
        const entry: *Ext2XattrEntry = @ptrCast(@alignCast(buf + entry_off));
        if (entry.e_name_len == 0) break;
        // Skip tombstones
        if (entry.e_name_index == 0) {
            const esz = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
            entry_off = (entry_off + esz + 3) & ~@as(usize, 3);
            continue;
        }
        if (entry.e_value_offs > 0 and entry.e_value_offs < min_value_off) {
            min_value_off = entry.e_value_offs;
        }
        const esz = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
        entry_off = (entry_off + esz + 3) & ~@as(usize, 3);
    }

    if (found_off != 0) {
        // Existing entry — update value in-place
        const found_entry: *Ext2XattrEntry = @ptrCast(@alignCast(buf + found_off));
        const old_val_off: usize = found_entry.e_value_offs;
        const old_val_size = found_entry.e_value_size;

        // Bounds check (e_value_offs=0 means flag-only, allow upgrade)
        if (old_val_off > 0 and old_val_off + old_val_size > block_size) return -5;

        if (old_val_off == 0) {
            // Flag-only attribute upgrading to valued — allocate value space
            if (value.len > 0) {
                const aligned_val_size = (value.len + 3) & ~@as(usize, 3);
                if (entries_end + aligned_val_size > min_value_off) return -28;
                const new_val_off2 = min_value_off - aligned_val_size;
                found_entry.e_value_offs = @intCast(new_val_off2);
                found_entry.e_value_size = @intCast(value.len);
                @memcpy(buf[new_val_off2..][0..value.len], value);
                if (!writeBlock(ea_block, buf)) return -5;
                return 0;
            }
            // Both old and new are empty — no change needed
            return 0;
        }

        if (value.len <= old_val_size) {
            // New value fits within old value space — write in-place
            found_entry.e_value_size = @intCast(value.len);
            if (value.len == 0) {
                // Valued → flag-only downgrade: release old value space
                found_entry.e_value_offs = 0;
                @memset(buf[old_val_off..][0..old_val_size], 0);
            } else {
                @memcpy(buf[old_val_off..][0..value.len], value);
            }
            if (!writeBlock(ea_block, buf)) return -5;
            return 0;
        }
        // New value is larger — check if there's space between entries and values
        const aligned_val_size = (value.len + 3) & ~@as(usize, 3);
        if (entries_end + aligned_val_size > min_value_off) return -28; // ENOSPC
        // Write new value at min_value_off - aligned_val_size (growing backward, 4-byte aligned)
        const new_val_off = min_value_off - aligned_val_size;
        found_entry.e_value_offs = @intCast(new_val_off);
        found_entry.e_value_size = @intCast(value.len);
        @memcpy(buf[new_val_off..][0..value.len], value);
        // Clear old value area
        @memset(buf[old_val_off..][0..old_val_size], 0);
        if (!writeBlock(ea_block, buf)) return -5;
        return 0;
    }

    // New attribute — check space, try tombstone reuse first
    const new_entry_size = (@sizeOf(Ext2XattrEntry) + name.len + 3) & ~@as(usize, 3);
    const new_val_aligned = if (value.len > 0) (value.len + 3) & ~@as(usize, 3) else 0;
    const new_val_off = if (value.len > 0) min_value_off - new_val_aligned else 0;

    // v52.8: Scan for reusable tombstone slot — best-fit with safe leftover
    // Only reuse when leftover == 0 (exact fit) or >= Ext2XattrEntry (can create
    // mini-tombstone). Leftover of 4/8/12 bytes creates zero dead-zone that
    // terminates the scanner, making subsequent entries invisible.
    var reuse_off: usize = 0;
    var reuse_tombstone_sz: usize = 0; // size of the tombstone at reuse_off
    {
        var scan_off: usize = @sizeOf(Ext2XattrHeader);
        while (scan_off < entries_end) {
            if (buf[scan_off] == 0 and buf[scan_off + 1] == 0) break;
            const te: *Ext2XattrEntry = @ptrCast(@alignCast(buf + scan_off));
            if (te.e_name_len == 0) break;
            if (te.e_name_index == 0) { // tombstone
                const tombstone_sz = (@sizeOf(Ext2XattrEntry) + te.e_name_len + 3) & ~@as(usize, 3);
                if (tombstone_sz >= new_entry_size) {
                    const leftover = tombstone_sz - new_entry_size;
                    // v52.9: leftover must be 0 (exact) or > Ext2XattrEntry (>=20)
                    // leftover==16 would make e_name_len=0, which is the
                    // entry termination marker — same dead-zone bug
                    if (leftover == 0 or leftover > @sizeOf(Ext2XattrEntry)) {
                        // Best-fit: prefer smallest tombstone that fits safely
                        if (reuse_off == 0 or tombstone_sz < reuse_tombstone_sz) {
                            reuse_off = scan_off;
                            reuse_tombstone_sz = tombstone_sz;
                        }
                    }
                }
            }
            const esz = (@sizeOf(Ext2XattrEntry) + te.e_name_len + 3) & ~@as(usize, 3);
            scan_off += esz;
        }
    }

    // Check space: if no tombstone reuse, need room at entries_end
    if (reuse_off == 0) {
        if (entries_end + new_entry_size > min_value_off) return -28; // ENOSPC
    }
    // v52.6: When tombstone reuse, entry goes inside entries_end, so only check value space
    if (value.len > 0) {
        const effective_end = if (reuse_off != 0) entries_end else entries_end + new_entry_size;
        if (effective_end > new_val_off) return -28;
    }

    // Write value at new_val_off (from end of block, growing backward)
    if (value.len > 0) {
        @memcpy(buf[new_val_off..][0..value.len], value);
    }

    // Write entry at reuse_off (tombstone) or entries_end (append)
    const write_off = if (reuse_off != 0) reuse_off else entries_end;
    const new_entry: *Ext2XattrEntry = @ptrCast(@alignCast(buf + write_off));
    new_entry.e_name_len = @intCast(name.len);
    new_entry.e_name_index = XATTR_USER_PREFIX;
    new_entry.e_value_offs = if (value.len > 0) @intCast(new_val_off) else 0;
    new_entry.e_value_block = 0;
    new_entry.e_value_size = @intCast(value.len);
    new_entry.e_hash = 0;
    @memcpy(buf[write_off + @sizeOf(Ext2XattrEntry) ..][0..name.len], name);

    // v52.8: If tombstone was larger than new entry, fill leftover with mini-tombstone
    // v52.9: (leftover is guaranteed > Ext2XattrEntry by the best-fit filter above)
    if (reuse_off != 0 and reuse_tombstone_sz > new_entry_size) {
        const leftover_off = write_off + new_entry_size;
        const leftover_sz = reuse_tombstone_sz - new_entry_size;
        // leftover_sz >= @sizeOf(Ext2XattrEntry) is guaranteed by best-fit filter
        const leftover: *Ext2XattrEntry = @ptrCast(@alignCast(buf + leftover_off));
        const leftover_name_len: u8 = @intCast(leftover_sz - @sizeOf(Ext2XattrEntry));
        leftover.e_name_len = leftover_name_len;
        leftover.e_name_index = 0; // tombstone marker
        leftover.e_value_offs = 0;
        leftover.e_value_block = 0;
        leftover.e_value_size = 0;
        leftover.e_hash = 0;
        @memset(buf[leftover_off + @sizeOf(Ext2XattrEntry) ..][0..leftover_name_len], 0);
    }

    // Write back EA block
    if (!writeBlock(ea_block, buf)) return -5;
    return 0;
}

/// Get extended attribute value from an inode.
/// Returns bytes written to value_buf, or -errno.
pub fn getXattr(inode_num: u32, name: []const u8, value_buf: [*]u8, buf_size: u32) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;
    if (name.len == 0) return -22;

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    const ea_block = inode.file_acl;
    if (ea_block == 0) return -61; // ENODATA

    const phys = pmm.allocPage() orelse return -12;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(ea_block, buf)) return -5;

    const hdr: *Ext2XattrHeader = @ptrCast(@alignCast(buf));
    if (hdr.h_magic != EXT2_XATTR_MAGIC) return -5;

    var entry_off: usize = @sizeOf(Ext2XattrHeader);
    while (entry_off < block_size) {
        if (buf[entry_off] == 0 and buf[entry_off + 1] == 0) break;
        const entry: *Ext2XattrEntry = @ptrCast(@alignCast(buf + entry_off));
        if (entry.e_name_len == 0) break;
        // Skip tombstones
        if (entry.e_name_index == 0) {
            const esz = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
            entry_off = (entry_off + esz + 3) & ~@as(usize, 3);
            continue;
        }
        const ename = buf[entry_off + @sizeOf(Ext2XattrEntry) ..][0..entry.e_name_len];
        if (entry.e_name_index == XATTR_USER_PREFIX and eql(ename, name)) {
            // Found — copy value
            const vsize = entry.e_value_size;
            if (vsize == 0) return @as(i64, 0); // flag-only, no value
            if (vsize > buf_size) return -34; // ERANGE
            const value_start: usize = entry.e_value_offs;
            // v52.5 fix: e_value_offs==0 with vsize>0 means corrupt/inline (unsupported)
            if (value_start == 0 or value_start < @sizeOf(Ext2XattrHeader)) return -5;
            if (value_start + vsize > block_size) return -5; // corrupt entry
            @memcpy(value_buf[0..vsize], buf[value_start..][0..vsize]);
            return @intCast(vsize);
        }
        const entry_size = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
        entry_off = (entry_off + entry_size + 3) & ~@as(usize, 3);
    }
    return -61; // ENODATA
}

/// List extended attribute names for an inode.
/// Returns bytes written to list_buf, or -errno.
pub fn listXattr(inode_num: u32, list_buf: [*]u8, buf_size: u32) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    const ea_block = inode.file_acl;
    if (ea_block == 0) return 0; // no attributes, 0 bytes written

    const phys = pmm.allocPage() orelse return -12;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(ea_block, buf)) return -5;

    const hdr: *Ext2XattrHeader = @ptrCast(@alignCast(buf));
    if (hdr.h_magic != EXT2_XATTR_MAGIC) return -5;

    var written: u32 = 0;
    var entry_off: usize = @sizeOf(Ext2XattrHeader);
    while (entry_off < block_size) {
        if (buf[entry_off] == 0 and buf[entry_off + 1] == 0) break;
        const entry: *Ext2XattrEntry = @ptrCast(@alignCast(buf + entry_off));
        if (entry.e_name_len == 0) break;

        // Skip tombstones (e_name_index == 0 means deleted)
        if (entry.e_name_index == 0) {
            const entry_size = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
            entry_off = (entry_off + entry_size + 3) & ~@as(usize, 3);
            continue;
        }

        // v52.6: Only list user namespace entries (consistent with set/get/remove EPERM rejection)
        if (entry.e_name_index != XATTR_USER_PREFIX) {
            const entry_size = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
            entry_off = (entry_off + entry_size + 3) & ~@as(usize, 3);
            continue;
        }

        // Format: "user.<name>\0"
        const prefix = "user.";
        const total_len: u32 = @intCast(prefix.len + entry.e_name_len + 1);
        if (written + total_len > buf_size) return -34; // ERANGE

        @memcpy(list_buf[written..][0..prefix.len], prefix);
        written += @intCast(prefix.len);
        @memcpy(list_buf[written..][0..entry.e_name_len], buf[entry_off + @sizeOf(Ext2XattrEntry) ..][0..entry.e_name_len]);
        written += entry.e_name_len;
        list_buf[written] = 0; // null terminator
        written += 1;

        const entry_size = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
        entry_off = (entry_off + entry_size + 3) & ~@as(usize, 3);
    }
    return @intCast(written);
}

/// Remove extended attribute from an inode.
/// Returns 0 on success, -errno on failure.
pub fn removeXattr(inode_num: u32, name: []const u8) i64 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (!active) return -5;
    if (name.len == 0) return -22;

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    const ea_block = inode.file_acl;
    if (ea_block == 0) return -61; // ENODATA

    const phys = pmm.allocPage() orelse return -12;
    defer pmm.freePage(phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    if (!readBlock(ea_block, buf)) return -5;

    const hdr: *Ext2XattrHeader = @ptrCast(@alignCast(buf));
    if (hdr.h_magic != EXT2_XATTR_MAGIC) return -5;

    var entry_off: usize = @sizeOf(Ext2XattrHeader);
    while (entry_off < block_size) {
        if (buf[entry_off] == 0 and buf[entry_off + 1] == 0) break;
        const entry: *Ext2XattrEntry = @ptrCast(@alignCast(buf + entry_off));
        if (entry.e_name_len == 0) break;
        // Skip tombstones (e_name_index == 0)
        if (entry.e_name_index == 0) {
            const esz = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
            entry_off = (entry_off + esz + 3) & ~@as(usize, 3);
            continue;
        }
        const ename = buf[entry_off + @sizeOf(Ext2XattrEntry) ..][0..entry.e_name_len];
        if (entry.e_name_index == XATTR_USER_PREFIX and eql(ename, name)) {
            // Found — tombstone approach: zero entry only, no shift (v52.4)
            // In standard ext2 xattr layout, values grow backward from block end.
            // Shifting entries would corrupt e_value_offs of surviving entries.
            const val_off: usize = entry.e_value_offs;
            const val_size = entry.e_value_size;
            if (val_off > 0 and val_off + val_size <= block_size) {
                @memset(buf[val_off..][0..val_size], 0);
            }
            // Tombstone: set e_name_index=0 (invalid namespace) to mark deleted,
            // keep e_name_len intact so scanners can skip over the tombstone slot.
            entry.e_name_index = 0; // tombstone marker
            entry.e_value_offs = 0;
            entry.e_value_size = 0;
            entry.e_hash = 0;
            // Clear the name bytes
            @memset(buf[entry_off + @sizeOf(Ext2XattrEntry) ..][0..entry.e_name_len], 0);

            // Check if EA block is now empty (no live entries left)
            var all_empty = true;
            var scan_off2: usize = @sizeOf(Ext2XattrHeader);
            while (scan_off2 < block_size) {
                if (buf[scan_off2] == 0 and buf[scan_off2 + 1] == 0) break; // end of entries
                const se: *Ext2XattrEntry = @ptrCast(@alignCast(buf + scan_off2));
                if (se.e_name_len == 0) break; // end of entries
                if (se.e_name_index != 0) {
                    all_empty = false;
                    break;
                } // live entry
                const ssz = (@sizeOf(Ext2XattrEntry) + se.e_name_len + 3) & ~@as(usize, 3);
                scan_off2 += ssz;
            }
            if (all_empty) {
                // v53.1: Only free EA block after successful writeInode
                // If writeInode fails, disk inode still references the EA block;
                // freeing it would create a dangling reference (data corruption)
                inode.file_acl = 0;
                if (!writeInode(inode_num, &inode)) return -5;
                freeBlock(ea_block);
            } else {
                _ = writeBlock(ea_block, buf);
            }
            return 0;
        }
        const entry_size = @sizeOf(Ext2XattrEntry) + entry.e_name_len;
        entry_off = (entry_off + entry_size + 3) & ~@as(usize, 3);
    }
    return -61; // ENODATA
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ─── Open file path lookup for execveat (v52.0) ─────────────────────────────

/// Get the path used to open file_idx. Returns null if not found.
pub fn getOpenFilePath(file_idx: u32) ?[]const u8 {
    const flags = fs_lock.acquire();
    defer fs_lock.release(flags);
    if (file_idx >= MAX_OPEN_FILES) return null;
    if (open_files[file_idx].inode_num == 0) return null;
    // Find null terminator
    var len: usize = 0;
    while (len < 128 and open_file_paths[file_idx][len] != 0) : (len += 1) {}
    if (len == 0) return null;
    return open_file_paths[file_idx][0..len];
}

/// Build a combined path: dir_path + "/" + relative_path into buf.
/// Returns slice of buf, or null on overflow.
/// Handles trailing slash in dir_path to avoid double-"//".
pub fn buildCombinedPath(buf: []u8, dir_path: []const u8, rel_path: []const u8) ?[]const u8 {
    // Trim trailing slashes from dir_path (but keep at least "/")
    var dp_end: usize = dir_path.len;
    while (dp_end > 1 and dir_path[dp_end - 1] == '/') dp_end -= 1;
    const dp = dir_path[0..dp_end];
    // Only add separator if dir_path doesn't already end with '/'
    const need_sep: bool = dp.len > 0 and dp[dp.len - 1] != '/';
    const total = dp.len + (if (need_sep) @as(usize, 1) else @as(usize, 0)) + rel_path.len;
    if (total >= buf.len) return null;
    @memcpy(buf[0..dp.len], dp);
    var pos = dp.len;
    if (need_sep) {
        buf[pos] = '/';
        pos += 1;
    }
    @memcpy(buf[pos..total], rel_path);
    buf[total] = 0;
    return buf[0..total];
}
