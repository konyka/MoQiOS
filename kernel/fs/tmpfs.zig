/// tmpfs — pure in-memory filesystem.
/// Files are stored in kernel-allocated physical pages.
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const capability = @import("../proc/capability_profile.zig");
const creation_metadata = @import("../proc/creation_metadata.zig");
const dac = @import("dac.zig");

const MAX_FILES = 64;
const MAX_NAME_LEN = 60;
const PAGES_PER_FILE = 64;
const PAGE_SIZE = 4096;
/// 一级间接页：一页 4KB 存放 512 个 u64 物理地址（0 = 空洞），
/// 单文件上限从 64 页（256 KiB）提升到 64+512 页（2.25 MiB）。
const INDIRECT_PAGES = 512;
const MAX_FILE_SIZE = (PAGES_PER_FILE + INDIRECT_PAGES) * PAGE_SIZE;

const TmpfsEntry = struct {
    active: bool,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    is_dir: bool,
    parent_idx: u8, // 255 = root
    size: u32,
    pages: [PAGES_PER_FILE]?u64, // physical page addresses
    page_count: u16, // 数据页数（不含间接页）；最大 576
    /// 一级间接页物理地址（0 = 未分配）；覆盖页号 [64, 576)。
    indirect: u64 = 0,
    mode: u32,
    uid: u32,
    gid: u32,
    ctime: u64,
    // v53.51: open refcount + deferred free. unlink used to free the slot
    // while other fds still held its index; allocEntry then reused it and the
    // stale fds read/wrote the NEW file. Unlink now tombstones (deleted=true)
    // and the slot is only freed once the last open fd closes.
    open_count: u16,
    deleted: bool,
};

pub const Metadata = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    is_dir: bool,
};

var entries: [MAX_FILES]TmpfsEntry = undefined;
var active_bm: u64 = 0; // Bitmap: bit i = entries[i].active
var tmpfs_lock: IrqSpinlock = .{};
var next_ctime: u64 = 1;
var initialized: bool = false;

inline fn bmSet(idx: u6) void {
    active_bm |= @as(u64, 1) << idx;
}
inline fn bmClr(idx: u6) void {
    active_bm &= ~(@as(u64, 1) << idx);
}

fn allocEntry() ?u8 {
    const inv = ~active_bm & ~@as(u64, 1); // skip bit 0 (root), mask free slots
    if (inv == 0) return null;
    const i: u8 = @intCast(@ctz(inv));
    if (i >= MAX_FILES) return null;
    bmSet(@intCast(i));
    return i;
}

fn freeEntryPages(idx: u8) void {
    const entry = &entries[idx];
    for (0..PAGES_PER_FILE) |p| {
        if (entry.pages[p]) |phys| {
            pmm.freePage(phys);
            entry.pages[p] = null;
        }
    }
    if (entry.indirect != 0) {
        const table: [*]u64 = @ptrFromInt(hhdm.physToVirt(entry.indirect));
        for (0..INDIRECT_PAGES) |s| {
            if (table[s] != 0) pmm.freePage(table[s]);
        }
        pmm.freePage(entry.indirect);
        entry.indirect = 0;
    }
    entry.page_count = 0;
    entry.size = 0;
    bmClr(@intCast(idx));
}

/// 读取文件页 page_idx 的物理地址（0 = 空洞）。页号 >= 64 走一级间接页。
fn pageAt(entry: *const TmpfsEntry, page_idx: u32) u64 {
    if (page_idx < PAGES_PER_FILE) return entry.pages[page_idx] orelse 0;
    const slot = page_idx - PAGES_PER_FILE;
    if (slot >= INDIRECT_PAGES or entry.indirect == 0) return 0;
    const table: [*]const u64 = @ptrFromInt(hhdm.physToVirt(entry.indirect));
    return table[slot];
}

/// 读取或按需分配文件页（0 = OOM）。间接页本身同样按需分配。
fn pageAtAlloc(entry: *TmpfsEntry, page_idx: u32) u64 {
    if (page_idx < PAGES_PER_FILE) {
        if (entry.pages[page_idx]) |phys| return phys;
        const phys = pmm.allocPage() orelse return 0;
        const page_ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
        @memset(page_ptr[0..PAGE_SIZE], 0);
        entry.pages[page_idx] = phys;
        entry.page_count += 1;
        return phys;
    }
    const slot = page_idx - PAGES_PER_FILE;
    if (slot >= INDIRECT_PAGES) return 0;
    if (entry.indirect == 0) {
        const ind = pmm.allocPage() orelse return 0;
        const ind_ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(ind));
        @memset(ind_ptr[0..PAGE_SIZE], 0);
        entry.indirect = ind;
    }
    const table: [*]u64 = @ptrFromInt(hhdm.physToVirt(entry.indirect));
    if (table[slot] != 0) return table[slot];
    const phys = pmm.allocPage() orelse return 0;
    const page_ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    @memset(page_ptr[0..PAGE_SIZE], 0);
    table[slot] = phys;
    entry.page_count += 1;
    return phys;
}

fn findEntry(name: []const u8, parent: u8) ?u8 {
    var bm = active_bm;
    while (bm != 0) {
        const bit = @ctz(bm);
        bm &= bm - 1;
        const i: u8 = @intCast(bit);
        if (entries[i].deleted) continue; // v53.51: unlinked, pending last close
        if (entries[i].parent_idx != parent) continue;
        if (entries[i].name_len != name.len) continue;
        if (nameEql(entries[i].name[0..entries[i].name_len], name)) {
            return i;
        }
    }
    return null;
}

/// Strip "/tmp" prefix and return the inner path.
fn stripPrefix(path: []const u8) []const u8 {
    if (path.len >= 4 and path[0] == '/' and path[1] == 't' and path[2] == 'm' and path[3] == 'p') {
        if (path.len == 4) return "/";
        return path[4..];
    }
    return path;
}

/// Split path into components (naive: split by '/').
/// Returns the final component name and its parent directory index.
fn resolvePath(path: []const u8, out_name: *[MAX_NAME_LEN]u8, out_name_len: *u8) ?u8 {
    const inner = stripPrefix(path);
    if (inner.len == 0 or (inner.len == 1 and inner[0] == '/')) {
        // root directory
        out_name_len.* = 1;
        out_name[0] = '/';
        return 0;
    }

    var parent: u8 = 0;
    var start: usize = 0;
    if (inner[0] == '/') start = 1;

    var i = start;
    while (i <= inner.len) : (i += 1) {
        if (i == inner.len or inner[i] == '/') {
            const comp = inner[start..i];
            if (comp.len == 0) {
                start = i + 1;
                continue;
            }
            if (i == inner.len) {
                // last component
                const len = @min(comp.len, MAX_NAME_LEN);
                @memcpy(out_name[0..len], comp[0..len]);
                out_name_len.* = @intCast(len);
                return parent;
            }
            // intermediate directory component
            if (findEntry(comp, parent)) |dir_idx| {
                if (!entries[dir_idx].is_dir) return null;
                parent = dir_idx;
            } else {
                return null;
            }
            start = i + 1;
        }
    }
    return null;
}

pub fn init() void {
    // Idempotent: subsystem_boot / main / SK-34 may all call this.
    if (initialized) return;
    for (0..MAX_FILES) |i| {
        entries[i] = .{
            .active = false,
            .name = @splat(0),
            .name_len = 0,
            .is_dir = false,
            .parent_idx = 255,
            .size = 0,
            .pages = [_]?u64{null} ** PAGES_PER_FILE,
            .page_count = 0,
            .mode = 0,
            .uid = 0,
            .gid = 0,
            .ctime = 0,
            .open_count = 0,
            .deleted = false,
        };
    }
    // Root directory (index 0)
    entries[0] = .{
        .active = true,
        .name = @splat(0),
        .name_len = 1,
        .is_dir = true,
        .parent_idx = 255,
        .size = 0,
        .pages = [_]?u64{null} ** PAGES_PER_FILE,
        .page_count = 0,
        .mode = 0o755,
        .uid = 0,
        .gid = 0,
        .ctime = 0,
        .open_count = 0,
        .deleted = false,
    };
    entries[0].name[0] = '/';
    active_bm = 1; // bit 0 = root
    initialized = true;
}

/// Open a file under /tmp/. Creates if it does not exist.
/// Returns entry index on success, -1 on error.
pub fn tmpfsOpen(path: []const u8, create: bool, is_dir: bool) i64 {
    return tmpfsOpenAuthorized(path, create, is_dir, 0, 0, .{}, 0, null, creation_metadata.DEFAULT_UMASK);
}

fn createEntryLocked(name: []const u8, name_len: u8, parent: u8, is_dir: bool, requested_mode: ?u32, umask_val: u32, euid: u32, egid: u32) ?u8 {
    const idx = allocEntry() orelse return null;
    const metadata = creation_metadata.decide(null, if (is_dir) .directory else .regular_file, requested_mode, umask_val, euid, egid).metadata;
    entries[idx] = .{
        .active = true,
        .name = @splat(0),
        .name_len = name_len,
        .is_dir = is_dir,
        .parent_idx = parent,
        .size = 0,
        .pages = [_]?u64{null} ** PAGES_PER_FILE,
        .page_count = 0,
        .mode = metadata.mode,
        .uid = metadata.uid,
        .gid = metadata.gid,
        .ctime = next_ctime,
        .open_count = 1,
        .deleted = false,
    };
    next_ctime +%= 1;
    @memcpy(entries[idx].name[0..name_len], name[0..name_len]);
    return idx;
}

/// Open a tmpfs entry for VFS. DAC applies only to an existing regular file;
/// creation and directory-open behavior remain identical to tmpfsOpen.
pub fn tmpfsOpenAuthorized(path: []const u8, create: bool, is_dir: bool, euid: u32, egid: u32, effective_caps: capability.SysCap, flags: u32, requested_mode: ?u32, umask_val: u32) i64 {
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);

    var name_buf: [MAX_NAME_LEN]u8 = undefined;
    var name_len: u8 = 0;
    const parent = resolvePath(path, &name_buf, &name_len) orelse return -1;

    if (name_len == 1 and name_buf[0] == '/') {
        if (creation_metadata.exclusiveCreateRejectsExisting(create, flags)) return -17;
        entries[0].open_count +|= 1;
        return 0;
    }

    const name = name_buf[0..name_len];
    if (findEntry(name, parent)) |idx| {
        if (creation_metadata.exclusiveCreateRejectsExisting(create, flags)) return -17;
        const entry = &entries[idx];
        if (!entry.is_dir) {
            const decision = dac.decideExistingOpen(
                .{ .mode = entry.mode, .uid = entry.uid, .gid = entry.gid },
                .{ .euid = euid, .egid = egid, .cap_dac_override = effective_caps.cap_dac_override },
                flags,
            );
            if (!decision.allowed) return -13;
            if (decision.truncate) truncateLocked(entry, 0);
        }
        entry.open_count +|= 1;
        return @intCast(idx);
    }

    if (create) {
        const idx = createEntryLocked(name, name_len, parent, is_dir, requested_mode, umask_val, euid, egid) orelse return -1;
        return @intCast(idx);
    }

    return -1;
}

/// Read from a tmpfs file.
pub fn tmpfsRead(idx: u8, offset: u64, buf: [*]u8, count: u32) i64 {
    if (idx >= MAX_FILES) return -1;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);

    const entry = &entries[idx];
    if (!entry.active or entry.is_dir) return -1;
    if (offset >= entry.size) return 0;

    const to_read = @min(count, entry.size - @as(u32, @intCast(offset)));
    var remaining = to_read;
    var pos: u32 = @intCast(offset);
    var dst: u32 = 0;

    while (remaining > 0) {
        const page_idx = pos / PAGE_SIZE;
        const page_off = pos % PAGE_SIZE;
        const chunk = @min(remaining, PAGE_SIZE - page_off);
        if (page_idx >= PAGES_PER_FILE + INDIRECT_PAGES) break;
        const phys = pageAt(entry, page_idx);
        if (phys != 0) {
            const src: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys) + page_off);
            @memcpy(buf[dst .. dst + chunk], src[0..chunk]);
        } else {
            // Unallocated page = zeros
            @memset(buf[dst .. dst + chunk], 0);
        }
        dst += chunk;
        pos += chunk;
        remaining -= chunk;
    }

    return @intCast(dst);
}

/// Write to a tmpfs file.
pub fn tmpfsWrite(idx: u8, offset: u64, data: [*]const u8, count: u32) i64 {
    if (idx >= MAX_FILES) return -1;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);

    const entry = &entries[idx];
    if (!entry.active or entry.is_dir) return -1;
    if (offset >= MAX_FILE_SIZE) return -1;

    const start: u32 = @intCast(offset);
    const to_write = @min(count, MAX_FILE_SIZE - start);
    var remaining = to_write;
    var pos = start;
    var src: u32 = 0;

    while (remaining > 0) {
        const page_idx = pos / PAGE_SIZE;
        const page_off = pos % PAGE_SIZE;
        const chunk = @min(remaining, PAGE_SIZE - page_off);

        const phys = pageAtAlloc(entry, page_idx);
        if (phys == 0) break; // OOM 或超出单文件上限

        const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys) + page_off);
        @memcpy(dst[0..chunk], data[src .. src + chunk]);

        src += chunk;
        pos += chunk;
        remaining -= chunk;
    }

    if (pos > entry.size) {
        entry.size = pos;
    }

    return @intCast(src);
}

/// Truncate a tmpfs file to `new_size`, freeing pages beyond the new size.
/// Growing only updates the size — pages are allocated lazily on write and
/// unallocated pages read back as zeros.
pub fn tmpfsTruncate(idx: u8, new_size: u32) bool {
    if (idx >= MAX_FILES) return false;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);

    const entry = &entries[idx];
    if (!entry.active or entry.is_dir or new_size > MAX_FILE_SIZE) return false;
    truncateLocked(entry, new_size);
    return true;
}

fn truncateLocked(entry: *TmpfsEntry, new_size: u32) void {
    const keep_pages: u32 = if (new_size == 0) 0 else (new_size + PAGE_SIZE - 1) / PAGE_SIZE;
    var p: u32 = keep_pages;
    while (p < PAGES_PER_FILE) : (p += 1) {
        if (entry.pages[p]) |phys| {
            pmm.freePage(phys);
            entry.pages[p] = null;
            entry.page_count -= 1;
        }
    }
    // 间接区：释放 keep 之后的数据页；keep 全部落在直辖区时间接页本身也释放。
    if (entry.indirect != 0) {
        const table: [*]u64 = @ptrFromInt(hhdm.physToVirt(entry.indirect));
        const start: u32 = if (keep_pages > PAGES_PER_FILE) keep_pages - PAGES_PER_FILE else 0;
        var s: u32 = start;
        while (s < INDIRECT_PAGES) : (s += 1) {
            if (table[s] != 0) {
                pmm.freePage(table[s]);
                table[s] = 0;
                entry.page_count -= 1;
            }
        }
        if (keep_pages <= PAGES_PER_FILE) {
            pmm.freePage(entry.indirect);
            entry.indirect = 0;
        }
    }
    // Zero the tail of the last kept page so stale bytes past the new EOF
    // don't resurface if the file later regrows into the same page.
    if (keep_pages > 0 and new_size % PAGE_SIZE != 0) {
        const phys = pageAt(entry, keep_pages - 1);
        if (phys != 0) {
            const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
            @memset(ptr[new_size % PAGE_SIZE .. PAGE_SIZE], 0);
        }
    }
    entry.size = new_size;
}

/// Close a tmpfs file: drop one open reference. The file persists until
/// unlink; an unlinked (deleted) file is freed once its last fd closes.
pub fn tmpfsClose(idx: u8) void {
    if (idx >= MAX_FILES) return;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    const entry = &entries[idx];
    if (!entry.active or entry.open_count == 0) return;
    entry.open_count -= 1;
    if (entry.open_count == 0 and entry.deleted) {
        freeEntryPages(idx);
        entry.active = false;
        entry.deleted = false;
    }
}

/// Retain one open reference (fork/clone fd-table copy — see
/// vfs.retainSharedResources).
pub fn tmpfsRetain(idx: u8) void {
    if (idx >= MAX_FILES) return;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    if (entries[idx].active) entries[idx].open_count +|= 1;
}

/// Unlink (delete) a file or empty directory.
pub fn tmpfsUnlink(path: []const u8) i64 {
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);

    var name_buf: [MAX_NAME_LEN]u8 = undefined;
    var name_len: u8 = 0;
    const parent = resolvePath(path, &name_buf, &name_len) orelse return -1;

    if (name_len == 1 and name_buf[0] == '/') return -1; // cannot unlink root

    const name = name_buf[0..name_len];
    const idx = findEntry(name, parent) orelse return -1;
    const entry = &entries[idx];

    if (entry.is_dir) {
        // directory must be empty — bitmap scan
        var bm = active_bm;
        while (bm != 0) {
            const bit = @ctz(bm);
            bm &= bm - 1;
            const ci: u8 = @intCast(bit);
            if (entries[ci].deleted) continue;
            if (entries[ci].parent_idx == idx) {
                return -1; // ENOTEMPTY
            }
        }
    }

    // v53.51: Tombstone first. While any fd still holds this index the pages
    // must stay: freeing now would let allocEntry reuse the slot and stale
    // fds would read/write the NEW file. tmpfsClose frees at the last close.
    entry.deleted = true;
    if (entry.open_count == 0) {
        freeEntryPages(@intCast(idx));
        entry.active = false;
        entry.deleted = false;
    }
    return 0;
}

/// Create a directory.
pub fn tmpfsMkdir(path: []const u8) i64 {
    return tmpfsMkdirAuthorized(path, 0o777, creation_metadata.DEFAULT_UMASK, 0, 0, .{});
}

pub fn tmpfsMkdirAuthorized(path: []const u8, requested_mode: u32, umask_val: u32, euid: u32, egid: u32, effective_caps: capability.SysCap) i64 {
    const result = tmpfsOpenAuthorized(path, true, true, euid, egid, effective_caps, 0, requested_mode, umask_val);
    if (result < 0) return result;
    // tmpfsOpen already created as dir; just return success
    return 0;
}

/// Get file size.
pub fn tmpfsGetSize(idx: u8) u32 {
    if (idx >= MAX_FILES) return 0;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    if (!entries[idx].active) return 0;
    return entries[idx].size;
}

pub fn tmpfsGetMetadata(idx: u8) ?Metadata {
    if (idx >= MAX_FILES) return null;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    const entry = &entries[idx];
    if (!entry.active) return null;
    return .{
        .mode = entry.mode,
        .uid = entry.uid,
        .gid = entry.gid,
        .is_dir = entry.is_dir,
    };
}

/// G2: ctime doubles as a generation tag for file-backed mmap regions —
/// captured at mmap time, revalidated on every fault by tmpfsGetMapPage so a
/// recycled slot can never serve a stale mapping the wrong file's pages.
pub fn tmpfsGetCtime(idx: u8) u64 {
    if (idx >= MAX_FILES) return 0;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    if (!entries[idx].active) return 0;
    return entries[idx].ctime;
}

/// G2: physical frame backing file page `page_idx`, for zero-copy MAP_PRIVATE
/// mappings. Returns null for sparse holes and for stale mappings (entry gone
/// or ctime tag mismatch). The caller must pmm.addRef() the frame before
/// mapping it; freeEntryPages' freePage then only drops tmpfs's own
/// reference and the frame outlives the entry while the mapping holds it.
pub fn tmpfsGetMapPage(idx: u8, ctime: u64, page_idx: u32) ?u64 {
    if (idx >= MAX_FILES) return null;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    const entry = &entries[idx];
    if (!entry.active or entry.is_dir) return null;
    if (entry.ctime != ctime) return null;
    if (page_idx >= PAGES_PER_FILE + INDIRECT_PAGES) return null;
    const phys = pageAt(entry, page_idx);
    return if (phys != 0) phys else null;
}

/// H1: tmpfsGetMapPage variant for writable MAP_SHARED faults — allocates a
/// zeroed backing page for a sparse hole so the write lands on tmpfs-owned
/// memory every sharer can see (a private zero page would silently unshare).
/// Same generation-tag validation and lifetime contract as tmpfsGetMapPage.
/// Does not grow entry.size: the fault path only ensures pages inside the
/// mmap-time size snapshot.
pub fn tmpfsEnsureMapPage(idx: u8, ctime: u64, page_idx: u32) ?u64 {
    if (idx >= MAX_FILES) return null;
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    const entry = &entries[idx];
    if (!entry.active or entry.is_dir) return null;
    if (entry.ctime != ctime) return null;
    if (page_idx >= PAGES_PER_FILE + INDIRECT_PAGES) return null;
    const phys = pageAtAlloc(entry, page_idx);
    return if (phys != 0) phys else null;
}

pub const TmpfsDirEntry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const TmpfsDirListing = struct {
    entries: []const TmpfsDirEntry,
    count: u32,
};

pub fn tmpfsCanListDir(idx: u8, euid: u32, egid: u32, effective_caps: capability.SysCap) bool {
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    if (idx >= MAX_FILES) return false;
    const entry = &entries[idx];
    if (!entry.active or entry.deleted or !entry.is_dir) return false;
    return dac.canListDirectory(
        .{ .mode = entry.mode, .uid = entry.uid, .gid = entry.gid },
        .{ .euid = euid, .egid = egid, .cap_dac_override = effective_caps.cap_dac_override },
    );
}

/// List directory entries for a given tmpfs directory index.
///
/// v53.51: entries and names are copied into CALLER-OWNED buffers while
/// tmpfs_lock is held. The previous version returned slices into a global
/// dir_listing_buf and into live entries[i].name after releasing the lock, so
/// a concurrent getdents/unlink corrupted a listing still in use.
/// `out_entries` receives the entry records; `names_buf`/`names_cap` receives
/// the name bytes each entry's name slice points into.
pub fn tmpfsListDir(idx: u8, out_entries: []TmpfsDirEntry, names_buf: [*]u8, names_cap: u32) TmpfsDirListing {
    const empty: TmpfsDirListing = .{ .entries = &[_]TmpfsDirEntry{}, .count = 0 };
    const state_held = tmpfs_lock.acquire();
    defer tmpfs_lock.release(state_held);
    if (idx >= MAX_FILES or !entries[idx].active or entries[idx].deleted or !entries[idx].is_dir) {
        return empty;
    }
    var count: u32 = 0;
    var names_used: u32 = 0;
    var bm = active_bm;
    while (bm != 0) {
        const bit = @ctz(bm);
        bm &= bm - 1;
        const i: u8 = @intCast(bit);
        if (entries[i].deleted) continue;
        if (entries[i].parent_idx != idx) continue;
        if (count >= out_entries.len) break;
        const nlen: u32 = entries[i].name_len;
        if (names_used + nlen > names_cap) break;
        @memcpy(names_buf[names_used .. names_used + nlen], entries[i].name[0..nlen]);
        out_entries[count] = .{
            .name = names_buf[names_used .. names_used + nlen],
            .is_dir = entries[i].is_dir,
        };
        names_used += nlen;
        count += 1;
    }
    return .{ .entries = out_entries[0..count], .count = count };
}

/// Compare two name slices for equality.
fn nameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}
