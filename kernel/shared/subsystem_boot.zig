//! Shared subsystem bootstrap fragments aligned with `main.zig`.
//!
//! Covers the portable CPU surfaces (gdt/tsc/per-CPU GS), symbol table
//! (SK-35), the M4 ipc/capability/syscall trio, the portable M2 mm pair,
//! slab / page_cache / tmpfs / random — safe on non-x86 via arch facade
//! stubs / HHDM=0.

const arch = @import("../arch/arch.zig");
const ipc = @import("../ipc/ipc.zig");
const capability = @import("../ipc/capability.zig");
const addr_space = @import("../mm/addr_space.zig");
const dma = @import("../mm/dma.zig");
const slab = @import("../mm/slab.zig");
const page_cache = @import("../fs/page_cache.zig");
const tmpfs = @import("../fs/tmpfs.zig");
const random = @import("../drivers/random.zig");
const symbol_table = @import("../debug/symbol_table.zig");

/// Early CPU surfaces from main.zig (gdt + tsc + BSP GS_BASE). Idempotent stubs
/// on non-x86; real gdt/tsc on x86_64.
pub fn initCpuSurfaces() void {
    arch.gdt.init();
    arch.tsc.init();
    arch.syscall.setPerCpuGsBase(0);
}

/// M1 symbol table from main.zig (panic backtrace; SK-35).
pub fn initSymbolTable() void {
    symbol_table.init();
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

/// SK-43: ramdisk parse from main.zig. The archive source is arch-specific
/// (Limine module on x86; probe-built blob on non-x86 for now) but the MRD
/// parser and file index are fully shared.
pub fn initRamdisk(base: [*]const u8, size: u64) bool {
    return @import("../fs/ramdisk.zig").init(base, size);
}

/// Full portable subsystem boot used by non-x86 SK-21 probes.
pub fn initAll() void {
    initCpuSurfaces();
    initSymbolTable();
    initIpcAndSyscall();
    initPortableMm();
    initSlab();
    initPageCache();
    initTmpfs();
    initRandom();
}
