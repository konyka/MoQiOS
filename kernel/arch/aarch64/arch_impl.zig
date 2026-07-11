//! AArch64 backend stub for the kernel-wide arch abstraction layer.
//!
//! Milestone 9 skeleton: PL011 serial only. Interrupts / paging / timer /
//! context-switch land in later M9 sub-steps.

const uart = @import("uart.zig");

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
    pub fn init() void {
        @import("trap.zig").init();
    }
    pub fn enableIrq() void {}
    pub fn disableIrq() void {}
};

pub const paging = struct {
    pub fn init() void {
        // Full init needs FDT regions from kmain; start.zig drives paging directly.
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
        asm volatile ("yield");
    }

    pub fn getCpuId() u8 {
        return 0;
    }
};

/// Segment/TSS surface — no-op on aarch64 (SK-1 stub).
pub const gdt = struct {
    pub fn init() void {}
};

/// Monotonic counter — CNTVCT_EL0 (SK-1 stub API).
pub const tsc = struct {
    pub fn init() void {}

    pub fn read() u64 {
        return asm volatile ("mrs %[r], cntvct_el0"
            : [r] "=r" (-> u64),
        );
    }

    pub fn nanos() u64 {
        const frq = asm volatile ("mrs %[r], cntfrq_el0"
            : [r] "=r" (-> u64),
        );
        if (frq == 0) return 0;
        return (read() *% 1_000_000_000) / frq;
    }
};

/// Syscall / per-CPU surface — no-op until shared kernel wires SVC (SK-1).
pub const syscall = struct {
    pub fn init() void {}

    pub fn setPerCpuGsBase(cpu_id: u32) void {
        _ = cpu_id;
    }
};
