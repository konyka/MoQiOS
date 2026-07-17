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
const serial = @import("../arch/arch.zig").serial;
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const PAGE_SIZE: u64 = 4096;
const CACHE_SLOTS: u32 = 512;
const MAX_PAGES: u32 = 1024; // Max cached pages (4MB cached data)
const DIRTY_BM_WORDS: u32 = (MAX_PAGES + 63) / 64;

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
    inode_next: ?u16 = null, // Chain link in per-inode list
    lru_next: ?u16 = null, // Free list link (v53.39: LRU removed, Clock-only)
};

var pages: [MAX_PAGES]CachedPage = undefined;
var page_count: u32 = 0;

// Dirty bitmap: DIRTY_BM_WORDS x u64 = 1024 bits for MAX_PAGES slots
var dirty_bm: [DIRTY_BM_WORDS]u64 = @splat(0);

inline fn dirtySet(slot: u16) void {
    dirty_bm[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
}

inline fn dirtyClr(slot: u16) void {
    dirty_bm[slot / 64] &= ~(@as(u64, 1) << @intCast(slot % 64));
}

inline fn dirtyTest(slot: u16) bool {
    return (dirty_bm[slot / 64] & (@as(u64, 1) << @intCast(slot % 64))) != 0;
}

// Hash table
var hash_buckets: [CACHE_SLOTS]?u16 = @splat(null);

// Per-inode page lists: inode_list_heads[inode_id % INODE_LIST_SLOTS] → slot chain
const INODE_LIST_SLOTS: u32 = 256;
var inode_list_heads: [INODE_LIST_SLOTS]?u16 = @splat(null);

fn inodeListSlot(inode_id: u64) u32 {
    return @intCast(inode_id % INODE_LIST_SLOTS);
}

fn inodeListInsert(slot: u16) void {
    const s: usize = slot;
    const ls = inodeListSlot(pages[s].key.inode_id);
    pages[s].inode_next = inode_list_heads[ls];
    inode_list_heads[ls] = slot;
}

fn inodeListRemove(slot: u16) void {
    const s: usize = slot;
    const ls = inodeListSlot(pages[s].key.inode_id);
    var prev: ?u16 = null;
    var cur = inode_list_heads[ls];
    while (cur) |c| {
        if (c == slot) {
            if (prev) |p| {
                pages[p].inode_next = pages[s].inode_next;
            } else {
                inode_list_heads[ls] = pages[s].inode_next;
            }
            pages[s].inode_next = null;
            return;
        }
        prev = cur;
        cur = pages[c].inode_next;
    }
}

// Clock hand for replacement
var clock_hand: u32 = 0;

// Free list
var free_head: ?u16 = null;

var cache_lock: IrqSpinlock = .{};

// Hit/miss counters
var cache_hits: u64 = 0;
var cache_misses: u64 = 0;

var initialized: bool = false;

/// Initialize the page cache.
/// Idempotent: subsystem_boot / main / SK-33 may all call this.
pub fn init() void {
    if (initialized) return;
    // Initialize all pages as free
    for (0..MAX_PAGES) |i| {
        pages[i].valid = false;
        pages[i].phys = 0;
        pages[i].data = undefined;
        pages[i].dirty = false;
        pages[i].hash_next = null;
        pages[i].inode_next = null;
        if (i + 1 < MAX_PAGES) {
            pages[i].lru_next = @intCast(i + 1);
        } else {
            pages[i].lru_next = null;
        }
    }
    free_head = 0;
    page_count = 0;
    clock_hand = 0;
    dirty_bm = @splat(0);
    cache_hits = 0;
    cache_misses = 0;
    for (0..INODE_LIST_SLOTS) |i| inode_list_heads[i] = null;
    for (0..CACHE_SLOTS) |i| hash_buckets[i] = null;
    initialized = true;
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
            cache_hits += 1;
            pages[s].referenced = true;
            return pages[s].data;
        }
        slot = pages[s].hash_next;
    }

    cache_misses += 1;
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
            dirtySet(s);
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
    dirtySet(new_slot);

    // Copy data
    @memcpy(pages[new_slot].data, src_data);

    // Insert into hash bucket (at head)
    pages[new_slot].hash_next = hash_buckets[bucket];
    hash_buckets[bucket] = @intCast(new_slot);

    // Insert into per-inode list
    inodeListInsert(new_slot);

    page_count += 1;
    return pages[new_slot].data;
}

/// Update a cached page if it exists (no allocation, no PMM locks).
/// Atomically checks + updates under cache_lock — fixes SMP TOCTOU race
/// where readPage returns null but a concurrent insertPage caches stale data.
/// Returns true if the page was found and updated, false if not cached.
pub fn updateIfCached(inode_id: u64, page_offset: u64, src_data: *const [PAGE_SIZE]u8) bool {
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
            @memcpy(pages[s].data, src_data);
            pages[s].dirty = true;
            pages[s].referenced = true;
            dirtySet(s);
            return true;
        }
        slot = pages[s].hash_next;
    }
    return false;
}

/// Insert a page into the cache from a disk read (not dirty).
pub fn insertPage(inode_id: u64, page_offset: u64, data: *const [PAGE_SIZE]u8, data_len: u32) ?*[PAGE_SIZE]u8 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    const key = CacheKey{ .inode_id = inode_id, .page_offset = page_offset };
    const bucket = hashKey(key);

    const new_slot = allocSlot() orelse return null;

    pages[new_slot].key = key;
    pages[new_slot].valid = true;
    pages[new_slot].dirty = false;
    pages[new_slot].referenced = true;

    // v53.34: Only copy data_len bytes, zero-fill the rest.
    @memcpy(pages[new_slot].data[0..data_len], data[0..data_len]);
    if (data_len < PAGE_SIZE) {
        @memset(pages[new_slot].data[data_len..PAGE_SIZE], 0);
    }

    pages[new_slot].hash_next = hash_buckets[bucket];
    hash_buckets[bucket] = @intCast(new_slot);

    inodeListInsert(new_slot);

    page_count += 1;

    return pages[new_slot].data;
}

/// Insert a page using a pre-allocated physical page (ownership transfer, v53.42).
/// Avoids redundant pmm.allocPage + memcpy in the caller.
/// On failure (cache full), returns null — caller must freePage(phys).
pub fn insertPageOwned(inode_id: u64, page_offset: u64, phys: u64, data_len: u32) ?*[PAGE_SIZE]u8 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    const key = CacheKey{ .inode_id = inode_id, .page_offset = page_offset };
    const bucket = hashKey(key);

    const new_slot = allocSlotOwned(phys) orelse return null;

    pages[new_slot].key = key;
    pages[new_slot].valid = true;
    pages[new_slot].dirty = false;
    pages[new_slot].referenced = true;

    // No memcpy needed — data is already in the physical page.
    // Zero-fill the remainder (data_len..PAGE_SIZE).
    if (data_len < PAGE_SIZE) {
        @memset(pages[new_slot].data[data_len..PAGE_SIZE], 0);
    }

    pages[new_slot].hash_next = hash_buckets[bucket];
    hash_buckets[bucket] = @intCast(new_slot);

    inodeListInsert(new_slot);

    page_count += 1;

    return pages[new_slot].data;
}

/// Flush all dirty pages for a given inode.
/// Calls the provided writeback function for each dirty page.
/// Uses per-inode linked list for O(pages_of_inode) instead of O(MAX_PAGES).
pub fn flushInode(inode_id: u64, writeback_fn: *const fn (u64, u64, *[PAGE_SIZE]u8) bool) u32 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    var flushed: u32 = 0;
    var slot = inode_list_heads[inodeListSlot(inode_id)];
    while (slot) |s| {
        const next = pages[s].inode_next;
        if (pages[s].valid and pages[s].dirty and pages[s].key.inode_id == inode_id) {
            if (writeback_fn(inode_id, pages[s].key.page_offset, pages[s].data)) {
                pages[s].dirty = false;
                dirtyClr(s);
                flushed += 1;
            }
        }
        slot = next;
    }
    return flushed;
}

/// Flush ALL dirty pages.
pub fn flushAll(writeback_fn: *const fn (u64, u64, *[PAGE_SIZE]u8) bool) u32 {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    var flushed: u32 = 0;
    // Iterate dirty bitmap: skip entire u64 groups with no dirty pages
    for (0..dirty_bm.len) |grp| {
        var bm = dirty_bm[grp];
        while (bm != 0) {
            const bit = @ctz(bm);
            bm &= bm - 1;
            const i: u16 = @intCast(grp * 64 + bit);
            if (!pages[i].valid or !pages[i].dirty) continue;
            if (writeback_fn(pages[i].key.inode_id, pages[i].key.page_offset, pages[i].data)) {
                pages[i].dirty = false;
                dirtyClr(i);
                flushed += 1;
            }
        }
    }
    return flushed;
}

/// Invalidate all cached pages for a given inode.
/// Uses per-inode linked list for O(pages_of_inode) instead of O(MAX_PAGES).
pub fn invalidateInode(inode_id: u64) void {
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);

    var slot = inode_list_heads[inodeListSlot(inode_id)];
    while (slot) |s| {
        const next = pages[s].inode_next;
        if (pages[s].valid and pages[s].key.inode_id == inode_id) {
            removePage(@intCast(s));
        }
        slot = next;
    }
}

/// Get cache statistics.
pub fn getStats() struct { total: u32, dirty: u32, hits: u64, misses: u64 } {
    var dirty_count: u32 = 0;
    for (0..dirty_bm.len) |grp| {
        dirty_count += @popCount(dirty_bm[grp]);
    }
    return .{ .total = page_count, .dirty = dirty_count, .hits = cache_hits, .misses = cache_misses };
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

        // v53.39: Don't evict dirty pages — data would be lost (Critical fix)
        if (dirtyTest(@intCast(i))) continue;

        // v53.41: Evict but keep physical page — avoids free+alloc pair (2 PMM lock ops)
        removePageKeepPhys(@intCast(i));
        return @intCast(i);
    }

    return null; // All pages are referenced
}

/// Allocate a cache slot using a pre-allocated physical page (v53.42).
/// Used by insertPageOwned to avoid redundant pmm.allocPage + memcpy.
fn allocSlotOwned(phys: u64) ?u16 {
    // First, try the free list
    if (free_head) |s| {
        const slot = s;
        pages[slot].phys = phys;
        pages[slot].data = @ptrFromInt(hhdm.physToVirt(phys));
        free_head = pages[slot].lru_next;
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
            pages[i].referenced = false;
            continue;
        }

        if (dirtyTest(@intCast(i))) continue;

        // v53.42: Evict, free old physical page, then use caller's page
        removePageKeepPhys(@intCast(i));
        if (pages[i].phys != 0) {
            pmm.freePage(pages[i].phys);
        }
        pages[i].phys = phys;
        pages[i].data = @ptrFromInt(hhdm.physToVirt(phys));
        return @intCast(i);
    }

    return null;
}

/// Remove a page from the cache (hash bucket + free list).
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

    // Remove from per-inode list
    inodeListRemove(slot);

    // v53.39: LRU list removed — Clock algorithm is sole eviction policy

    // Free physical page
    if (pages[s].phys != 0) {
        pmm.freePage(pages[s].phys);
    }

    pages[s].valid = false;
    pages[s].phys = 0;
    pages[s].dirty = false;
    dirtyClr(slot);
    pages[s].hash_next = null;
    // v53.39: Add to free list (single-linked via lru_next)
    pages[s].lru_next = free_head;
    free_head = slot;
    page_count -= 1;
}

/// Remove a page from the cache but keep its physical page allocated (v53.41).
/// Used by allocSlot eviction path to avoid free+alloc pair.
fn removePageKeepPhys(slot: u16) void {
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

    // Remove from per-inode list
    inodeListRemove(slot);

    // Keep physical page (pages[s].phys and pages[s].data unchanged)
    pages[s].valid = false;
    pages[s].dirty = false;
    dirtyClr(slot);
    pages[s].hash_next = null;
    page_count -= 1;
}

/// Prefetch window: number of pages to prefetch on sequential access detection.
/// v51.0: doubled from 4 to 8 for better large-file sequential read throughput.
const PREFETCH_WINDOW: u32 = 8;

/// Per-inode sequential access tracker (lightweight, max 8 tracked inodes).
const PrefetchTracker = struct {
    inode_id: u64 = 0,
    last_page: u64 = 0,
    sequential_count: u32 = 0, // consecutive sequential hits
    active: bool = false,
};
const MAX_PREFETCH_TRACK: u32 = 32;
var prefetch_trackers: [MAX_PREFETCH_TRACK]PrefetchTracker = @splat(.{});

/// Record a page access and return a prefetch hint.
/// Returns the number of pages ahead to prefetch (0 if no prefetch needed).
/// Detects sequential access: 2+ consecutive page offsets trigger prefetch.
/// Record a page access and return a prefetch hint (internal — caller must hold cache_lock).
fn recordAccessLocked(inode_id: u64, page_offset: u64) u32 {
    // Find or allocate tracker for this inode
    var tracker: ?*PrefetchTracker = null;
    for (&prefetch_trackers) |*t| {
        if (t.active and t.inode_id == inode_id) {
            tracker = t;
            break;
        }
    }
    if (tracker == null) {
        // Allocate a new tracker (overwrite oldest inactive or first)
        for (&prefetch_trackers) |*t| {
            if (!t.active) {
                tracker = t;
                break;
            }
        }
        if (tracker == null) tracker = &prefetch_trackers[0]; // overwrite first
        tracker.?.* = .{
            .inode_id = inode_id,
            .last_page = page_offset,
            .sequential_count = 0,
            .active = true,
        };
        return 0; // First access, no prefetch
    }

    const t = tracker.?;
    const expected = t.last_page + 1;
    t.last_page = page_offset;

    if (page_offset == expected) {
        // Sequential access detected
        t.sequential_count += 1;
        if (t.sequential_count >= 1) {
            // Prefetch PREFETCH_WINDOW pages ahead
            return PREFETCH_WINDOW;
        }
    } else {
        // Non-sequential — reset counter
        t.sequential_count = 0;
    }
    return 0;
}

/// Record a page access and return a prefetch hint.
/// Returns the number of pages ahead to prefetch (0 if no prefetch needed).
/// Detects sequential access: 2+ consecutive page offsets trigger prefetch.
pub fn recordAccess(inode_id: u64, page_offset: u64) u32 {
    // v53.39: Acquire cache_lock — prefetch_trackers is global (SMP race fix)
    const flags = cache_lock.acquire();
    defer cache_lock.release(flags);
    return recordAccessLocked(inode_id, page_offset);
}

/// Read a page from cache and record access in a single lock acquisition (v53.41).
/// Returns the cached data pointer and prefetch hint, or null if not cached.
pub fn readPageAndRecord(inode_id: u64, page_offset: u64) ?struct { data: *[PAGE_SIZE]u8, prefetch: u32 } {
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
            cache_hits += 1;
            pages[s].referenced = true;
            const pf_count = recordAccessLocked(inode_id, page_offset);
            return .{ .data = pages[s].data, .prefetch = pf_count };
        }
        slot = pages[s].hash_next;
    }

    cache_misses += 1;
    return null;
}

/// Check if a page is already cached (without updating LRU/referenced).
pub fn isCached(inode_id: u64, page_offset: u64) bool {
    // v53.39: Acquire cache_lock — hash_buckets is global (SMP race fix)
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
            return true;
        }
        slot = pages[s].hash_next;
    }
    return false;
}
