//! Kernel glue for the read-only ext4/ext3/ext2 and NTFS drivers.
//!
//! A mounted volume is a block device plus a byte window (partition start and
//! length); mounts live in a small fixed table and are addressed by slot.
//! Reads go through a per-mount 4 KiB page cache (direct-mapped, LRU-free) so
//! the parsers' many tiny metadata reads do not each hit the device.
//!
//! One lock (`rofs_lock`) serialises every operation: the parsers carry shared
//! scratch buffers and the cache is not re-entrant. Holding it across device
//! I/O is deliberate and cheap here (read-only, small volumes).

const std = @import("std");
const builtin = @import("builtin");
const fr = @import("fs_reader.zig");
const ext4 = @import("ext4.zig");
const ntfs = @import("ntfs.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const serial = @import("../arch/arch.zig").serial;
const block_dev = @import("../drivers/block_dev.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const access = @import("rofs_access_policy.zig");

pub const MAX_MOUNTS: usize = 4;
const SECTOR: u64 = 512;
const CACHE_PAGES: usize = 16; // per mount
const PAGE: u64 = 4096;

pub const FsKind = enum(u8) { none = 0, ext4 = 1, ntfs = 2 };

pub const Error = ext4.Error;
pub const Creds = access.Creds;

const CachePage = struct {
    valid: bool = false,
    page_no: u64 = 0,
    data: [PAGE]u8 align(8) = undefined,
};

const Mount = struct {
    active: bool = false,
    kind: FsKind = .none,
    dev: u8 = 0,
    /// Volume window on the device, in bytes.
    base: u64 = 0,
    len: u64 = 0,
    ext4_vol: ext4.Volume = undefined,
    ntfs_vol: ntfs.Volume = undefined,
    /// DMA-safe bounce page (device reads must target PMM memory, not BSS).
    bounce_phys: u64 = 0,
    cache: [CACHE_PAGES]CachePage = undefined,
    /// NTFS needs per-level index-block buffers; allocated on mount.
    scratch: ?*ntfs.Scratch = null,
    scratch_phys: u64 = 0,
    scratch_pages: usize = 0,
    /// Bumped on every mount into this slot. File descriptors carry the value
    /// they were opened under, so one that outlives its mount (or sees the slot
    /// reused for another volume) fails instead of reading the wrong data.
    generation: u32 = 0,
    label: [32]u8 = @splat(0),
    label_len: u8 = 0,
};

var rofs_lock: IrqSpinlock = .{};
var mounts: [MAX_MOUNTS]Mount = @splat(.{});
var next_generation: u32 = 1;

// ─── Cached byte reader ─────────────────────────────────────────────────

fn deviceRead(m: *Mount, page_no: u64, out: *[PAGE]u8) bool {
    const byte = m.base + page_no * PAGE;
    if (byte + PAGE > m.base + m.len + PAGE - 1) return false;
    var done: u64 = 0;
    const bounce: [*]u8 = @ptrFromInt(hhdm.physToVirt(m.bounce_phys));
    while (done < PAGE) {
        const abs = byte + done;
        const lba = abs / SECTOR;
        // The final page of a volume may be short: read what exists, zero the rest.
        const volume_end = m.base + m.len;
        if (abs >= volume_end) {
            @memset(out[@intCast(done)..], 0);
            return true;
        }
        const sectors: u32 = @intCast(@min(@as(u64, 8), (PAGE - done) / SECTOR));
        const avail = (volume_end - abs + SECTOR - 1) / SECTOR;
        const n: u32 = @intCast(@min(@as(u64, sectors), avail));
        if (block_dev.readSectors(m.dev, lba, n, bounce) != 0) return false;
        @memcpy(out[@intCast(done)..][0 .. n * SECTOR], bounce[0 .. n * SECTOR]);
        done += n * SECTOR;
        if (n < sectors) {
            @memset(out[@intCast(done)..], 0);
            return true;
        }
    }
    return true;
}

fn readFn(ctx: *anyopaque, offset: u64, buf: []u8) bool {
    const m: *Mount = @ptrCast(@alignCast(ctx));
    if (buf.len == 0) return true;
    if (offset > m.len or buf.len > m.len - offset) return false;
    var done: usize = 0;
    while (done < buf.len) {
        const pos = offset + done;
        const page_no = pos / PAGE;
        const slot = &m.cache[@intCast(page_no % CACHE_PAGES)];
        if (!slot.valid or slot.page_no != page_no) {
            if (!deviceRead(m, page_no, &slot.data)) {
                slot.valid = false;
                return false;
            }
            slot.page_no = page_no;
            slot.valid = true;
        }
        const poff: usize = @intCast(pos % PAGE);
        const n = @min(buf.len - done, PAGE - poff);
        @memcpy(buf[done..][0..n], slot.data[poff..][0..n]);
        done += n;
    }
    return true;
}

fn readerFor(m: *Mount) fr.Reader {
    return .{ .ctx = m, .read_fn = readFn };
}

// ─── Mount / unmount ────────────────────────────────────────────────────

pub const MountError = error{ NoDevice, BadFs, NoSlot, Busy, NoMemory, Range };

fn freeMountMem(m: *Mount) void {
    if (m.bounce_phys != 0) pmm.freePage(m.bounce_phys);
    m.bounce_phys = 0;
    if (m.scratch_phys != 0) pmm.freeContiguous(m.scratch_phys, m.scratch_pages);
    m.scratch_phys = 0;
    m.scratch = null;
}

fn sniff(m: *Mount) ?FsKind {
    var b: [1024 + 2]u8 = undefined;
    const rd = readerFor(m);
    if (!rd.read(0, b[0..512])) return null;
    if (std.mem.eql(u8, b[3..11], "NTFS    ")) return .ntfs;
    if (!rd.read(1024, b[0..64])) return null;
    if (std.mem.readInt(u16, b[0x38..][0..2], .little) == 0xEF53) return .ext4;
    return null;
}

/// Mount the volume at [base, base+len) bytes of block device `dev`.
/// `want` forces a type (null = detect). Returns the mount slot.
pub fn mountVolume(dev: u8, base: u64, len: u64, want: ?FsKind) MountError!u8 {
    const info = block_dev.getDeviceInfo(dev) orelse return error.NoDevice;
    if (info.sector_size != 512) return error.BadFs;
    if (base % SECTOR != 0 or len == 0 or len % SECTOR != 0) return error.Range;
    if (base > info.total_sectors * SECTOR or len > info.total_sectors * SECTOR - base) return error.Range;

    const flags = rofs_lock.acquire();
    defer rofs_lock.release(flags);

    var idx: ?usize = null;
    for (&mounts, 0..) |*m, i| {
        if (m.active) {
            if (m.dev == dev and m.base == base) return error.Busy; // already mounted
        } else if (idx == null) idx = i;
    }
    const slot = idx orelse return error.NoSlot;
    const m = &mounts[slot];
    m.* = .{};
    for (&m.cache) |*c| c.valid = false;
    m.generation = next_generation;
    next_generation +%= 1;
    if (next_generation == 0) next_generation = 1;
    m.dev = dev;
    m.base = base;
    m.len = len;
    m.bounce_phys = pmm.allocPage() orelse return error.NoMemory;
    errdefer freeMountMem(m);

    const kind = want orelse (sniff(m) orelse return error.BadFs);
    switch (kind) {
        .ext4 => {
            m.ext4_vol = ext4.Volume.mount(readerFor(m)) catch return error.BadFs;
            const lab = m.ext4_vol.label;
            var n: usize = 0;
            while (n < lab.len and lab[n] != 0 and n < m.label.len) : (n += 1) m.label[n] = lab[n];
            m.label_len = @intCast(n);
            if (m.ext4_vol.needs_recovery) serial.writeString("[rofs] WARNING: volume needs journal recovery; read-only, journal not replayed\n");
        },
        .ntfs => {
            const pages = (@sizeOf(ntfs.Scratch) + PAGE - 1) / PAGE;
            m.scratch_phys = pmm.allocContiguous(pages) orelse return error.NoMemory;
            m.scratch_pages = pages;
            m.scratch = @ptrFromInt(hhdm.physToVirt(m.scratch_phys));
            m.ntfs_vol = ntfs.Volume.mount(readerFor(m), m.scratch.?) catch return error.BadFs;
        },
        .none => return error.BadFs,
    }
    m.kind = kind;
    m.active = true;
    return @intCast(slot);
}

pub fn umountVolume(slot: u8) MountError!void {
    if (slot >= MAX_MOUNTS) return error.NoDevice;
    const flags = rofs_lock.acquire();
    defer rofs_lock.release(flags);
    const m = &mounts[slot];
    if (!m.active) return error.NoDevice;
    freeMountMem(m);
    m.active = false;
    m.kind = .none;
}

pub fn isActive(slot: u8) bool {
    return slot < MAX_MOUNTS and mounts[slot].active;
}

pub fn generationOf(slot: u8) u32 {
    return if (isActive(slot)) mounts[slot].generation else 0;
}

/// Mount `slot` is active and still the one a descriptor was opened under.
fn live(slot: u8, gen: u32) ?*Mount {
    if (slot >= MAX_MOUNTS) return null;
    const m = &mounts[slot];
    if (!m.active or m.generation != gen) return null;
    return m;
}

pub fn kindOf(slot: u8) FsKind {
    return if (isActive(slot)) mounts[slot].kind else .none;
}

pub fn anyActive() bool {
    for (&mounts) |*m| if (m.active) return true;
    return false;
}

// ─── Object handles ─────────────────────────────────────────────────────

/// A file reference on a mount: ext4 inode number or NTFS record number.
pub const Ref = u64;

pub const Opened = struct {
    ref: Ref,
    gen: u32,
    stat: fr.Stat,
    kind: fr.FileKind,
};

fn mapErr(e: anyerror) i64 {
    return switch (e) {
        error.NotFound => -2, // ENOENT
        error.NotDir => -20, // ENOTDIR
        error.IsDir => -21, // EISDIR
        error.Loop => -40, // ELOOP
        error.NameTooLong => -36, // ENAMETOOLONG
        error.Access => -13, // EACCES
        error.Unsupported => -95, // EOPNOTSUPP
        error.Io => -5,
        else => -5, // EIO: Corrupt, Invalid
    };
}

fn statOf(m: *Mount, ref: Ref) anyerror!Opened {
    switch (m.kind) {
        .ext4 => {
            const in = try m.ext4_vol.readInode(@intCast(ref));
            const kind: fr.FileKind = if (in.isDir()) .directory else if (in.isLnk()) .symlink else if (in.isReg()) .regular else .other;
            return .{ .ref = ref, .gen = m.generation, .stat = m.ext4_vol.stat(&in), .kind = kind };
        },
        .ntfs => {
            const f = try m.ntfs_vol.readFile(ref);
            return .{ .ref = ref, .gen = m.generation, .stat = ntfs.Volume.stat(&f), .kind = ntfs.Volume.fileKind(&f) };
        },
        .none => return error.Invalid,
    }
}

fn metaOf(st: fr.Stat) access.Meta {
    return .{ .mode = st.mode, .uid = st.uid, .gid = st.gid };
}

const SearchCtx = struct { creds: Creds };

fn mayTraverse(ctx: *anyopaque, st: fr.Stat) bool {
    const c: *SearchCtx = @ptrCast(@alignCast(ctx));
    return access.canSearch(metaOf(st), c.creds);
}

/// Resolve `path` (relative to the volume root) for a caller with `creds`.
/// Every directory on the way must be searchable; a regular file must be
/// readable and a directory listable (the access an O_RDONLY open implies).
/// Negative errno on failure.
pub fn open(slot: u8, path: []const u8, follow: bool, creds: Creds) union(enum) { ok: Opened, err: i64 } {
    if (slot >= MAX_MOUNTS) return .{ .err = -19 };
    const flags = rofs_lock.acquire();
    defer rofs_lock.release(flags);
    const m = &mounts[slot];
    if (!m.active) return .{ .err = -19 };
    var sc: SearchCtx = .{ .creds = creds };
    const ref: Ref = switch (m.kind) {
        .ext4 => m.ext4_vol.resolveChecked(path, follow, .{ .ctx = &sc, .allow = mayTraverse }) catch |e| return .{ .err = mapErr(e) },
        .ntfs => m.ntfs_vol.resolveChecked(path, follow, .{ .ctx = &sc, .allow = mayTraverse }) catch |e| return .{ .err = mapErr(e) },
        .none => return .{ .err = -19 },
    };
    const o = statOf(m, ref) catch |e| return .{ .err = mapErr(e) };
    // A symlink's own permissions are never checked (they are always 0777).
    if (o.kind != .symlink and !access.allows(metaOf(o.stat), creds, access.R)) return .{ .err = -13 };
    return .{ .ok = o };
}

pub fn statRef(slot: u8, gen: u32, ref: Ref) union(enum) { ok: Opened, err: i64 } {
    const flags = rofs_lock.acquire();
    defer rofs_lock.release(flags);
    const m = live(slot, gen) orelse return .{ .err = -19 };
    return if (statOf(m, ref)) |o| .{ .ok = o } else |e| .{ .err = mapErr(e) };
}

/// Read file data. Returns bytes read (0 at EOF) or a negative errno.
pub fn readAt(slot: u8, gen: u32, ref: Ref, offset: u64, buf: []u8) i64 {
    const flags = rofs_lock.acquire();
    defer rofs_lock.release(flags);
    const m = live(slot, gen) orelse return -19;
    switch (m.kind) {
        .ext4 => {
            const in = m.ext4_vol.readInode(@intCast(ref)) catch |e| return mapErr(e);
            const n = m.ext4_vol.readFile(&in, offset, buf) catch |e| return mapErr(e);
            return @intCast(n);
        },
        .ntfs => {
            const n = m.ntfs_vol.read(ref, offset, buf) catch |e| return mapErr(e);
            return @intCast(n);
        },
        .none => return -19,
    }
}

/// Next directory entry at or after resume cookie `pos`.
///
/// The cookie is opaque to callers (they store it in the fd offset and hand it
/// back): 0 = start. "." and ".." are synthesised first, then real entries.
/// ext4 encodes a byte position in the directory, NTFS an entry index; both
/// are offset by 2 for the synthetic entries.
///
/// Returns 1 with `out` and `next` filled, 0 at the end, or a negative errno.
pub fn dirNext(slot: u8, gen: u32, ref: Ref, pos: u64, out: *fr.DirEntry, next: *u64) i64 {
    const flags = rofs_lock.acquire();
    defer rofs_lock.release(flags);
    const m = live(slot, gen) orelse return -19;
    if (pos < 2) {
        out.* = .{ .ino = ref, .kind = .directory, .name_len = @intCast(pos + 1) };
        out.name[0] = '.';
        out.name[1] = '.';
        next.* = pos + 1;
        return 1;
    }
    // The synthetic "." / ".." above are the only ones reported: ext4
    // directories store both as real entries and NTFS indexes a "." entry, so
    // those are skipped here to list each exactly once.
    switch (m.kind) {
        .ext4 => {
            const dir = m.ext4_vol.readInode(@intCast(ref)) catch |e| return mapErr(e);
            var raw: u64 = if (pos == 2) 0 else pos - 2;
            var guard: u32 = 0;
            while (guard < 4) : (guard += 1) {
                const nx = m.ext4_vol.readDir(&dir, raw, out) catch |e| return mapErr(e);
                const n = nx orelse return 0;
                if (isDotName(out.nameSlice())) {
                    raw = n;
                    continue;
                }
                next.* = n + 2;
                return 1;
            }
            // More than a handful of consecutive dot entries cannot be a real directory.
            return -5;
        },
        .ntfs => {
            var idx: u64 = pos - 2;
            var guard: u32 = 0;
            while (guard < 4) : (guard += 1) {
                const hit = m.ntfs_vol.readDirAt(ref, idx, out) catch |e| return mapErr(e);
                if (!hit) return 0;
                idx += 1;
                if (isDotName(out.nameSlice())) continue;
                next.* = idx + 2;
                return 1;
            }
            return -5;
        },
        .none => return -19,
    }
}

fn isDotName(n: []const u8) bool {
    return (n.len == 1 and n[0] == '.') or (n.len == 2 and n[0] == '.' and n[1] == '.');
}

pub fn readLink(slot: u8, gen: u32, ref: Ref, buf: []u8) i64 {
    const flags = rofs_lock.acquire();
    defer rofs_lock.release(flags);
    const m = live(slot, gen) orelse return -19;
    switch (m.kind) {
        .ext4 => {
            const in = m.ext4_vol.readInode(@intCast(ref)) catch |e| return mapErr(e);
            const n = m.ext4_vol.readLink(&in, buf) catch |e| return mapErr(e);
            return @intCast(n);
        },
        .ntfs => {
            const n = m.ntfs_vol.readLink(ref, buf) catch |e| return mapErr(e);
            return @intCast(n);
        },
        .none => return -19,
    }
}

pub fn labelOf(slot: u8) []const u8 {
    if (slot >= MAX_MOUNTS) return "";
    return mounts[slot].label[0..mounts[slot].label_len];
}
