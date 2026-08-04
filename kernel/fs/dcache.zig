//! Directory-entry cache (dcache, K1).
//!
//! Caches (fs_kind, parent_id, name) → child_id positive lookups so path
//! resolution can skip the on-disk directory scan:
//!   - ext2:  parent_id = parent directory inode number, child_id = child inode.
//!            Consulted per path component in findDirEntryCached (ext2.zig);
//!            a hit skips the directory-block reads.
//!   - fat32: parent_id = owning directory cluster (only the fixed root
//!            cluster is cached — fat32.openFile resolves root entries),
//!            child_id = the files[] slot index; a hit skips the linear scan.
//!
//! Design: `CAPACITY` entries, direct-mapped by hash with replace-on-conflict
//! (first cut — no chaining, no LRU). Only successful ("positive") lookups are
//! cached; a miss on the slow path fills the entry.
//!
//! Invalidation policy (conservative — a wrong hit is corruption):
//!   - ext2 addDirEntry / removeDirEntry (covers createFile/createDir/unlink/
//!     rename/hardlink/symlink): drop every entry keyed by the modified
//!     directory's inode, AND every entry keyed by the child's inode as parent
//!     (the child may be a directory whose contents are being abandoned, and
//!     its inode number may later be reused).
//!   - fat32 createFile / deleteFile: full flush of all .fat32 entries —
//!     createFile may reuse a tombstoned files[] slot under a different name,
//!     so per-parent tracking of slot indices is not trustworthy. Documented
//!     cost: fat32 only ever caches the root directory anyway.
//!
//! Concurrency: one IrqSpinlock (`lock`) guards the whole table. It is a leaf
//! lock, acquired only inside the pub glue wrappers below — callers hold
//! fs_lock, take dcache.lock briefly for a table consult/fill, and release it
//! before any I/O. Lock order: fs_lock → dcache.lock (never the reverse, and
//! dcache.lock is never held across an FS call).
//!
//! The `*Pure` functions are the lock-free core, shared by the glue and by
//! the host tests (tests/main.zig "K1" block) — do not call them from kernel
//! code without holding `lock`.
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

pub const FsKind = enum(u8) {
    ext2 = 0,
    fat32 = 1,
};

/// Fixed table size; must stay a power of two (slotFor masks with CAPACITY-1).
pub const CAPACITY: usize = 512;

/// Longest cached name (ext2/fat32 on-disk name_len is a u8).
const MAX_NAME: usize = 255;

const Entry = struct {
    valid: bool = false,
    fs: FsKind = .ext2,
    parent: u32 = 0,
    name_hash: u32 = 0,
    name_len: u8 = 0,
    name: [MAX_NAME]u8 = @splat(0),
    child: u32 = 0,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    fills: u64 = 0,
    invalidated: u64 = 0,
};

var entries: [CAPACITY]Entry = @splat(.{});
var stat_hits: u64 = 0;
var stat_misses: u64 = 0;
var stat_fills: u64 = 0;
var stat_invalidated: u64 = 0;

var lock: IrqSpinlock = .{};

// ─── Pure core (host-testable; kernel callers must hold `lock`) ────────────

/// FNV-1a over the name bytes.
pub fn hashName(name: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (name) |c| {
        h ^= c;
        h *%= 0x01000193;
    }
    return h;
}

/// Direct-mapped slot for a key. Pub so host tests can construct collisions.
pub fn slotFor(fs: FsKind, parent: u32, name_hash: u32) usize {
    var x = name_hash;
    x ^= parent *% 0x9E3779B1;
    x ^= @as(u32, @intFromEnum(fs)) *% 0x85EBCA6B;
    x ^= x >> 16;
    x *%= 0x45d9f3b;
    x ^= x >> 16;
    return @intCast(x & (CAPACITY - 1));
}

fn cacheable(name: []const u8) bool {
    return name.len > 0 and name.len <= MAX_NAME;
}

fn entryMatches(e: *const Entry, fs: FsKind, parent: u32, name_hash: u32, name: []const u8) bool {
    if (!e.valid) return false;
    if (e.fs != fs or e.parent != parent) return false;
    if (e.name_hash != name_hash or e.name_len != name.len) return false;
    for (name, 0..) |c, i| {
        if (e.name[i] != c) return false;
    }
    return true;
}

/// Positive-lookup probe. Returns the cached child id on a full-key hit.
pub fn lookupPure(fs: FsKind, parent: u32, name: []const u8) ?u32 {
    if (!cacheable(name)) return null;
    const h = hashName(name);
    const e = &entries[slotFor(fs, parent, h)];
    if (entryMatches(e, fs, parent, h, name)) {
        stat_hits += 1;
        return e.child;
    }
    stat_misses += 1;
    return null;
}

/// Insert/refresh an entry, replacing whatever occupies the slot.
pub fn fillPure(fs: FsKind, parent: u32, name: []const u8, child: u32) void {
    if (!cacheable(name)) return;
    const h = hashName(name);
    const e = &entries[slotFor(fs, parent, h)];
    e.* = .{
        .valid = true,
        .fs = fs,
        .parent = parent,
        .name_hash = h,
        .name_len = @intCast(name.len),
        .name = @splat(0),
        .child = child,
    };
    @memcpy(e.name[0..name.len], name);
    stat_fills += 1;
}

/// Drop every entry keyed by (fs, parent). Returns how many were dropped.
pub fn invalidateParentPure(fs: FsKind, parent: u32) u32 {
    var dropped: u32 = 0;
    for (&entries) |*e| {
        if (e.valid and e.fs == fs and e.parent == parent) {
            e.valid = false;
            dropped += 1;
        }
    }
    stat_invalidated += dropped;
    return dropped;
}

/// Drop every entry of one filesystem (conservative full flush).
pub fn invalidateFsPure(fs: FsKind) u32 {
    var dropped: u32 = 0;
    for (&entries) |*e| {
        if (e.valid and e.fs == fs) {
            e.valid = false;
            dropped += 1;
        }
    }
    stat_invalidated += dropped;
    return dropped;
}

/// Number of live entries (test/diagnostic aid).
pub fn countValidPure() u32 {
    var n: u32 = 0;
    for (&entries) |*e| {
        if (e.valid) n += 1;
    }
    return n;
}

pub fn statsPure() Stats {
    return .{
        .hits = stat_hits,
        .misses = stat_misses,
        .fills = stat_fills,
        .invalidated = stat_invalidated,
    };
}

/// Clear the whole table and the counters (host tests start from a known state).
pub fn resetPure() void {
    entries = @splat(.{});
    stat_hits = 0;
    stat_misses = 0;
    stat_fills = 0;
    stat_invalidated = 0;
}

// ─── Kernel glue (leaf spinlock; no I/O, no FS calls under the lock) ───────

pub fn lookup(fs: FsKind, parent: u32, name: []const u8) ?u32 {
    const flags = lock.acquire();
    defer lock.release(flags);
    return lookupPure(fs, parent, name);
}

pub fn fill(fs: FsKind, parent: u32, name: []const u8, child: u32) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    fillPure(fs, parent, name, child);
}

pub fn invalidateParent(fs: FsKind, parent: u32) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    _ = invalidateParentPure(fs, parent);
}

pub fn invalidateFs(fs: FsKind) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    _ = invalidateFsPure(fs);
}

pub fn stats() Stats {
    const flags = lock.acquire();
    defer lock.release(flags);
    return statsPure();
}
