//! Shared subsystem bootstrap fragments aligned with `main.zig`.
//!
//! Covers the portable CPU surfaces (gdt/tsc/per-CPU GS), the M4
//! ipc/capability/syscall trio, the portable M2 mm pair (addr_space + dma),
//! slab (SK-32), page_cache (SK-33), and tmpfs/random (SK-34) — safe on
//! non-x86 via arch facade stubs / HHDM=0.

const arch = @import("../arch/arch.zig");
const ipc = @import("../ipc/ipc.zig");
const capability = @import("../ipc/capability.zig");
const addr_space = @import("../mm/addr_space.zig");
const dma = @import("../mm/dma.zig");
const slab = @import("../mm/slab.zig");
const page_cache = @import("../fs/page_cache.zig");
const tmpfs = @import("../fs/tmpfs.zig");
const random = @import("../drivers/random.zig");

/// Early CPU surfaces from main.zig (gdt + tsc + BSP GS_BASE). Idempotent stubs
/// on non-x86; real gdt/tsc on x86_64.
pub fn initCpuSurfaces() void {
    arch.gdt.init();
    arch.tsc.init();
    arch.syscall.setPerCpuGsBase(0);
}

/// M4 block from main.zig: IPC + capabilities + syscall entry.
pub fn initIpcAndSyscall() void {
    ipc.init();
    capability.init();
    arch.syscall.init();
}

/// Portable M2 mm pair from main.zig: address-space tracker + DMA manager.
/// Requires shared PMM/HHDM already live (SK-6 on non-x86; Limine path on x86).
pub fn initPortableMm() void {
    addr_space.init();
    dma.init();
}

/// M2 slab allocator from main.zig (idempotent; SK-6 may already have called it).
pub fn initSlab() void {
    slab.init();
}

/// Unified page cache from main.zig (before block/FS bring-up; SK-33).
pub fn initPageCache() void {
    page_cache.init();
}

/// In-memory tmpfs from main.zig (SK-34).
pub fn initTmpfs() void {
    tmpfs.init();
}

/// /dev/urandom PRNG from main.zig; seeds via arch.tsc (SK-34).
pub fn initRandom() void {
    random.init();
}

/// Full portable subsystem boot used by non-x86 SK-21 probes.
pub fn initAll() void {
    initCpuSurfaces();
    initIpcAndSyscall();
    initPortableMm();
    initSlab();
    initPageCache();
    initTmpfs();
    initRandom();
}
