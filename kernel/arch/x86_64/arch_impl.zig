//! x86_64 backend for the kernel-wide arch abstraction layer.
//!
//! Each public namespace mirrors the contract declared in `../arch.zig` and
//! is built by re-exporting an existing x86_64 module. Keeping the adapters
//! here (rather than editing the underlying modules) lets us share code with
//! riscv64 without disturbing the well-tested x86_64 boot path.

pub const serial = @import("serial.zig");
pub const interrupts = @import("idt.zig");
pub const paging = @import("paging.zig");
pub const timer = @import("lapic.zig");
pub const context_switch = @import("context_switch.zig");
pub const gdt = @import("gdt.zig");
pub const tsc = @import("tsc.zig");
pub const syscall = @import("syscall_entry.zig");
pub const tlb = @import("tlb.zig");
pub const io = @import("io.zig");

pub const cpu = struct {
    /// Park the current CPU forever. Used by panic / boot-failure paths.
    pub fn halt() noreturn {
        while (true) {
            asm volatile ("cli");
            asm volatile ("hlt");
        }
    }

    /// Wait for the next interrupt (single `hlt`). Used by idle loops.
    pub fn waitForInterrupt() void {
        asm volatile ("hlt");
    }

    /// Spin-wait hint for busy loops (PAUSE on x86_64).
    pub fn pause() void {
        asm volatile ("pause");
    }

    /// Return the BSP/AP-relative CPU id (0-based) when the per-CPU area has
    /// been initialised; otherwise fall back to 0 so very-early callers stay
    /// correct on a uniprocessor boot.
    pub fn getCpuId() u8 {
        const se = @import("syscall_entry.zig");
        const pc = se.getPerCpuOrNull() orelse return 0;
        return @intCast(pc.cpu_id);
    }
};

/// Maskable IRQ save/restore for IrqSpinlock and similar critical sections.
pub const irq = struct {
    pub inline fn saveAndDisable() u64 {
        var rflags: u64 = undefined;
        asm volatile (
            \\pushfq
            \\pop %[flags]
            \\cli
            : [flags] "=r" (rflags),
        );
        return rflags;
    }

    pub inline fn restore(saved_rflags: u64) void {
        asm volatile (
            \\push %[flags]
            \\popfq
            :
            : [flags] "r" (saved_rflags),
        );
    }
};
