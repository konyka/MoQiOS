/// Unified Page Cache — global cache for file-backed pages.
///
/// Replaces the separate block caches in ext2 and FAT32 with a single
/// hash-table-based cache indexed by (inode_id, page_offset).
///
/// Features:
///   - 128-entry hash table with chained collision resolution
///   - Clock (second-chance) replacement policy
///   - Dirty page tracking for writeback
///   - Integration with ext2/fat32 via readPage/writePage API
///
/// The page cache sits between VFS and block device drivers:
///   readPage(inode, offset) → check cache → miss → read from disk → cache
///   writePage(inode, offset, data) → write to cache → mark dirty → writeback

const serial = @import("../arch/x86_64/serial.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const PAGE_SIZE: u64 = 4096;
const CACHE_SLOTS: u32 = 128;
const MAX_PAGES: u32 = 256; // Max cached pages

pub const CacheKey = struct {
    inode_id: u64,
    page_offset: u64, // In pages (not bytes)
};

pub const CachedPage = struct {
    key: CacheKey,
    phys: u64, // Physical page address
    data: *[PAGE_SIZE]u8, // Virtual pointer (via HHDM)
    dirty: bool = false,
    referenced: bool = true, // For clock algorithm
    valid: bool = false,
    hash_next: ?u16 = null, // Chain link in hash bucket
    lru_next: ?u16 = null, // LRU list link
    lru_prev: ?u16 = null,
};

var pages: [MAX_PAGES]CachedPage = undefined;
var page_count: u32 = 0;

// Hash table
var hash_buckets: [CACHE_SLOTS]?u16 = @splat(null);

// LRU list (doubly-linked, most-recent at head)
var lru_head: ?u16 = null;
var lru_tail: ?u16 = null;

// Clock hand for replacement
var clock_hand: u32 = 0;

// Free list
var free_head: ?u16 = null;

var cache_lock: IrqSpinlock = .{};

/// Initialize the page cache.
pub fn init() void {
    // Initialize all pages as free
    for (0..MAX_PAGES) |i| {
        pages[i].valid = false;
        pages[i].phys = 0;
        pages[i].data = undefined;
        pages[i].dirty = false;
        pages[i].hash_next = null;
        pages[i].lru_prev = null;
        if (i + 1 < MAX_PAGES) {
            pages[i].lru_next = @intCast(i + 1);
        } else {
            pages[i].lru_next = null;
        }
    }
    free_head = 0;
    page_count = 0;
    lru_head = null;
    lru_tail = null;
    clock_hand = 0;
}

/// Hash function for cache key.
fn hashKey(key: CacheKey) u32 {
    var h: u64 = key.inode_id;
    h ^= key.page_offset *% 0x9E3779B97F4A7C15;
    h ^= h >> 33;
    h *%= 0xFF51AFD7ED558CCD;
    h ^= h >> 33;
    h *%= 0xC4CEB9FE1A85EC53;
    h ^= h >> 33;
    return @truncate(h % CACHE_SLOTS);
}

/// Look up a page in the cache.
/// Returns a pointer to the cached data, or null if not cached.
pub fn readPage(inode_id: u64, page_offset: u64) ?*[PAGE_SIZE]u8 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    const key = CacheKey{ .inode_id = inode_id, .page_offset = page_offset };
    const bucket = hashKey(key);

    var slot = hash_buckets[bucket];
    while (slot) |s| {
        if (pages[s].valid and
            pages[s].key.inode_id == inode_id and
            pages[s].key.page_offset == page_offset)
        {
            // Cache hit
            pages[s].referenced = true;
            // Move to LRU head
            moveToHead(s);
            return pages[s].data;
        }
        slot = pages[s].hash_next;
    }

    return null;
}

/// Write a page to the cache (marks dirty for writeback).
/// Returns the cache slot where the data was stored.
pub fn writePage(inode_id: u64, page_offset: u64, src_data: *const [PAGE_SIZE]u8) ?*[PAGE_SIZE]u8 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    const key = CacheKey{ .inode_id = inode_id, .page_offset = page_offset };
    const bucket = hashKey(key);

    // Check if already cached
    var slot = hash_buckets[bucket];
    while (slot) |s| {
        if (pages[s].valid and
            pages[s].key.inode_id == inode_id and
            pages[s].key.page_offset == page_offset)
        {
            // Update existing entry
            @memcpy(pages[s].data, src_data);
            pages[s].dirty = true;
            pages[s].referenced = true;
            moveToHead(s);
            return pages[s].data;
        }
        slot = pages[s].hash_next;
    }

    // Allocate a new cache entry
    const new_slot = allocSlot() orelse return null;

    // Initialize the entry
    pages[new_slot].key = key;
    pages[new_slot].valid = true;
    pages[new_slot].dirty = true;
    pages[new_slot].referenced = true;

    // Copy data
    @memcpy(pages[new_slot].data, src_data);

    // Insert into hash bucket (at head)
    pages[new_slot].hash_next = hash_buckets[bucket];
    hash_buckets[bucket] = @intCast(new_slot);

    // Insert into LRU list at head
    moveToHead(new_slot);

    page_count += 1;
    return pages[new_slot].data;
}

/// Insert a page into the cache from a disk read (not dirty).
pub fn insertPage(inode_id: u64, page_offset: u64, data: *const [PAGE_SIZE]u8) ?*[PAGE_SIZE]u8 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    const key = CacheKey{ .inode_id = inode_id, .page_offset = page_offset };
    const bucket = hashKey(key);

    const new_slot = allocSlot() orelse return null;

    pages[new_slot].key = key;
    pages[new_slot].valid = true;
    pages[new_slot].dirty = false;
    pages[new_slot].referenced = true;

    @memcpy(pages[new_slot].data, data);

    pages[new_slot].hash_next = hash_buckets[bucket];
    hash_buckets[bucket] = @intCast(new_slot);

    moveToHead(new_slot);
    page_count += 1;

    return pages[new_slot].data;
}

/// Flush all dirty pages for a given inode.
/// Calls the provided writeback function for each dirty page.
pub fn flushInode(inode_id: u64, writeback_fn: *const fn (u64, u64, *[PAGE_SIZE]u8) bool) u32 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    var flushed: u32 = 0;
    for (0..MAX_PAGES) |i| {
        if (pages[i].valid and pages[i].dirty and pages[i].key.inode_id == inode_id) {
            if (writeback_fn(inode_id, pages[i].key.page_offset, pages[i].data)) {
                pages[i].dirty = false;
                flushed += 1;
            }
        }
    }
    return flushed;
}

/// Flush ALL dirty pages.
pub fn flushAll(writeback_fn: *const fn (u64, u64, *[PAGE_SIZE]u8) bool) u32 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    var flushed: u32 = 0;
    for (0..MAX_PAGES) |i| {
        if (pages[i].valid and pages[i].dirty) {
            if (writeback_fn(pages[i].key.inode_id, pages[i].key.page_offset, pages[i].data)) {
                pages[i].dirty = false;
                flushed += 1;
            }
        }
    }
    return flushed;
}

/// Invalidate all cached pages for a given inode.
pub fn invalidateInode(inode_id: u64) void {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    for (0..MAX_PAGES) |i| {
        if (pages[i].valid and pages[i].key.inode_id == inode_id) {
            removePage(@intCast(i));
        }
    }
}

/// Get cache statistics.
pub fn getStats() struct { total: u32, dirty: u32, hits: u64, misses: u64 } {
    var dirty_count: u32 = 0;
    for (0..MAX_PAGES) |i| {
        if (pages[i].valid and pages[i].dirty) dirty_count += 1;
    }
    return .{ .total = page_count, .dirty = dirty_count, .hits = 0, .misses = 0 };
}

/// Allocate a cache slot, evicting if necessary using clock algorithm.
fn allocSlot() ?u16 {
    // First, try the free list
    if (free_head) |s| {
        const slot = s;
        // Allocate physical page for this slot
        const phys = pmm.allocPage() orelse return null;
        pages[slot].phys = phys;
        pages[slot].data = @ptrFromInt(hhdm.physToVirt(phys));
        free_head = pages[slot].lru_next;
        if (free_head) |fh| {
            pages[fh].lru_prev = null;
        }
        return slot;
    }

    // No free slots — evict using clock algorithm
    var attempts: u32 = 0;
    while (attempts < MAX_PAGES * 2) : (attempts += 1) {
        if (clock_hand >= MAX_PAGES) clock_hand = 0;
        const i = clock_hand;
        clock_hand += 1;

        if (!pages[i].valid) continue;

        if (pages[i].referenced) {
            // Second chance: clear reference bit
            pages[i].referenced = false;
            continue;
        }

        // Evict this page (removePage frees the physical page and returns slot to free list)
        removePage(@intCast(i));

        // Now allocate from free list (should succeed since we just freed one)
        if (free_head) |s| {
            const slot = s;
            const phys = pmm.allocPage() orelse return null;
            pages[slot].phys = phys;
            pages[slot].data = @ptrFromInt(hhdm.physToVirt(phys));
            free_head = pages[slot].lru_next;
            if (free_head) |fh| {
                pages[fh].lru_prev = null;
            }
            return slot;
        }
    }

    return null; // All pages are referenced
}

/// Remove a page from the cache (hash bucket + LRU list).
fn removePage(slot: u16) void {
    const s: usize = slot;

    if (!pages[s].valid) return;

    // Remove from hash bucket
    const bucket = hashKey(pages[s].key);
    var prev: ?u16 = null;
    var current = hash_buckets[bucket];
    while (current) |c| {
        if (c == slot) {
            if (prev) |p| {
                pages[p].hash_next = pages[s].hash_next;
            } else {
                hash_buckets[bucket] = pages[s].hash_next;
            }
            break;
        }
        prev = current;
        current = pages[c].hash_next;
    }

    // Remove from LRU list
    if (pages[s].lru_prev) |p| {
        pages[p].lru_next = pages[s].lru_next;
    } else {
        lru_head = pages[s].lru_next;
    }
    if (pages[s].lru_next) |n| {
        pages[n].lru_prev = pages[s].lru_prev;
    } else {
        lru_tail = pages[s].lru_prev;
    }

    // Free physical page
    if (pages[s].phys != 0) {
        pmm.freePage(pages[s].phys);
    }

    pages[s].valid = false;
    pages[s].phys = 0;
    pages[s].dirty = false;
    pages[s].hash_next = null;
    pages[s].lru_next = free_head;
    pages[s].lru_prev = null;
    if (free_head) |fh| {
        pages[fh].lru_prev = slot;
    }
    free_head = slot;
    page_count -= 1;
}

/// Move a page to the head of the LRU list.
fn moveToHead(slot: u16) void {
    const s: usize = slot;

    // Remove from current position
    if (pages[s].lru_prev) |p| {
        pages[p].lru_next = pages[s].lru_next;
    } else {
        lru_head = pages[s].lru_next;
    }
    if (pages[s].lru_next) |n| {
        pages[n].lru_prev = pages[s].lru_prev;
    } else {
        lru_tail = pages[s].lru_prev;
    }

    // Insert at head
    pages[s].lru_prev = null;
    pages[s].lru_next = lru_head;
    if (lru_head) |h| {
        pages[h].lru_prev = slot;
    }
    lru_head = slot;
    if (lru_tail == null) {
        lru_tail = slot;
    }
}