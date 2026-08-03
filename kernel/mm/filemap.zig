// kernel/mm/filemap.zig — pure decision logic for file-backed (MAP_PRIVATE) mmap.
//
// Deliberately free of imports so the host test runner can exercise it
// (same pattern as cow_pte.zig). The page-fault path (arch/x86_64/idt.zig)
// and the mmap/munmap bookkeeping (mm/mmap.zig) call into here for region
// lookup, file-offset computation, EOF clamping and permission/PTE synthesis.
//
// Design (G2): file-backed mappings are demand-paged. mmap() records the
// backing metadata in the task's region table without touching the page
// tables; the first access faults, the fault handler asks planFault() what
// to do, and either maps the backing frame read-only (zero-copy, COW marker
// when the mapping is writable-private) or serves a private copy. Pages
// wholly at/past EOF raise SIGSEGV (Linux SIGBUS semantics); the last
// partial page is served with a zeroed tail.

pub const PAGE_SIZE: u64 = 4096;

/// Backing-store flavour of a file region. Stored as u8 in task.MmapRegion;
/// 0 means anonymous so zero-initialised regions stay anonymous.
pub const FsKind = enum(u8) {
    none = 0,
    ramdisk = 1,
    tmpfs = 2,
    ext2 = 3,
    fat32 = 4,
};

pub const PROT_READ: u8 = 1;
pub const PROT_WRITE: u8 = 2;
pub const PROT_EXEC: u8 = 4;

pub const PTE_PRESENT: u64 = 1;
pub const PTE_WRITABLE: u64 = 1 << 1;
pub const PTE_USER: u64 = 1 << 2;
/// COW marker (same bit cow_pte.zig uses) — hardware ignores it, the fault
/// handler recognises a shared page by it.
pub const PTE_COW: u64 = 1 << 9;
pub const PTE_NX: u64 = 1 << 63;
pub const PTE_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

pub const FaultAction = enum {
    /// Whole page at/past EOF — the fault handler lets this become SIGSEGV.
    segv,
    /// Serve the page from the backing store (zero-fill past valid_bytes).
    file_page,
};

pub const FaultPlan = struct {
    action: FaultAction,
    /// Byte offset within the file of the faulting page.
    file_off: u64 = 0,
    /// Bytes the file supplies for this page; the rest is zero-filled.
    valid_bytes: u32 = 0,
    /// Map the shared backing frame read-only with the COW marker
    /// (writable MAP_PRIVATE) instead of granting write access.
    cow: bool = false,
    executable: bool = false,
};

/// mmap's offset argument must be page-aligned (Linux EINVAL otherwise).
pub fn offsetValid(offset: u64) bool {
    return offset % PAGE_SIZE == 0;
}

/// First active file-backed region containing `addr`, or null.
///
/// Generic over the region record so the kernel passes task.MmapRegion
/// slices directly while host tests use a plain struct. Required fields:
/// `active: bool`, `file_kind: u8`, `base: u64`, `num_pages: u64`.
pub fn findFileRegion(comptime R: type, regions: []const R, addr: u64) ?usize {
    for (regions, 0..) |r, i| {
        if (!r.active or r.file_kind == 0) continue;
        if (addr >= r.base and addr - r.base < r.num_pages * PAGE_SIZE) return i;
    }
    return null;
}

/// What a not-present fault inside a file-backed region should do.
/// Required region fields: `base`, `file_offset`, `file_size`, `prot`.
/// The caller must have established containment (findFileRegion).
pub fn planFault(comptime R: type, r: *const R, fault_page: u64) FaultPlan {
    const page_index = (fault_page - r.base) / PAGE_SIZE;
    const file_off = r.file_offset + page_index * PAGE_SIZE;
    // Linux semantics: a page wholly at/past EOF faults (SIGBUS there; this
    // kernel delivers SIGSEGV). The last partial page is served, tail zeroed.
    if (file_off >= r.file_size) return .{ .action = .segv };
    const remaining = r.file_size - file_off;
    return .{
        .action = .file_page,
        .file_off = file_off,
        .valid_bytes = @intCast(@min(remaining, PAGE_SIZE)),
        .cow = (r.prot & PROT_WRITE) != 0,
        .executable = (r.prot & PROT_EXEC) != 0,
    };
}

/// munmap head-trim: the region base moved up by `delta_pages`, so the file
/// offset tracked at the base advances with it.
pub fn advanceFileOffset(file_offset: u64, delta_pages: u64) u64 {
    return file_offset + delta_pages * PAGE_SIZE;
}

/// Region merging (trackMmapRegion) is only valid between two anonymous
/// regions — file regions carry per-region backing metadata that a merge
/// would silently drop.
pub fn canMergeAnon(existing_kind: u8, new_kind: u8) bool {
    return existing_kind == 0 and new_kind == 0;
}

/// PTE for a shared backing frame (page-cache/tmpfs): present+user,
/// read-only, COW marker when the mapping is writable-private so the first
/// write faults into the existing COW copier (handleCowFault).
///
/// The caller must pmm.addRef() the frame before installing this entry; the
/// owner's freePage() then only drops the owner's reference and the frame
/// outlives eviction for as long as the mapping holds it.
pub fn filePte(phys: u64, cow: bool, executable: bool) u64 {
    var pte = (phys & PTE_ADDR_MASK) | PTE_PRESENT | PTE_USER;
    if (cow) pte |= PTE_COW;
    if (!executable) pte |= PTE_NX;
    return pte;
}

/// PTE for a private copy page (ramdisk frames, tmpfs sparse holes,
/// page-cache-full fallback): an ordinary demand-paged page honouring prot,
/// never carrying the COW marker — the frame is exclusively ours.
pub fn privatePte(phys: u64, prot: u8) u64 {
    var pte = (phys & PTE_ADDR_MASK) | PTE_PRESENT | PTE_USER;
    if ((prot & PROT_WRITE) != 0) pte |= PTE_WRITABLE;
    if ((prot & PROT_EXEC) == 0) pte |= PTE_NX;
    return pte;
}
