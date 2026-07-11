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
    pub const PAGE_SIZE: u64 = 4096;

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

/// Segment/TSS surface — no-op on riscv64 (SK-1/SK-9 stub).
pub const gdt = struct {
    pub fn init() void {}

    pub fn setRsp0(cpu_id: usize, rsp0: u64) void {
        _ = cpu_id;
        _ = rsp0;
    }
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

/// Syscall / per-CPU surface — stub until shared kernel wires ecall (SK-9).
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

/// Port I/O — not applicable on riscv64 (SK-9 stub).
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

/// TLB shootdown surface — no-op on uniprocessor riscv64 bring-up (SK-8).
pub const tlb = struct {
    pub fn shootdownRange(addr_start: u64, page_count: u32) void {
        _ = addr_start;
        _ = page_count;
        asm volatile ("sfence.vma" ::: .{ .memory = true });
    }
};
