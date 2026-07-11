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

    /// Software interrupt frame for shared `sched` (SK-13).
    /// Field names mirror x86_64 so `setupInitialFrame` is portable; the
    /// arch-local trap path still uses its own TrapFrame until a later SK.
    pub const InterruptFrame = extern struct {
        r15: u64 = 0,
        r14: u64 = 0,
        r13: u64 = 0,
        r12: u64 = 0,
        r11: u64 = 0,
        r10: u64 = 0,
        r9: u64 = 0,
        r8: u64 = 0,
        rbp: u64 = 0,
        rdi: u64 = 0,
        rsi: u64 = 0,
        rdx: u64 = 0,
        rcx: u64 = 0,
        rbx: u64 = 0,
        rax: u64 = 0,
        vector: u64 = 0,
        error_code: u64 = 0,
        rip: u64 = 0,
        cs: u64 = 0,
        rflags: u64 = 0,
        rsp: u64 = 0,
        ss: u64 = 0,
    };

    var tick_count: u64 = 0;

    pub fn getTickCount() u64 {
        return tick_count;
    }
};

pub const paging = struct {
    pub const PAGE_SIZE: u64 = 4096;
    pub const PAGE_2MB: u64 = 2 * 1024 * 1024;

    /// Shared MapFlags shape (SK-11) — forwarded to EL1 paging (SK-12).
    pub const MapFlags = struct {
        writable: bool = false,
        user: bool = false,
        no_execute: bool = true,
        global: bool = false,
        write_through: bool = false,
        cache_disable: bool = false,
    };

    const a64pag = @import("paging.zig");

    pub fn init() void {
        // Full init needs FDT regions from kmain; start.zig drives paging directly.
    }

    pub fn getKernelPml4() u64 {
        return a64pag.rootPhys();
    }

    fn toFlags(flags: MapFlags) u8 {
        var f: u8 = 0;
        if (flags.writable) f |= a64pag.F_WRITE;
        if (!flags.no_execute) f |= a64pag.F_EXEC;
        if (flags.user) f |= a64pag.F_USER;
        return f;
    }

    pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
        _ = pml4_phys;
        if (!a64pag.mapPage(@intCast(virt), @intCast(phys), toFlags(flags)))
            return error.OutOfMemory;
    }

    pub fn unmapPage(pml4_phys: u64, virt: u64) ?u64 {
        _ = pml4_phys;
        a64pag.unmapPage(@intCast(virt));
        return null;
    }

    pub fn isPageMapped(pml4_phys: u64, virt: u64) bool {
        _ = pml4_phys;
        _ = virt;
        // a64 paging has no isMapped helper yet.
        return false;
    }

    pub fn mapHugePage(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
        try mapPage(pml4_phys, virt, phys, flags);
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

    /// SK-13/14: shared sched uses software InterruptFrames; enter via eret.
    pub const uses_software_frame: bool = true;

    var resume_pc: usize = 0;
    var resume_sp: usize = 0;

    /// `eret` into `InterruptFrame.rip`, then `resumeAfterSoftwareEnter` returns here.
    pub fn enterSoftwareFrame(frame_ptr: u64) void {
        const rip_off = @offsetOf(interrupts.InterruptFrame, "rip");
        asm volatile (
            \\adr x0, 1f
            \\str x0, [%[rpc]]
            \\mov x0, sp
            \\str x0, [%[rsp]]
            \\ldr x0, [%[fp], %[roff]]
            \\msr elr_el1, x0
            \\mov x0, #0x5
            \\msr spsr_el1, x0
            \\mov sp, %[fp]
            \\isb
            \\eret
            \\1:
            :
            : [fp] "r" (frame_ptr),
              [roff] "i" (rip_off),
              [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
            : .{ .memory = true, .x0 = true });
    }

    /// Return to the `enterSoftwareFrame` caller (used by SK-14 probe body).
    pub fn resumeAfterSoftwareEnter() noreturn {
        asm volatile (
            \\ldr x0, [%[rsp]]
            \\mov sp, x0
            \\ldr x0, [%[rpc]]
            \\br x0
            :
            : [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
            : .{ .memory = true, .x0 = true });
        unreachable;
    }
};

pub const cpu = struct {
    pub fn halt() noreturn {
        while (true) asm volatile ("wfi");
    }

    /// Wait for the next interrupt (single `wfi`). Used by idle loops (SK-12).
    pub fn waitForInterrupt() void {
        asm volatile ("wfi");
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

/// Syscall / per-CPU surface — stub until shared kernel wires SVC (SK-9/SK-11).
pub const syscall = struct {
    pub const MAX_CPUS: u32 = 1;

    pub const PerCpu = extern struct {
        kernel_rsp: u64 = 0,
        saved_user_rsp: u64 = 0,
        saved_stack_anchor: u64 = 0,
        slice_remaining: u64 = 10,
        cpu_id: u32 = 0,
        apic_id: u32 = 0,
        current_tid: u32 = 0,
        current_task_idx: u32 = 0xFFFFFFFF,
        exec_pending: u64 = 0,
        exec_new_entry: u64 = 0,
        exec_new_stack: u64 = 0,
        force_reschedule: u8 = 0,
    };

    pub var percpu_array: [MAX_CPUS]PerCpu = .{.{}};

    pub const PERCPU_ANCHOR_OFFSET = @offsetOf(PerCpu, "saved_stack_anchor");

    pub const Personality = enum(u8) {
        native = 0,
        linux = 1,
        windows = 2,
    };

    pub fn init() void {}

    pub fn setPerCpuGsBase(cpu_id: u32) void {
        _ = cpu_id;
    }

    pub fn getPerCpu() *PerCpu {
        return &percpu_array[0];
    }

    pub fn getPerCpuOrNull() ?*PerCpu {
        return &percpu_array[0];
    }

    pub inline fn gsReadCurrentTaskIdx() u32 {
        return percpu_array[0].current_task_idx;
    }

    pub inline fn gsWriteCurrentTaskIdx(v: u32) void {
        percpu_array[0].current_task_idx = v;
    }

    pub inline fn gsReadCpuId() u32 {
        return percpu_array[0].cpu_id;
    }

    pub inline fn gsReadSliceRemaining() u64 {
        return percpu_array[0].slice_remaining;
    }

    pub inline fn gsWriteSliceRemaining(v: u64) void {
        percpu_array[0].slice_remaining = v;
    }

    pub fn syncUserRspToTask(t: anytype) void {
        _ = t;
    }

    pub fn syncUserRspFromTask(t: anytype) void {
        _ = t;
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
