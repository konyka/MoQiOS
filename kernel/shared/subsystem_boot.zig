//! Shared subsystem bootstrap fragments aligned with `main.zig`.
//!
//! Covers the portable CPU surfaces (gdt/tsc/per-CPU GS) and the M4
//! ipc/capability/syscall trio — safe on non-x86 via arch facade stubs.

const arch = @import("../arch/arch.zig");
const ipc = @import("../ipc/ipc.zig");
const capability = @import("../ipc/capability.zig");

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

/// Full portable subsystem boot used by non-x86 SK-21 probes.
pub fn initAll() void {
    initCpuSurfaces();
    initIpcAndSyscall();
}
