//! The table of tracked mappings of one address space (mmap/munmap/mprotect/mlock bookkeeping), kept in Mm.
//!
//! It belongs to the address space, not to a thread: CLONE_VM siblings share one Mm and so one table. Every writer holds
//! the Mm's vm_lock. A fork child (new Mm) starts with a copy, an exec image with an empty table.

/// Tracked mmap region for munmap support.
pub const MmapRegion = struct {
    base: u64 = 0,
    num_pages: u64 = 0,
    /// 0 = free slot
    active: bool = false,
    /// Whether this region is mlock'd (non-swappable).
    locked: bool = false,

    /// I1: count of 2MiB huge blocks in this region; they are always the
    /// FIRST huge_pages*512 pages of the region (a block that falls back to
    /// 4K at mmap ends huge allocation for the rest of the region).
    /// Informational: every huge-page mutation path (munmap/mprotect/
    /// mremap/fork/teardown) is driven by the page tables themselves, and
    /// any partial mutation demotes first — this count only records what
    /// mmap created and is recomputed conservatively on region splits.
    huge_pages: u32 = 0,

    // ─── G2: file-backed (MAP_PRIVATE) metadata ───
    // All zero = anonymous region, so existing initialisers are unaffected.
    /// Backing store kind (filemap.FsKind as u8); 0 = anonymous.
    file_kind: u8 = 0,
    /// PROT_READ/WRITE/EXEC bits captured at mmap; demand faults synthesise
    /// page permissions from this. mprotect updates it (splitting regions).
    prot: u8 = 0,
    /// H1: MAP_SHARED region — faults map the backing frame writable with no
    /// COW marker, fork keeps the frame shared, and ext2/fat32 regions flush
    /// their dirty page-cache pages when the region is released.
    shared: bool = false,
    /// Linux VM_MAYWRITE for MAP_SHARED file regions: false when the fd was
    /// opened read-only, so mprotect cannot later grant PROT_WRITE (EACCES).
    may_write: bool = true,
    /// Byte offset in the file that corresponds to `base`.
    file_offset: u64 = 0,
    /// File size snapshot taken at mmap time — drives the EOF/SIGSEGV rule.
    file_size: u64 = 0,
    /// FS open slot: ext2_file_idx / fat32_file_idx / tmpfs entry index.
    file_idx: u32 = 0,
    /// ramdisk: kernel-virtual data pointer. tmpfs: ctime generation tag.
    file_data: u64 = 0,
    /// Page-cache key (ext2/fat32).
    inode_id: u64 = 0,

    /// L1: the frames backing this region are NOT PMM-owned RAM (user-MMIO
    /// from dev_map_mmio, or DMA frames owned by the user driver framework).
    /// unmapRange must unmap such pages without returning their frames to
    /// the PMM; the owner (userdrv) releases DMA frames itself, and MMIO
    /// frames are never freed at all.
    no_free: bool = false,
};

pub const MAX_REGIONS: usize = 64;

pub const VmaTable = struct {
    /// One page, owned by the Mm that holds this table (allocated when the Mm is created, freed when it dies).
    regions: *[MAX_REGIONS]MmapRegion,
    count: u32 = 0,
    active_bm: u64 = 0,
};

/// A copy of a table taken under the parent's vm_lock, handed to the child's new Mm once it exists (fork, clone
/// without CLONE_VM). It lives on the caller's kernel stack.
pub const Snapshot = struct {
    regions: [MAX_REGIONS]MmapRegion,
    count: u32,
    active_bm: u64,
};

pub fn snapshot(t: *VmaTable, out: *Snapshot) void {
    // The copy is COW-cloned: no huge block survives on either side, so neither table counts any.
    for (t.regions) |*r| r.huge_pages = 0;
    out.regions = t.regions.*;
    out.count = t.count;
    out.active_bm = t.active_bm;
}

pub fn adopt(t: *VmaTable, snap: *const Snapshot) void {
    t.regions.* = snap.regions;
    t.count = snap.count;
    t.active_bm = snap.active_bm;
}
