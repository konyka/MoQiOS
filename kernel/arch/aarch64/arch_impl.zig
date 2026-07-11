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
    pub const PAGE_SIZE: u64 = 4096;

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

/// Segment/TSS surface — no-op on aarch64 (SK-1/SK-9 stub).
pub const gdt = struct {
    pub fn init() void {}

    pub fn setRsp0(cpu_id: usize, rsp0: u64) void {
        _ = cpu_id;
        _ = rsp0;
    }
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

/// Syscall / per-CPU surface — stub until shared kernel wires SVC (SK-9).
pub const syscall = struct {
    pub const MAX_CPUS: u32 = 1;

    pub const Personality = enum(u8) {
        linux = 0,
    };

    pub fn init() void {}

    pub fn setPerCpuGsBase(cpu_id: u32) void {
        _ = cpu_id;
    }
};

/// Port I/O — not applicable on aarch64 (SK-9 stub).
pub const io = struct {
    pub fn outb(port: u16, val: u8) void {
        _ = port;
        _ = val;
    }
    pub fn outw(port: u16, val: u16) void {
        _ = port;
        _ = val;
    }
    pub fn outl(port: u16, val: u32) void {
        _ = port;
        _ = val;
    }
    pub fn inb(port: u16) u8 {
        _ = port;
        return 0xff;
    }
    pub fn inw(port: u16) u16 {
        _ = port;
        return 0xffff;
    }
    pub fn inl(port: u16) u32 {
        _ = port;
        return 0xffffffff;
    }
    pub fn ioWait() void {}
};

/// Maskable IRQ save/restore (DAIF.I).
pub const irq = struct {
    pub inline fn saveAndDisable() u64 {
        const daif = asm volatile ("mrs %[r], daif"
            : [r] "=r" (-> u64),
        );
        asm volatile ("msr daifset, #2");
        return daif;
    }

    pub inline fn restore(saved: u64) void {
        asm volatile ("msr daif, %[v]"
            :
            : [v] "r" (saved),
        );
    }
};

/// TLB shootdown surface — local only on uniprocessor aarch64 bring-up (SK-8).
pub const tlb = struct {
    pub fn shootdownRange(addr_start: u64, page_count: u32) void {
        _ = addr_start;
        _ = page_count;
        asm volatile ("dsb ish" ::: .{ .memory = true });
        asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
        asm volatile ("dsb ish" ::: .{ .memory = true });
        asm volatile ("isb");
    }
};
