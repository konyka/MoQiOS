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
    /// Unmask IRQs at EL1 (clear DAIF.I). Symmetric with riscv64 sstatus.SIE
    /// so shared SK probes get real mask/unmask semantics on both arches.
    pub fn enableIrq() void {
        asm volatile ("msr daifclr, #2" ::: .{ .memory = true });
    }

    /// Mask IRQs at EL1 (set DAIF.I) so shared probe setup runs atomically.
    pub fn disableIrq() void {
        asm volatile ("msr daifset, #2" ::: .{ .memory = true });
    }

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

    /// SK-40: root table currently loaded in the MMU (TTBR0_EL1).
    pub fn currentRoot() u64 {
        const ttbr0 = asm volatile ("mrs %[v], ttbr0_el1"
            : [v] "=r" (-> u64));
        return ttbr0 & 0x0000_FFFF_FFFF_FFFE;
    }

    /// SK-40: bring-up runs a single stage-1 space; root arg kept for parity.
    pub fn isUserAccessible(root_phys: u64, virt: u64) bool {
        _ = root_phys;
        return a64pag.isUserMapped(@intCast(virt));
    }

    /// Bring-up maps every user page writable and has no copy-on-write, so
    /// there is no read-only user page for a kernel write to trip over yet.
    pub fn isUserWritable(root_phys: u64, virt: u64) bool {
        return isUserAccessible(root_phys, virt);
    }

    /// SK-40: PSTATE.PAN is not enabled at EL1 — EL1 can already touch
    /// EL0-accessible pages, so the brackets are no-ops.
    pub fn userAccessBegin() void {}
    pub fn userAccessEnd() void {}
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

    /// Cooperative switch (SK-20): restore `InterruptFrame.rsp` then `eret` to `rip`.
    pub fn switchToSoftwareFrame(frame_ptr: u64) noreturn {
        const rip_off = @offsetOf(interrupts.InterruptFrame, "rip");
        const rsp_off = @offsetOf(interrupts.InterruptFrame, "rsp");
        asm volatile (
            \\ldr x0, [%[fp], %[roff]]
            \\msr elr_el1, x0
            \\mov x0, #0x5
            \\msr spsr_el1, x0
            \\ldr x0, [%[fp], %[spoff]]
            \\mov sp, x0
            \\isb
            \\eret
            :
            : [fp] "r" (frame_ptr),
              [roff] "i" (rip_off),
              [spoff] "i" (rsp_off),
            : .{ .memory = true, .x0 = true });
        unreachable;
    }

    /// SK-24: PC interrupted by a timer IRQ (TrapFrame.elr).
    pub fn irqInterruptedPc(trap_frame_ptr: u64) u64 {
        const asched = @import("sched.zig");
        const frame: *asched.TrapFrame = @ptrFromInt(trap_frame_ptr);
        return frame.elr;
    }

    /// SK-24: SP before the IRQ frame was pushed (frame_ptr + FRAME_BYTES).
    pub fn irqInterruptedSp(trap_frame_ptr: u64) u64 {
        const asched = @import("sched.zig");
        return trap_frame_ptr + asched.FRAME_BYTES;
    }

    /// SK-26: true when the IRQ interrupted EL0 (spsr M[3:0] == 0).
    pub fn irqFromUserMode(trap_frame_ptr: u64) bool {
        const asched = @import("sched.zig");
        const frame: *asched.TrapFrame = @ptrFromInt(trap_frame_ptr);
        return (frame.spsr & 0xf) == 0;
    }

    const USER_PROBE_TEXT_VA: usize = 0x00030000;
    const USER_PROBE_STACK_VA: usize = 0x00040000;
    const USER_PROBE_STACK_TOP: usize = USER_PROBE_STACK_VA + 4096;
    const USER_PROBE_STACK1_VA: usize = 0x00050000;
    const USER_PROBE_STACK1_TOP: usize = USER_PROBE_STACK1_VA + 4096;

    fn writeU32(page: [*]u8, off: usize, word: u32) void {
        page[off] = @truncate(word);
        page[off + 1] = @truncate(word >> 8);
        page[off + 2] = @truncate(word >> 16);
        page[off + 3] = @truncate(word >> 24);
    }

    /// SK-26: map a tiny EL0 `wfi` loop (VA distinct from M9-6).
    pub fn prepareUserIrqProbe() bool {
        const pmm = @import("pmm.zig");
        const a64pag = @import("paging.zig");
        const text_pa = pmm.allocPage();
        if (text_pa == 0) return false;
        const stack_pa = pmm.allocPage();
        if (stack_pa == 0) {
            pmm.freePage(text_pa);
            return false;
        }
        const page: [*]u8 = @ptrFromInt(text_pa);
        @memset(page[0..4096], 0);
        writeU32(page, 0, 0xD503207F); // wfi
        writeU32(page, 4, 0x17FFFFFF); // b -4
        if (!a64pag.mapPage(USER_PROBE_TEXT_VA, text_pa, a64pag.F_EXEC | a64pag.F_USER)) {
            pmm.freePage(text_pa);
            pmm.freePage(stack_pa);
            return false;
        }
        if (!a64pag.mapPage(USER_PROBE_STACK_VA, stack_pa, a64pag.F_WRITE | a64pag.F_USER)) {
            a64pag.unmapPage(USER_PROBE_TEXT_VA);
            pmm.freePage(text_pa);
            pmm.freePage(stack_pa);
            return false;
        }
        return true;
    }

    /// SK-26: `eret` into EL0 with IRQs unmasked (spsr=0). Saves resume slot.
    pub fn enterUserIrqProbe() void {
        const gic = @import("gic.zig");
        gic.enableCpuIrq();
        asm volatile (
            \\adr x0, 1f
            \\str x0, [%[rpc]]
            \\mov x0, sp
            \\str x0, [%[rsp]]
            \\msr sp_el0, %[usp]
            \\msr elr_el1, %[entry]
            \\mov x0, #0
            \\msr spsr_el1, x0
            \\isb
            \\eret
            \\1:
            :
            : [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
              [usp] "r" (@as(u64, USER_PROBE_STACK_TOP)),
              [entry] "r" (@as(u64, USER_PROBE_TEXT_VA)),
            : .{ .memory = true, .x0 = true });
    }

    /// SK-26: leave EL0 probe and return to `enterUserIrqProbe` caller.
    pub fn finishUserIrqProbe() noreturn {
        // Drop scheduler current so SK-31 fallthrough cannot preempt later EL0.
        @import("../../proc/sched.zig").setCurrentTaskIndex(null);
        @import("gic.zig").disableCpuIrq();
        resumeAfterSoftwareEnter();
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

    /// SK-15: build a native TrapFrame on a shared task stack for eret enter/switch.
    pub fn buildKernelTrapFrame(stack_top: u64, entry: u64) u64 {
        const asched = @import("sched.zig");
        const frame_addr = (stack_top - asched.FRAME_BYTES) & ~@as(u64, 15);
        const frame: *asched.TrapFrame = @ptrFromInt(frame_addr);
        const bytes: [*]u8 = @ptrCast(frame);
        @memset(bytes[0..asched.FRAME_BYTES], 0);
        frame.elr = entry;
        frame.spsr = 0x5; // EL1h, IRQs unmasked after eret
        return frame_addr;
    }

    /// SK-27: native TrapFrame that `eret`s into EL0 (spsr=0, sp_el0=user_sp).
    pub fn buildUserTrapFrame(kstack_top: u64, entry: u64, user_sp: u64) u64 {
        const asched = @import("sched.zig");
        const frame_addr = (kstack_top - asched.FRAME_BYTES) & ~@as(u64, 15);
        const frame: *asched.TrapFrame = @ptrFromInt(frame_addr);
        const bytes: [*]u8 = @ptrCast(frame);
        @memset(bytes[0..asched.FRAME_BYTES], 0);
        frame.elr = entry;
        frame.spsr = 0; // EL0t, DAIF clear
        frame.sp_el0 = user_sp;
        return frame_addr;
    }

    pub fn userProbeTextVa() u64 {
        return USER_PROBE_TEXT_VA;
    }

    pub fn userProbeStackTop() u64 {
        return USER_PROBE_STACK_TOP;
    }

    pub fn userProbeStackTop1() u64 {
        return USER_PROBE_STACK1_TOP;
    }

    pub fn nativeTrapFrameBytes() u64 {
        const asched = @import("sched.zig");
        return asched.FRAME_BYTES;
    }

    /// Relocate a live TrapFrame onto the task kernel stack when needed.
    /// aarch64 EL0 IRQs usually already land on per-task SP_EL1 — fast path
    /// returns `frame_ptr` unchanged.
    pub fn relocateNativeTrapFrame(frame_ptr: u64, kstack_base: u64, kstack_top: u64) u64 {
        const asched = @import("sched.zig");
        const nbytes: u64 = asched.FRAME_BYTES;
        if (frame_ptr >= kstack_base and frame_ptr + nbytes <= kstack_top) {
            return frame_ptr;
        }
        const dest = (kstack_top -% 2 * nbytes) & ~@as(u64, 15);
        if (dest < kstack_base or dest + nbytes > kstack_top) return frame_ptr;
        if (dest != frame_ptr) {
            const dst: [*]u8 = @ptrFromInt(dest);
            const src: [*]const u8 = @ptrFromInt(frame_ptr);
            @memcpy(dst[0..nbytes], src[0..nbytes]);
        }
        return dest;
    }

    /// SK-28: text + two user stacks (shared busy-loop image, distinct SPs).
    pub fn prepareDualUserIrqProbe() bool {
        if (!prepareUserIrqProbe()) return false;
        const pmm = @import("pmm.zig");
        const a64pag = @import("paging.zig");
        const stack1_pa = pmm.allocPage();
        if (stack1_pa == 0) return false;
        if (!a64pag.mapPage(USER_PROBE_STACK1_VA, stack1_pa, a64pag.F_WRITE | a64pag.F_USER)) {
            pmm.freePage(stack1_pa);
            return false;
        }
        return true;
    }

    /// SK-15: init GICv3 + CNTV so shared preempt can take timer IRQs.
    /// Leaves CPU IRQs masked until TrapFrame spsr enables them on eret.
    pub fn armSharedPreemptTimer() void {
        const gic = @import("gic.zig");
        _ = gic.init();
        @import("timer.zig").init(0);
        // Distributor/CPU iface ready; DAIF.I still set until eret from enterTrapFrame.
        gic.enableCpuIrq();
    }

    /// SK-36: stop CNTV and mask CPU IRQs after shared user-IRQ probes.
    pub fn disarmSharedPreemptTimer() void {
        @import("timer.zig").disarm();
        @import("gic.zig").disableCpuIrq();
    }

    /// SK-15/SK-28: `eret` into a TrapFrame (kernel or EL0). Restores SP_EL0
    /// from offset 168 so direct enter into a user frame is valid.
    pub fn enterTrapFrame(frame_ptr: u64) void {
        asm volatile (
            \\adr x0, 1f
            \\str x0, [%[rpc]]
            \\mov x0, sp
            \\str x0, [%[rsp]]
            \\mov sp, %[f]
            \\ldp x1, x2, [sp, #176]
            \\msr elr_el1, x1
            \\msr spsr_el1, x2
            \\ldr x1, [sp, #168]
            \\msr sp_el0, x1
            \\ldr x30, [sp, #160]
            \\ldp x18, x29, [sp, #144]
            \\ldp x16, x17, [sp, #128]
            \\ldp x14, x15, [sp, #112]
            \\ldp x12, x13, [sp, #96]
            \\ldp x10, x11, [sp, #80]
            \\ldp x8, x9, [sp, #64]
            \\ldp x6, x7, [sp, #48]
            \\ldp x4, x5, [sp, #32]
            \\ldp x2, x3, [sp, #16]
            \\ldp x0, x1, [sp, #0]
            \\add sp, sp, #192
            \\isb
            \\eret
            \\1:
            :
            : [f] "r" (frame_ptr),
              [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
            : .{ .memory = true });
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

    pub fn readStackPointer() u64 {
        return asm volatile ("mov %[r], sp"
            : [r] "=r" (-> u64));
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

    /// TLS base install. aarch64 uses TPIDR_EL0, and this port has no user
    /// threading yet, so there is nothing to program here.
    pub fn setUserTlsBase(base: u64) void {
        _ = base;
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
