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
    /// TODO(M3): allocate root Sv39 PT, populate kernel half, write `satp`.
    pub fn init() void {}
};

pub const timer = struct {
    /// TODO(M5): arm initial deadline via SBI Timer or `stimecmp`.
    pub fn init(_: u64) void {}
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
