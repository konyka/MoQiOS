//! Architecture abstraction layer — common interface for all ISA backends.
//!
//! Kernel-shared code SHOULD route architecture-specific operations through
//! this module rather than reaching into `kernel/arch/<isa>/` directly. The
//! concrete backend is selected at comptime from `builtin.cpu.arch`.
//!
//! Backends (`arch_impl.zig` per ISA) MUST expose the same public namespaces
//! re-exported below: `serial`, `interrupts`, `paging`, `timer`,
//! `context_switch`, `cpu`. Cross-arch port plan (M4) tracks the gradual
//! migration of `kernel/main.zig` and other shared sites onto this surface.

const builtin = @import("builtin");

pub const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/arch_impl.zig"),
    .riscv64 => @import("riscv64/arch_impl.zig"),
    else => @compileError("unsupported architecture"),
};

// Re-export the common interface expected by the rest of the kernel.
pub const serial = impl.serial;
pub const interrupts = impl.interrupts;
pub const paging = impl.paging;
pub const timer = impl.timer;
pub const context_switch = impl.context_switch;
pub const cpu = impl.cpu;
