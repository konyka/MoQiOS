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
const serial = @import("../arch/x86_64/serial.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");

const SECTOR_SIZE: u32 = 512;
const MAX_OPEN_FILES: u32 = 16;
const MAX_FILENAME: u32 = 256;

// ─── ext2 on-disk structures ──────────────────────────────────────────────

const Ext2Superblock = extern struct {
    inodes_count: u32,
    blocks_count: u32,
    r_blocks_count: u32,
    free_blocks_count: u32,
    free_inodes_count: u32,
    first_data_block: u32,
    log_block_size: u32,
    log_frag_size: u32,
    blocks_per_group: u32,
    frags_per_group: u32,
    inodes_per_group: u32,
    mtime: u32,
    wtime: u32,
    mnt_count: u16,
    max_mnt_count: u16,
    magic: u16,
    state: u16,
    errors: u16,
    minor_rev_level: u16,
    lastcheck: u32,
    checkinterval: u32,
    creator_os: u32,
    rev_level: u32,
    def_resuid: u16,
    def_resgid: u16,
    first_ino: u32,
    inode_size: u16,
    block_group_nr: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    uuid: [16]u8,
    volume_name: [16]u8,
};

const Ext2GroupDesc = extern struct {
    bg_block_bitmap: u32,
    bg_inode_bitmap: u32,
    bg_inode_table: u32,
    bg_free_blocks_count: u16,
    bg_free_inodes_count: u16,
    bg_used_dirs_count: u16,
};

const EXT2_INODE_DIRECT = 12;

const Ext2Inode = extern struct {
    mode: u16,
    uid: u16,
    size: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid: u16,
    links_count: u16,
    blocks: u32,
    flags: u32,
    osd1: u32,
    block: [15]u32,
    generation: u32,
    file_acl: u32,
    dir_acl: u32,
    faddr: u32,
    osd2: [12]u8,
};

const Ext2DirEntry = extern struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
};

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

const DISK_LBA_OFFSET: u64 = 32768;

var group_descs_phys: u64 = 0;
var group_descs_virt: u64 = 0;

var sector_buf_phys: u64 = 0;
var sector_buf_virt: u64 = 0;

pub const Ext2File = struct {
    inode_num: u32,
    inode: Ext2Inode,
    offset: u32,
};

var open_files: [MAX_OPEN_FILES]Ext2File = undefined;
var open_count: u32 = 0;

// ─── Initialization ───────────────────────────────────────────────────────

pub fn init() void {
    sector_buf_phys = pmm.allocPage() orelse return;
    sector_buf_virt = hhdm.physToVirt(sector_buf_phys);

    // Read superblock (at byte offset 1024 = sector 2)
    const sb_sector: u64 = 1024 / SECTOR_SIZE;
    if (!readSectors(sb_sector, 2)) return;

    const sb_ptr: [*]const u8 = @ptrFromInt(sector_buf_virt);
    @memcpy(@as([*]u8, @ptrCast(&sb))[0..@sizeOf(Ext2Superblock)], sb_ptr[0..@sizeOf(Ext2Superblock)]);

    if (sb.magic != 0xEF53) {
        serial.writeString("[ext2] bad magic\n");
        return;
    }

    block_size = @as(u32, 1024) << @intCast(sb.log_block_size);
    groups_count = (sb.blocks_count + sb.blocks_per_group - 1) / sb.blocks_per_group;
    inodes_per_group = sb.inodes_per_group;
    inode_size = if (sb.rev_level >= 1) sb.inode_size else 128;
    if (inode_size == 0) inode_size = 128;
    first_data_block = sb.first_data_block;

    // Read block group descriptor table (at block first_data_block + 1)
    const bgdt_block = first_data_block + 1;
    const bgdt_size = groups_count * @sizeOf(Ext2GroupDesc);
    const bgdt_blocks = (bgdt_size + block_size - 1) / block_size;
    const bgdt_sectors = bgdt_blocks * (block_size / SECTOR_SIZE);
    const bgdt_sector = bgdt_block * (block_size / SECTOR_SIZE);

    group_descs_phys = pmm.allocPage() orelse return;
    group_descs_virt = hhdm.physToVirt(group_descs_phys);

    const gd_buf: [*]u8 = @ptrFromInt(group_descs_virt);
    if (!readSectorsToBuf(bgdt_sector, bgdt_sectors, gd_buf)) return;

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

fn readSectorsToBuf(lba: u64, count: u32, dest: [*]u8) bool {
    const n = virtio_blk.readSectors(DISK_LBA_OFFSET + lba, count, dest);
    return n > 0;
}

// ─── Block I/O ─────────────────────────────────────────────────────────────

/// Read a block from disk (uncached, direct I/O).
fn readBlockUncached(block_num: u32, buf: [*]u8) bool {
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
    data: [CACHE_BLOCK_SIZE]u8 = @splat(0),
    hash_next: ?u8 = null, // chain link in hash bucket
};

var cache: [CACHE_ENTRIES]CacheEntry = @splat(.{});
var cache_hash: [CACHE_ENTRIES]?u8 = @splat(null); // hash buckets
var cache_next: usize = 0; // clock hand for replacement
var cache_hits: u64 = 0;
var cache_misses: u64 = 0;

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

/// Flush all dirty cache entries to disk.
pub fn cacheFlush() void {
    for (0..CACHE_ENTRIES) |i| {
        if (cache[i].valid and cache[i].dirty) {
            _ = writeBlockUncached(cache[i].block_num, &cache[i].data);
            cache[i].dirty = false;
        }
    }
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
    return .{ .hits = cache_hits, .misses = cache_misses };
}

// ─── Inode operations ─────────────────────────────────────────────────────

fn readInode(inode_num: u32, out: *Ext2Inode) bool {
    const group = (inode_num - 1) / inodes_per_group;
    const index = (inode_num - 1) % inodes_per_group;

    const gds: [*]const Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = gds[group];

    const inode_table_block = gd.bg_inode_table;
    const byte_offset = index * inode_size;
    const block_offset = byte_offset / block_size;
    const offset_in_block = byte_offset % block_size;

    const target_block = inode_table_block + block_offset;

    // `inode_size` is the on-disk *stride* between inodes (256 on rev>=1
    // filesystems), but our `Ext2Inode` only models the 128-byte base inode.
    // Clamp the copy to the struct size so we never overflow `out` (the extra
    // bytes of a 256-byte inode are extended fields we don't use).
    const out_bytes: [*]u8 = @ptrCast(out);
    const copy_len = @min(inode_size, @as(u32, @sizeOf(Ext2Inode)));

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
    if (!active) return -1;

    // Start from root inode (2)
    return walkPath(2, name);
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
        if (inode.mode & 0xF000 != 0x4000) return -1;

        // Search directory entries for component
        const found = findDirEntry(&inode, component) orelse return -1;

        // Check if the found entry is a symlink
        var found_inode: Ext2Inode = undefined;
        if (readInode(found, &found_inode) and found_inode.mode & 0xF000 == 0xA000) {
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
                open_files[@intCast(resolved_fd)].inode_num = 0; // close
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
            if (inode.mode & 0xF000 != 0x4000) return null;

            const dir_inode_num = parent_inode; // directory containing this component
            parent_inode = findDirEntry(&inode, component) orelse return null;

            // v50.0: resolve symlinks in intermediate components
            var found_inode: Ext2Inode = undefined;
            if (readInode(parent_inode, &found_inode) and
                found_inode.mode & 0xF000 == 0xA000)
            {
                if (readSymlinkTarget(&found_inode)) |target| {
                    const new_start: u32 = if (target.len > 0 and target[0] == '/') 2 else dir_inode_num;
                    const inner = walkPathInner(new_start, target, 1);
                    if (inner < 0) return null;
                    parent_inode = @intCast(inner);
                } else {
                    return null;
                }
            }
        }
    }

    return .{ .parent = parent_inode, .name = filename };
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
            const entry: *const Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len == name.len) {
                const entry_name = buf[pos + @sizeOf(Ext2DirEntry) .. pos + @sizeOf(Ext2DirEntry) + name.len];
                var match = true;
                for (name, 0..) |c, j| {
                    if (entry_name[j] != c) {
                        match = false;
                        break;
                    }
                }
                if (match) return entry.inode;
            }

            pos += entry.rec_len;
        }
        offset += block_size;
    }
    return null;
}

// ─── Block resolution (direct + single indirect) ──────────────────────────

fn resolveBlock(inode: *const Ext2Inode, logical_block: u32) u32 {
    if (logical_block < EXT2_INODE_DIRECT) {
        return inode.block[logical_block];
    }

    // Single indirect (block[12])
    const indirect_base = EXT2_INODE_DIRECT;
    const ptrs_per_block = block_size / 4;

    if (logical_block < indirect_base + ptrs_per_block) {
        const indirect_block = inode.block[12];
        if (indirect_block == 0) return 0;

        const index = logical_block - indirect_base;

        // Fast path: zero-copy cache lookup (avoids allocPage + memcpy)
        if (cacheLookupPtr(indirect_block)) |buf| {
            const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
            return ptrs[index];
        }

        // Cache miss: allocate temp buffer, read, insert into cache
        const buf_phys = pmm.allocPage() orelse return 0;
        defer pmm.freePage(buf_phys);
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
        if (!readBlock(indirect_block, buf)) return 0;
        const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
        return ptrs[index];
    }

    // Double indirect (block[13])
    const dbl_base = indirect_base + ptrs_per_block;
    if (logical_block < dbl_base + ptrs_per_block * ptrs_per_block) {
        const dbl_block = inode.block[13];
        if (dbl_block == 0) return 0;

        const rel = logical_block - dbl_base;
        const idx1 = rel / ptrs_per_block;
        const idx2 = rel % ptrs_per_block;

        // Fast path for double indirect block: zero-copy
        const single_indirect: u32 = if (cacheLookupPtr(dbl_block)) |buf| blk: {
            const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
            break :blk ptrs[idx1];
        } else blk: {
            const buf_phys = pmm.allocPage() orelse return 0;
            defer pmm.freePage(buf_phys);
            const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
            if (!readBlock(dbl_block, buf)) return 0;
            const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
            break :blk ptrs[idx1];
        };
        if (single_indirect == 0) return 0;

        // Fast path for single indirect: zero-copy
        if (cacheLookupPtr(single_indirect)) |buf| {
            const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
            return ptrs[idx2];
        }

        const buf2_phys = pmm.allocPage() orelse return 0;
        defer pmm.freePage(buf2_phys);
        const buf2: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf2_phys));
        if (!readBlock(single_indirect, buf2)) return 0;
        const ptrs2: [*]const u32 = @ptrCast(@alignCast(buf2));
        return ptrs2[idx2];
    }

    return 0;
}

// ─── File read ─────────────────────────────────────────────────────────────

pub fn readFile(file_idx: u32, offset: u32, buf: [*]u8, count: u32) i64 {
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

        // Try page cache first (with sequential prefetch)
        const page_idx = logical_block; // page_offset in pages
        if (page_cache.readPage(inode_id, page_idx)) |cached| {
            @memcpy(buf[read_total .. read_total + chunk], cached[block_offset .. block_offset + chunk]);
            // Track access for prefetch hint (on cache hit too, to maintain pattern)
            const pf_count = page_cache.recordAccess(inode_id, page_idx);
            if (pf_count > 0) {
                // Prefetch next pages (already cached? skip)
                prefetchPages(&f.inode, inode_id, page_idx + 1, pf_count);
            }
        } else {
            // Cache miss — read from disk
            const phys_block = resolveBlock(&f.inode, logical_block);
            if (phys_block == 0) break;
            const tmp_phys = pmm.allocPage() orelse break;
            const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(tmp_phys));
            if (!readBlock(phys_block, tmp)) {
                pmm.freePage(tmp_phys);
                break;
            }
            @memcpy(buf[read_total .. read_total + chunk], tmp[block_offset .. block_offset + chunk]);
            // Insert into page cache
            const page_data: *const [4096]u8 = tmp[0..4096];
            _ = page_cache.insertPage(inode_id, page_idx, page_data);
            pmm.freePage(tmp_phys);
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
        if (!readBlock(phys_block, tmp)) {
            pmm.freePage(tmp_phys);
            break;
        }
        const page_data: *const [4096]u8 = tmp[0..4096];
        _ = page_cache.insertPage(inode_id, pg, page_data);
        pmm.freePage(tmp_phys);
    }
}

pub fn getInodeNum(file_idx: u32) u32 {
    if (file_idx >= MAX_OPEN_FILES) return 0;
    return open_files[file_idx].inode_num;
}

pub fn getFileSize(file_idx: u32) u64 {
    if (file_idx >= open_count) return 0;
    return open_files[file_idx].inode.size;
}

pub fn closeFile(file_idx: u32) void {
    if (file_idx >= open_count) return;
    open_files[file_idx].inode_num = 0;
}

// ─── Directory listing ─────────────────────────────────────────────────────

pub fn listDir(path: []const u8, callback: *const fn ([*]const u8, u32) void) void {
    if (!active) return;

    const inode_num = if (path.len == 0 or (path.len == 1 and path[0] == '/'))
        @as(u32, 2)
    else blk: {
        const r = walkPath(2, path);
        break :blk if (r >= 0) open_files[@intCast(r)].inode_num else {
            if (r >= 0) closeFile(@intCast(r));
            return;
        };
    };

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return;
    if (inode.mode & 0xF000 != 0x4000) return;

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
            const entry: *const Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name_ptr = buf + pos + @sizeOf(Ext2DirEntry);
                callback(name_ptr, entry.name_len);
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
    if (!active) return 0;
    return listDirInode(2, buf);
}

fn listDirInode(inode_num: u32, buf: []u8) usize {
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return 0;
    if (inode.mode & 0xF000 != 0x4000) return 0;

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
            const entry: *const Ext2DirEntry = @ptrCast(@alignCast(blk + bpos));
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name = blk + bpos + @sizeOf(Ext2DirEntry);
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
pub fn readDirEntries(file_idx: u32, start_offset: u32, names: [*][*]u8, name_lens: [*]u32, inodes: [*]u32, file_types: [*]u8, next_offsets: [*]u32, max_entries: u32) struct { count: u32, new_offset: u32 } {
    if (!active) return .{ .count = 0, .new_offset = start_offset };
    if (file_idx >= open_count) return .{ .count = 0, .new_offset = start_offset };
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return .{ .count = 0, .new_offset = start_offset };
    if (f.inode.mode & 0xF000 != 0x4000) return .{ .count = 0, .new_offset = start_offset };

    const dir_size = f.inode.size;
    if (start_offset >= dir_size) return .{ .count = 0, .new_offset = start_offset };

    const buf_phys = pmm.allocPage() orelse return .{ .count = 0, .new_offset = start_offset };
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    var offset = start_offset;
    var count: u32 = 0;

    while (offset < dir_size and count < max_entries) {
        const block_num = offset / block_size;
        const phys_block = resolveBlock(&f.inode, block_num);
        if (phys_block == 0) break;
        if (!readBlock(phys_block, buf)) break;

        const pos_in_block = offset % block_size;
        var pos: u32 = pos_in_block;

        while (pos < block_size and count < max_entries) {
            const entry: *const Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name_ptr = buf + pos + @sizeOf(Ext2DirEntry);
                names[count] = name_ptr;
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

/// Truncate a file to the given length. Frees blocks beyond the new size.
pub fn truncateFile(file_idx: u32, new_size: u32) bool {
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

    // Shrinking: free blocks beyond new_size
    const new_blocks_needed = if (new_size == 0) 0 else (new_size + block_size - 1) / block_size;

    // Free direct blocks beyond needed
    for (new_blocks_needed..EXT2_INODE_DIRECT) |i| {
        if (i < EXT2_INODE_DIRECT and f.inode.block[i] != 0) {
            freeBlock(f.inode.block[i]);
            f.inode.block[i] = 0;
        }
    }

    // If new_blocks_needed < EXT2_INODE_DIRECT, free indirect blocks entirely
    if (new_blocks_needed <= EXT2_INODE_DIRECT) {
        if (f.inode.block[12] != 0) {
            // Free all blocks pointed to by single indirect
            const ib_phys = pmm.allocPage() orelse return false;
            const ib: [*]u8 = @ptrFromInt(hhdm.physToVirt(ib_phys));
            if (readBlock(f.inode.block[12], ib)) {
                const ptrs_per_block = block_size / 4;
                const ptrs: [*]const u32 = @ptrCast(@alignCast(ib));
                for (0..ptrs_per_block) |j| {
                    if (ptrs[j] != 0) freeBlock(ptrs[j]);
                }
            }
            pmm.freePage(ib_phys);
            freeBlock(f.inode.block[12]);
            f.inode.block[12] = 0;
        }
    }

    // Free double indirect entirely if not needed
    if (f.inode.block[13] != 0 and new_blocks_needed <= EXT2_INODE_DIRECT + block_size / 4) {
        freeBlock(f.inode.block[13]);
        f.inode.block[13] = 0;
    }

    f.inode.size = new_size;
    f.inode.blocks = new_blocks_needed * (block_size / 512);
    _ = writeInode(f.inode_num, &f.inode);
    return true;
}

/// Rename a file: remove old entry from source dir, add entry in dest dir.
/// Supports cross-directory rename (old_path and new_path can be in different dirs).
pub fn renameFile(old_path: []const u8, new_path: []const u8) bool {
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
    const file_inode_num = findDirEntry(&old_parent_ino_data, old_filename) orelse return false;

    // Read file inode to get file_type
    var file_inode: Ext2Inode = undefined;
    if (!readInode(file_inode_num, &file_inode)) return false;
    const file_type: u8 = if (file_inode.mode & 0xF000 == 0x4000) 2 else 1;

    // If destination exists, remove it first (overwrite semantics)
    var new_parent_inode_data: Ext2Inode = undefined;
    if (readInode(new_parent_inode, &new_parent_inode_data)) {
        if (findDirEntry(&new_parent_inode_data, new_filename)) |_| {
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
    const n = virtio_blk.writeSectors(DISK_LBA_OFFSET + lba, block_size / SECTOR_SIZE, buf);
    return n > 0;
}

/// Write a block to disk and update cache (write-through).
fn writeBlock(block_num: u32, buf: [*]const u8) bool {
    return writeBlockCached(block_num, buf);
}

fn writeInode(inode_num: u32, inode: *const Ext2Inode) bool {
    const group = (inode_num - 1) / inodes_per_group;
    const index = (inode_num - 1) % inodes_per_group;

    const gds: [*]const Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = gds[group];

    const inode_table_block = gd.bg_inode_table;
    const byte_offset = index * inode_size;
    const block_offset = byte_offset / block_size;
    const offset_in_block = byte_offset % block_size;
    const target_block = inode_table_block + block_offset;

    const buf_phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    if (!readBlock(target_block, buf)) return false;

    // Read-modify-write: only overwrite the 128-byte base inode we model,
    // preserving the on-disk extended portion (rev>=1 inodes are 256 bytes).
    // Reading `inode_size` bytes from our 128-byte struct would also be an
    // out-of-bounds read that leaks adjacent memory onto disk.
    const inode_bytes: [*]const u8 = @ptrCast(inode);
    const copy_len = @min(inode_size, @as(u32, @sizeOf(Ext2Inode)));
    if (offset_in_block + copy_len <= block_size) {
        @memcpy(buf[offset_in_block .. offset_in_block + copy_len], inode_bytes[0..copy_len]);
        if (!writeBlock(target_block, buf)) return false;
    } else {
        // Inode straddles a block boundary
        const first_part = block_size - offset_in_block;
        @memcpy(buf[offset_in_block .. offset_in_block + first_part], inode_bytes[0..first_part]);
        if (!writeBlock(target_block, buf)) return false;

        const buf2_phys = pmm.allocPage() orelse return false;
        defer pmm.freePage(buf2_phys);
        const buf2: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf2_phys));
        if (!readBlock(target_block + 1, buf2)) return false;
        @memcpy(buf2[0 .. copy_len - first_part], inode_bytes[first_part..copy_len]);
        if (!writeBlock(target_block + 1, buf2)) return false;
    }
    return true;
}

/// Allocate a data block from the block bitmap of the given group.
/// Returns block number, or 0 on failure.
fn allocBlock(group: u32) u32 {
    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];

    if (gd.bg_free_blocks_count == 0) return 0;

    const bitmap_block = gd.bg_block_bitmap;
    const buf_phys = pmm.allocPage() orelse return 0;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    if (!readBlock(bitmap_block, buf)) return 0;

    const total_blocks_in_group = if (group < groups_count - 1) sb.blocks_per_group else sb.blocks_count - group * sb.blocks_per_group;
    const first_block = group * sb.blocks_per_group + first_data_block;

    // Scan bitmap for a free bit (0 = free) using 64-bit word scanning.
    // Inverted word + @ctz skips 64 used blocks per iteration.
    const words: [*]const u64 = @ptrCast(@alignCast(buf));
    const total_bytes = (total_blocks_in_group + 7) / 8;
    const total_words = (total_bytes + 7) / 8;
    var w: u32 = 0;
    while (w < total_words) : (w += 1) {
        const inv = ~words[w]; // flip: 1 = free
        if (inv == 0) continue; // all 64 blocks used
        const bit = @ctz(inv);
        const i = w * 64 + @as(u32, bit);
        if (i >= total_blocks_in_group) break;
        // Found a free block — mark as used
        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(i % 8);
        buf[byte_idx] |= @as(u8, 1) << bit_idx;
        if (!writeBlock(bitmap_block, buf)) return 0;

        // Update group descriptor
        gd.bg_free_blocks_count -= 1;
        writeGroupDescs();

        // Update superblock free block count
        sb.free_blocks_count -= 1;
        writeSuperblock();

        // Zero the newly allocated block
        const zero_phys = pmm.allocPage() orelse return 0;
        defer pmm.freePage(zero_phys);
        const zero_buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(zero_phys));
        @memset(zero_buf[0..block_size], 0);
        const block_num = first_block + i;
        _ = writeBlock(block_num, zero_buf);

        return block_num;
    }
    return 0;
}

/// Ensure a logical block is allocated for the given inode.
/// Returns the physical block number, allocating if necessary.
fn ensureBlock(inode: *Ext2Inode, inode_num: u32, logical_block: u32) u32 {
    // Check direct blocks first
    if (logical_block < EXT2_INODE_DIRECT) {
        if (inode.block[logical_block] != 0) return inode.block[logical_block];
        const blk = allocBlock(0); // allocate from group 0 for simplicity
        if (blk == 0) return 0;
        inode.block[logical_block] = blk;
        inode.blocks += block_size / 512;
        _ = writeInode(inode_num, inode);
        return blk;
    }

    // Single indirect
    const indirect_base = EXT2_INODE_DIRECT;
    const ptrs_per_block = block_size / 4;

    if (logical_block < indirect_base + ptrs_per_block) {
        const buf_phys = pmm.allocPage() orelse return 0;
        defer pmm.freePage(buf_phys);
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

        if (inode.block[12] == 0) {
            // Allocate indirect block
            const ind_blk = allocBlock(0);
            if (ind_blk == 0) return 0;
            inode.block[12] = ind_blk;
            inode.blocks += block_size / 512;
            @memset(buf[0..block_size], 0);
        } else {
            if (!readBlock(inode.block[12], buf)) return 0;
        }

        const index = logical_block - indirect_base;
        const ptrs: [*]u32 = @ptrCast(@alignCast(buf));
        if (ptrs[index] == 0) {
            const blk = allocBlock(0);
            if (blk == 0) return 0;
            ptrs[index] = blk;
            inode.blocks += block_size / 512;
            _ = writeBlock(inode.block[12], buf);
        }
        _ = writeInode(inode_num, inode);
        return ptrs[index];
    }

    // Double indirect: block[13] -> single indirect blocks -> data blocks
    const dbl_base = indirect_base + ptrs_per_block;
    if (logical_block < dbl_base + ptrs_per_block * ptrs_per_block) {
        const buf_phys = pmm.allocPage() orelse return 0;
        defer pmm.freePage(buf_phys);
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

        // Ensure double indirect block exists
        if (inode.block[13] == 0) {
            const dbl_blk = allocBlock(0);
            if (dbl_blk == 0) return 0;
            inode.block[13] = dbl_blk;
            inode.blocks += block_size / 512;
            @memset(buf[0..block_size], 0);
        } else {
            if (!readBlock(inode.block[13], buf)) return 0;
        }

        const rel = logical_block - dbl_base;
        const idx1 = rel / ptrs_per_block;
        const idx2 = rel % ptrs_per_block;
        const dbl_ptrs: [*]u32 = @ptrCast(@alignCast(buf));

        // Ensure single indirect block at idx1
        if (dbl_ptrs[idx1] == 0) {
            const si_blk = allocBlock(0);
            if (si_blk == 0) return 0;
            dbl_ptrs[idx1] = si_blk;
            inode.blocks += block_size / 512;
            _ = writeBlock(inode.block[13], buf);
            // Allocate zeroed single indirect block
            const si_buf_phys = pmm.allocPage() orelse return 0;
            defer pmm.freePage(si_buf_phys);
            const si_buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(si_buf_phys));
            @memset(si_buf[0..block_size], 0);
            _ = writeBlock(si_blk, si_buf);
        }

        // Read single indirect block
        const si_buf_phys = pmm.allocPage() orelse return 0;
        defer pmm.freePage(si_buf_phys);
        const si_buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(si_buf_phys));
        if (!readBlock(dbl_ptrs[idx1], si_buf)) return 0;

        const si_ptrs: [*]u32 = @ptrCast(@alignCast(si_buf));
        if (si_ptrs[idx2] == 0) {
            const blk = allocBlock(0);
            if (blk == 0) return 0;
            si_ptrs[idx2] = blk;
            inode.blocks += block_size / 512;
            _ = writeBlock(dbl_ptrs[idx1], si_buf);
        }
        _ = writeInode(inode_num, inode);
        return si_ptrs[idx2];
    }

    return 0;
}

/// Write data to an ext2 file at the given offset.
/// Returns bytes written, or -1 on error.
pub fn writeFile(file_idx: u32, offset: u32, buf: [*]const u8, count: u32) i64 {
    if (!active) return -1;
    if (file_idx >= open_count) return -1;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return -1;

    var written: u32 = 0;
    var current_offset = offset;
    const page_cache = @import("page_cache.zig");
    const inode_id: u64 = 0x3000_0000_0000_0000 + @as(u64, f.inode_num);

    while (written < count) {
        const logical_block = current_offset / block_size;
        const block_offset = current_offset % block_size;
        const chunk = @min(count - written, block_size - block_offset);

        const phys_block = ensureBlock(&f.inode, f.inode_num, logical_block);
        if (phys_block == 0) break;

        // Build the full block data
        var block_data: [4096]u8 = undefined;

        // Check page cache for existing data
        if (page_cache.readPage(inode_id, logical_block)) |cached| {
            @memcpy(&block_data, cached);
        } else {
            // Read-modify-write: read the block from disk, patch our data
            if (block_offset != 0 or chunk < block_size) {
                if (!readBlock(phys_block, &block_data)) break;
            } else {
                @memset(&block_data, 0);
            }
        }

        @memcpy(block_data[block_offset .. block_offset + chunk], buf[written .. written + chunk]);

        // Write through page cache (marks dirty for writeback)
        _ = page_cache.writePage(inode_id, logical_block, &block_data);
        // Also write directly to disk for now (write-through)
        _ = writeBlock(phys_block, &block_data);

        written += chunk;
        current_offset += chunk;
    }

    if (written == 0) return -1;

    // Update file size if we extended the file
    const new_end = offset + written;
    if (new_end > f.inode.size) {
        f.inode.size = new_end;
        _ = writeInode(f.inode_num, &f.inode);
    }

    return @intCast(written);
}

// ─── Inode allocation ──────────────────────────────────────────────────────

/// Allocate an inode from the bitmap of the given group.
/// Returns inode number (1-based), or 0 on failure.
fn allocInode(group: u32) u32 {
    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];

    if (gd.bg_free_inodes_count == 0) return 0;

    const bitmap_block = gd.bg_inode_bitmap;
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
    const sb_buf_phys = pmm.allocPage() orelse return;
    defer pmm.freePage(sb_buf_phys);
    const sb_buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(sb_buf_phys));
    // Superblock is at byte offset 1024. We need to preserve bytes 0-1023.
    const sb_lba: u64 = 1024 / SECTOR_SIZE;
    // Read existing 1024 bytes of boot area
    if (!readSectorsToBuf(sb_lba, 2, sb_buf)) return;
    // Overlay superblock at offset 0 within the sector buffer (superblock starts at byte 1024, sector 2, offset 0)
    @memcpy(sb_buf[0..@sizeOf(Ext2Superblock)], @as([*]const u8, @ptrCast(&sb))[0..@sizeOf(Ext2Superblock)]);
    _ = virtio_blk.writeSectors(DISK_LBA_OFFSET + sb_lba, 2, sb_buf);
}

// ─── Create file ────────────────────────────────────────────────────────────

/// Create a new file in the root directory of the ext2 filesystem.
/// Returns file index (>= 0) on success, -1 on failure.
pub fn createFile(name: []const u8) i64 {
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

    if (!writeInode(new_inode_num, &new_inode)) return -1;

    // Add directory entry to parent directory
    if (!addDirEntry(parent_inode_num, new_inode_num, filename, 1)) { // file_type=1 (regular file)
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
            if (i >= open_count) open_count = @intCast(i + 1);
            return @intCast(i);
        }
    }
    return -1;
}

/// Add a directory entry to a directory inode.
/// Simple approach: try to split last entry in last block, else allocate new block.
fn addDirEntry(dir_inode_num: u32, target_inode: u32, entry_name: []const u8, file_type: u8) bool {
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
            while (pos < block_size) {
                const entry: *const Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
                if (entry.rec_len == 0) break;
                last_pos = pos;
                const next = pos + entry.rec_len;
                if (next >= block_size) break;
                pos = next;
            }

            // Check if the last entry has wasted space we can split
            if (last_pos < block_size) {
                const last_entry: *Ext2DirEntry = @ptrCast(@alignCast(buf + last_pos));
                const actual_len = (@as(u16, @sizeOf(Ext2DirEntry)) + @as(u16, last_entry.name_len) + 3) & ~@as(u16, 3);
                const wasted = last_entry.rec_len - actual_len;

                if (wasted >= aligned_len) {
                    // Shrink the last entry
                    last_entry.rec_len = actual_len;

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
    const new_block = allocBlock(0);
    if (new_block == 0) return false;

    // Add block to directory inode
    const next_logical = dir_size / block_size;
    if (next_logical >= EXT2_INODE_DIRECT) return false; // only direct blocks for dirs
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

    if (!writeBlock(new_block, buf)) return false;
    return writeInode(dir_inode_num, &dir_inode);
}

// ─── Directory creation ────────────────────────────────────────────────────

/// Create a new directory in the ext2 filesystem.
/// Supports multi-level paths (e.g., "testdir/subdir").
/// Returns file index (>= 0) on success, 0 if already exists, -1 on failure.
pub fn createDir(name: []const u8) i64 {
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
    const dir_block = allocBlock(0);
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
            if (i >= open_count) open_count = @intCast(i + 1);
            return @intCast(i);
        }
    }
    return -1;
}

// ─── Block / inode deallocation ────────────────────────────────────────────

/// Mark a data block as free in the bitmap.
fn freeBlock(block_num: u32) void {
    const group = (block_num - first_data_block) / sb.blocks_per_group;
    const index = (block_num - first_data_block) % sb.blocks_per_group;

    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];
    const bitmap_block = gd.bg_block_bitmap;

    const buf_phys = pmm.allocPage() orelse return;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    if (!readBlock(bitmap_block, buf)) return;

    const byte_idx = index / 8;
    const bit_idx: u3 = @intCast(index % 8);
    buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);

    if (!writeBlock(bitmap_block, buf)) return;

    gd.bg_free_blocks_count += 1;
    writeGroupDescs();

    sb.free_blocks_count += 1;
    writeSuperblock();
}

/// Mark an inode as free in the bitmap.
fn freeInode(inode_num: u32) void {
    const group = (inode_num - 1) / inodes_per_group;
    const index = (inode_num - 1) % inodes_per_group;

    const gds: [*]Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = &gds[group];
    const bitmap_block = gd.bg_inode_bitmap;

    const buf_phys = pmm.allocPage() orelse return;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    if (!readBlock(bitmap_block, buf)) return;

    const byte_idx = index / 8;
    const bit_idx: u3 = @intCast(index % 8);
    buf[byte_idx] &= ~(@as(u8, 1) << bit_idx);

    if (!writeBlock(bitmap_block, buf)) return;

    gd.bg_free_inodes_count += 1;
    writeGroupDescs();

    sb.free_inodes_count += 1;
    writeSuperblock();
}

// ─── Directory entry removal ───────────────────────────────────────────────

/// Remove a named entry from a parent directory.
/// Merges the deleted entry's rec_len into the previous entry if possible.
fn removeDirEntry(parent_inode_num: u32, name: []const u8) bool {
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
            const entry: *Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len == name.len) {
                const entry_name = buf[pos + @sizeOf(Ext2DirEntry) .. pos + @sizeOf(Ext2DirEntry) + name.len];
                var match = true;
                for (name, 0..) |c, j| {
                    if (entry_name[j] != c) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    // Found — remove by merging with previous or zeroing inode
                    if (prev_pos != 0xFFFF_FFFF) {
                        const prev: *Ext2DirEntry = @ptrCast(@alignCast(buf + prev_pos));
                        prev.rec_len += entry.rec_len;
                    } else {
                        // First entry in block — just zero inode
                        entry.inode = 0;
                    }

                    if (!writeBlock(phys_block, buf)) return false;
                    return true;
                }
            }

            prev_pos = pos;
            pos += entry.rec_len;
        }
        offset += block_size;
    }

    return false; // not found
}

// ─── File unlink ────────────────────────────────────────────────────────────

/// Unlink (delete) a file from the ext2 filesystem.
/// Supports multi-level paths, hardlinks, and symlinks (v50.0).
pub fn unlinkFile(path: []const u8) bool {
    if (!active) return false;

    // Resolve parent directory and filename
    const resolved = resolveParent(path) orelse return false;
    const parent_inode_num = resolved.parent;
    const filename = resolved.name;

    // Find the file's inode number via findDirEntry on parent
    var parent_inode: Ext2Inode = undefined;
    if (!readInode(parent_inode_num, &parent_inode)) return false;
    const file_inode_num = findDirEntry(&parent_inode, filename) orelse return false;

    // Read file inode
    var file_inode: Ext2Inode = undefined;
    if (!readInode(file_inode_num, &file_inode)) return false;

    const is_symlink = (file_inode.mode & 0xF000 == 0xA000);

    // v50.0: decrement links_count for hardlinked files
    if (file_inode.links_count > 1) {
        file_inode.links_count -= 1;
        _ = writeInode(file_inode_num, &file_inode);
    } else {
        // Last link: free data blocks
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

            // Free single indirect block (block[12]) and all blocks it points to
            if (file_inode.block[12] != 0) {
                const ib_phys = pmm.allocPage() orelse return false;
                const ib: [*]u8 = @ptrFromInt(hhdm.physToVirt(ib_phys));
                if (readBlock(file_inode.block[12], ib)) {
                    const ptrs_per_block = block_size / 4;
                    const ptrs: [*]const u32 = @ptrCast(@alignCast(ib));
                    for (0..ptrs_per_block) |i| {
                        if (ptrs[i] != 0) freeBlock(ptrs[i]);
                    }
                }
                pmm.freePage(ib_phys);
                freeBlock(file_inode.block[12]);
            }

            // Free double indirect block (block[13])
            if (file_inode.block[13] != 0) {
                freeBlock(file_inode.block[13]);
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
    if (!active) return -5; // EIO

    // 1. Resolve oldpath to its inode number
    const old_inode = walkPathToInode(oldpath) orelse return -2; // ENOENT

    // Read the old inode to check it's not a directory
    var old_inode_data: Ext2Inode = undefined;
    if (!readInode(old_inode, &old_inode_data)) return -5;

    if (old_inode_data.mode & 0xF000 == 0x4000) return -1; // EPERM: cannot hardlink directories

    // 2. Resolve newpath's parent directory + filename
    const resolved = resolveParent(newpath) orelse return -2;
    if (resolved.name.len == 0) return -2;

    // Check that newpath doesn't already exist
    var parent_check: Ext2Inode = undefined;
    if (readInode(resolved.parent, &parent_check)) {
        if (findDirEntry(&parent_check, resolved.name) != null) return -17; // EEXIST
    }

    // 3. Add directory entry pointing to old_inode with same file_type
    const ft: u8 = if (old_inode_data.mode & 0xF000 == 0x4000) 2 else 1;
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
    if (!active) return -5;

    // 1. Resolve linkpath's parent directory + filename
    const resolved = resolveParent(linkpath) orelse return -2;
    if (resolved.name.len == 0) return -2;

    // Check that linkpath doesn't already exist
    var parent_check: Ext2Inode = undefined;
    if (readInode(resolved.parent, &parent_check)) {
        if (findDirEntry(&parent_check, resolved.name) != null) return -17; // EEXIST
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
        const data_block = allocBlock(0);
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

/// Resolve a path to its inode number (without opening a file descriptor).
fn walkPathToInode(path: []const u8) ?u32 {
    var current_inode: u32 = 2; // root
    var pos: u32 = 0;

    while (pos < path.len) {
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos >= path.len) break;

        const start = pos;
        while (pos < path.len and path[pos] != '/') pos += 1;
        const component = path[start..pos];

        var inode: Ext2Inode = undefined;
        if (!readInode(current_inode, &inode)) return null;
        if (inode.mode & 0xF000 != 0x4000) return null; // not a directory

        current_inode = findDirEntry(&inode, component) orelse return null;
    }
    if (current_inode == 2 and path.len > 1) return null;
    return current_inode;
}

// ─── Public symlink target read (v50.0) ────────────────────────────────────

/// Read symlink target by path. Returns target slice or null.
/// Uses static symlink_buf for long symlinks (caller must copy before next call).
pub fn readSymlinkByPath(path: []const u8) ?[]const u8 {
    if (!active) return null;

    // Resolve parent and find the entry
    const resolved = resolveParent(path) orelse return null;
    var parent_inode: Ext2Inode = undefined;
    if (!readInode(resolved.parent, &parent_inode)) return null;
    const entry_inode_num = findDirEntry(&parent_inode, resolved.name) orelse return null;

    // Read the entry's inode and check it's a symlink
    var entry_inode: Ext2Inode = undefined;
    if (!readInode(entry_inode_num, &entry_inode)) return null;
    if (entry_inode.mode & 0xF000 != 0xA000) return null; // not a symlink

    return readSymlinkTarget(&entry_inode);
}

// ─── chown/chmod inode persistence (v51.0) ─────────────────────────────────

/// Set owner (uid/gid) for a path. Returns 0 on success, -errno on failure.
/// Pass -1 (0xFFFF) to leave uid or gid unchanged.
pub fn setOwner(path: []const u8, uid: u16, gid: u16) i64 {
    if (!active) return -5; // EIO

    const inode_num = walkPathToInode(path) orelse return -2; // ENOENT
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    if (uid != 0xFFFF) inode.uid = uid;
    if (gid != 0xFFFF) inode.gid = gid;
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Set owner (uid/gid) for an inode by number. Used by fchown via fd→inode mapping.
pub fn setOwnerByInode(inode_num: u32, uid: u16, gid: u16) i64 {
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
    if (!active) return -5;

    const inode_num = walkPathToInode(path) orelse return -2;
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    // Preserve file type bits (upper 4), replace permission bits (lower 12)
    inode.mode = (inode.mode & 0xF000) | (new_mode & 0x0FFF);
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Set permission mode for an inode by number. Used by fchmod via fd→inode mapping.
pub fn setModeByInode(inode_num: u32, new_mode: u16) i64 {
    if (!active) return -5;
    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return -5;

    inode.mode = (inode.mode & 0xF000) | (new_mode & 0x0FFF);
    if (!writeInode(inode_num, &inode)) return -5;
    return 0;
}

/// Get inode number from an open ext2 file index.
pub fn getInodeNumFromOpen(file_idx: u32) u32 {
    if (file_idx >= MAX_OPEN_FILES) return 0;
    return open_files[file_idx].inode_num;
}
