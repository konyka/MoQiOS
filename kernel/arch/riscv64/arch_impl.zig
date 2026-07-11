//! RISC-V 64 backend for the kernel-wide arch abstraction layer.
//!
//! Milestone 2 wires a real UART16550 console and a minimal `stvec` trap
//! path. Paging / timer / context-switch remain stubs until later milestones
//! (see docs/cross-arch-port-plan.md).

const uart = @import("uart.zig");
const trap = @import("trap.zig");

pub const serial = struct {
    pub fn init() void {
        uart.init();
    }

    pub fn writeByte(byte: u8) void {
        uart.writeByte(byte);
    }

    pub fn writeString(s: []const u8) void {
        uart.writeString(s);
    }
};

pub const interrupts = struct {
    /// Install the supervisor trap vector (direct mode).
    pub fn init() void {
        trap.init();
    }

    /// Enable supervisor interrupts (sstatus.SIE).
    pub fn enableIrq() void {
        asm volatile ("csrsi sstatus, 2");
    }

    /// Disable supervisor interrupts (sstatus.SIE).
    pub fn disableIrq() void {
        asm volatile ("csrci sstatus, 2");
    }
};

pub const paging = struct {
    /// Sv39 identity map + satp enable (Milestone 3).
    pub fn init() void {
        // Full init needs FDT regions from kmain; start.zig drives sv39 directly.
    }
};

pub const timer = struct {
    pub fn init(interval: u64) void {
        @import("timer.zig").init(interval);
    }
};

pub const context_switch = struct {
    pub fn initCpu() void {}

    pub fn onContextSwitch(old: anytype) void {
        _ = old;
    }
};

pub const cpu = struct {
    pub fn halt() noreturn {
        while (true) asm volatile ("wfi");
    }

    pub fn pause() void {
        asm volatile ("nop");
    }

    pub fn getCpuId() u8 {
        return 0;
    }
};

/// Segment/TSS surface — no-op on riscv64 (SK-1 stub).
pub const gdt = struct {
    pub fn init() void {}
};

/// Monotonic counter — `rdtime` when available (SK-1 stub API).
pub const tsc = struct {
    pub fn init() void {}

    pub fn read() u64 {
        return asm volatile ("rdtime %[r]"
            : [r] "=r" (-> u64),
        );
    }

    pub fn nanos() u64 {
        // QEMU virt typically ~10 MHz timebase; approximate only.
        return read() * 100;
    }
};

/// Syscall / per-CPU GS surface — no-op until shared kernel wires ecall (SK-1).
pub const syscall = struct {
    pub fn init() void {}

    pub fn setPerCpuGsBase(cpu_id: u32) void {
        _ = cpu_id;
    }
};

/// Maskable IRQ save/restore (sstatus.SIE).
pub const irq = struct {
    pub inline fn saveAndDisable() u64 {
        return asm volatile ("csrrc %[old], sstatus, %[mask]"
            : [old] "=r" (-> u64),
            : [mask] "r" (@as(u64, 1 << 1)),
        );
    }

    pub inline fn restore(saved: u64) void {
        if ((saved & (1 << 1)) != 0) {
            asm volatile ("csrsi sstatus, 2");
        }
    }
};
