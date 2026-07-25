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

    /// Shared MapFlags shape (SK-11) — forwarded to Sv39 (SK-12).
    pub const MapFlags = struct {
        writable: bool = false,
        user: bool = false,
        no_execute: bool = true,
        global: bool = false,
        write_through: bool = false,
        cache_disable: bool = false,
    };

    const sv39 = @import("sv39.zig");

    /// Sv39 identity map + satp enable (Milestone 3).
    pub fn init() void {
        // Full init needs FDT regions from kmain; start.zig drives sv39 directly.
    }

    pub fn getKernelPml4() u64 {
        return sv39.rootPhys();
    }

    pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
        _ = pml4_phys;
        const ok = sv39.mapPage(@intCast(virt), @intCast(phys), .{
            .read = true,
            .write = flags.writable,
            .exec = !flags.no_execute,
            .user = flags.user,
        });
        if (!ok) return error.OutOfMemory;
    }

    pub fn unmapPage(pml4_phys: u64, virt: u64) ?u64 {
        _ = pml4_phys;
        if (!sv39.isMapped(@intCast(virt))) return null;
        // Sv39 unmap does not return the old phys; callers that free must track it.
        sv39.unmapPage(@intCast(virt));
        return null;
    }

    pub fn isPageMapped(pml4_phys: u64, virt: u64) bool {
        _ = pml4_phys;
        return sv39.isMapped(@intCast(virt));
    }

    pub fn mapHugePage(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
        // No Sv39 huge helper yet — fall back to a single 4K map of the base.
        try mapPage(pml4_phys, virt, phys, flags);
    }

    /// SK-40: root table currently loaded in the MMU (satp PPN → phys).
    pub fn currentRoot() u64 {
        const satp = asm volatile ("csrr %[v], satp"
            : [v] "=r" (-> u64));
        return (satp & 0xFFF_FFFF_FFFF) << 12;
    }

    /// SK-40: bring-up runs a single Sv39 address space; the root argument is
    /// accepted for facade parity with x86 but the shared table is walked.
    pub fn isUserAccessible(root_phys: u64, virt: u64) bool {
        _ = root_phys;
        return sv39.isUserMapped(@intCast(virt));
    }

    /// SK-40: S-mode loads/stores to U pages trap unless sstatus.SUM is set.
    pub fn userAccessBegin() void {
        asm volatile ("csrs sstatus, %[b]"
            :
            : [b] "r" (@as(u64, 1) << 18),
            : .{ .memory = true });
    }

    pub fn userAccessEnd() void {
        asm volatile ("csrc sstatus, %[b]"
            :
            : [b] "r" (@as(u64, 1) << 18),
            : .{ .memory = true });
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

    /// SK-13/14: shared sched uses software InterruptFrames; enter via sret.
    pub const uses_software_frame: bool = true;

    var resume_pc: usize = 0;
    var resume_sp: usize = 0;

    /// `sret` into `InterruptFrame.rip`, then `resumeAfterSoftwareEnter` returns here.
    pub fn enterSoftwareFrame(frame_ptr: u64) void {
        const rip_off = @offsetOf(interrupts.InterruptFrame, "rip");
        asm volatile (
            \\lla t0, 1f
            \\sd t0, 0(%[rpc])
            \\sd sp, 0(%[rsp])
            \\ld t0, %[roff](%[fp])
            \\csrw sepc, t0
            \\li t0, %[sstat]
            \\csrw sstatus, t0
            \\mv sp, %[fp]
            \\sret
            \\1:
            :
            : [fp] "r" (frame_ptr),
              [roff] "i" (rip_off),
              [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
              [sstat] "i" (@as(usize, (1 << 8) | (1 << 5))),
            : .{ .memory = true, .x5 = true });
    }

    /// Cooperative switch (SK-20): restore `InterruptFrame.rsp` then `sret` to `rip`.
    /// Does not clobber the SK-14 resume slot used by `resumeAfterSoftwareEnter`.
    pub fn switchToSoftwareFrame(frame_ptr: u64) noreturn {
        const rip_off = @offsetOf(interrupts.InterruptFrame, "rip");
        const rsp_off = @offsetOf(interrupts.InterruptFrame, "rsp");
        asm volatile (
            \\ld t0, %[roff](%[fp])
            \\csrw sepc, t0
            \\li t0, %[sstat]
            \\csrw sstatus, t0
            \\ld sp, %[spoff](%[fp])
            \\sret
            :
            : [fp] "r" (frame_ptr),
              [roff] "i" (rip_off),
              [spoff] "i" (rsp_off),
              [sstat] "i" (@as(usize, (1 << 8) | (1 << 5))),
            : .{ .memory = true, .x5 = true });
        unreachable;
    }

    /// SK-24: PC interrupted by a supervisor timer IRQ (TrapFrame.sepc).
    pub fn irqInterruptedPc(trap_frame_ptr: u64) u64 {
        const frame: *trap.TrapFrame = @ptrFromInt(trap_frame_ptr);
        return frame.sepc;
    }

    /// SK-24: SP at the moment of the IRQ (TrapFrame.sp).
    pub fn irqInterruptedSp(trap_frame_ptr: u64) u64 {
        const frame: *trap.TrapFrame = @ptrFromInt(trap_frame_ptr);
        return frame.sp;
    }

    /// SK-26: true when the trap/IRQ interrupted U-mode (sstatus.SPP == 0).
    pub fn irqFromUserMode(trap_frame_ptr: u64) bool {
        const frame: *trap.TrapFrame = @ptrFromInt(trap_frame_ptr);
        return (frame.sstatus & (1 << 8)) == 0;
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

    /// SK-26: map a tiny U-mode `wfi` loop at a VA distinct from M6's pages.
    pub fn prepareUserIrqProbe() bool {
        const pmm = @import("pmm.zig");
        const sv39 = @import("sv39.zig");
        const text_pa = pmm.allocPage() orelse return false;
        const stack_pa = pmm.allocPage() orelse {
            pmm.freePage(text_pa);
            return false;
        };
        const page: [*]u8 = @ptrFromInt(text_pa);
        @memset(page[0..4096], 0);
        // U-mode cannot execute WFI (illegal insn on virt); busy-loop instead.
        writeU32(page, 0, 0x00000013); // addi x0, x0, 0 (nop)
        writeU32(page, 4, 0xffdff06f); // jal x0, -4
        if (!sv39.mapPage(USER_PROBE_TEXT_VA, text_pa, .{
            .read = true,
            .write = false,
            .exec = true,
            .user = true,
        })) {
            pmm.freePage(text_pa);
            pmm.freePage(stack_pa);
            return false;
        }
        if (!sv39.mapPage(USER_PROBE_STACK_VA, stack_pa, .{
            .read = true,
            .write = true,
            .exec = false,
            .user = true,
        })) {
            sv39.unmapPage(USER_PROBE_TEXT_VA);
            pmm.freePage(text_pa);
            pmm.freePage(stack_pa);
            return false;
        }
        asm volatile ("sfence.vma" ::: .{ .memory = true });
        return true;
    }

    /// SK-26: `sret` into U-mode with SPIE (IRQs enable after sret). Saves the
    /// same resume slot as `enterSoftwareFrame` for `finishUserIrqProbe`.
    pub fn enterUserIrqProbe() void {
        const ksp = trap.userTrapStackTop();
        if (ksp == 0) {
            while (true) asm volatile ("wfi");
        }
        asm volatile (
            \\lla t0, 1f
            \\sd t0, 0(%[rpc])
            \\sd sp, 0(%[rsp])
            \\li t0, %[entry]
            \\csrw sepc, t0
            \\li t0, %[sstat]
            \\csrw sstatus, t0
            \\csrw sscratch, %[ks]
            \\li sp, %[usp]
            \\sret
            \\1:
            :
            : [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
              [entry] "i" (USER_PROBE_TEXT_VA),
              [sstat] "i" (@as(usize, 1 << 5)), // SPIE; SPP=0
              [ks] "r" (ksp),
              [usp] "i" (USER_PROBE_STACK_TOP),
            : .{ .memory = true, .x5 = true });
    }

    /// SK-26: leave U-mode probe and return to `enterUserIrqProbe` caller.
    pub fn finishUserIrqProbe() noreturn {
        // Drop scheduler current so SK-31 fallthrough cannot preempt M6.
        @import("../../proc/sched.zig").setCurrentTaskIndex(null);
        asm volatile ("csrw sscratch, zero");
        asm volatile ("csrci sstatus, 2"); // clear SIE
        resumeAfterSoftwareEnter();
    }

    /// Return to the `enterSoftwareFrame` caller (used by SK-14 probe body).
    pub fn resumeAfterSoftwareEnter() noreturn {
        asm volatile (
            \\ld sp, 0(%[rsp])
            \\ld t0, 0(%[rpc])
            \\jr t0
            :
            : [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
            : .{ .memory = true });
        unreachable;
    }

    /// SK-15: build a native TrapFrame on a shared task stack for sret enter/switch.
    pub fn buildKernelTrapFrame(stack_top: u64, entry: u64) u64 {
        const frame_addr = (stack_top - trap.FRAME_BYTES) & ~@as(u64, 15);
        const frame: *trap.TrapFrame = @ptrFromInt(frame_addr);
        const bytes: [*]u8 = @ptrCast(frame);
        @memset(bytes[0..trap.FRAME_BYTES], 0);
        frame.sepc = entry;
        frame.sstatus = (1 << 8) | (1 << 5); // SPP=1, SPIE=1
        // Keep gp/tp for medany/TLS; sp unused by first sret but needed after trap return.
        frame.gp = asm volatile ("mv %[r], gp"
            : [r] "=r" (-> u64));
        frame.tp = asm volatile ("mv %[r], tp"
            : [r] "=r" (-> u64));
        frame.sp = frame_addr;
        return frame_addr;
    }

    /// SK-27: native TrapFrame that `sret`s into U-mode (SPP=0, SPIE=1).
    pub fn buildUserTrapFrame(kstack_top: u64, entry: u64, user_sp: u64) u64 {
        const frame_addr = (kstack_top - trap.FRAME_BYTES) & ~@as(u64, 15);
        const frame: *trap.TrapFrame = @ptrFromInt(frame_addr);
        const bytes: [*]u8 = @ptrCast(frame);
        @memset(bytes[0..trap.FRAME_BYTES], 0);
        frame.sepc = entry;
        frame.sstatus = 1 << 5; // SPIE; SPP=0
        frame.gp = asm volatile ("mv %[r], gp"
            : [r] "=r" (-> u64));
        frame.tp = asm volatile ("mv %[r], tp"
            : [r] "=r" (-> u64));
        frame.sp = user_sp;
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
        return trap.FRAME_BYTES;
    }

    /// Relocate a live TrapFrame onto `kstack_top` if it sits outside that
    /// stack (riscv U-mode IRQs share `u_trap_stack`). No-op copy when already
    /// local. Destination: `kstack_top - 2*FRAME` (below the synthetic enter frame).
    pub fn relocateNativeTrapFrame(frame_ptr: u64, kstack_base: u64, kstack_top: u64) u64 {
        const nbytes: u64 = trap.FRAME_BYTES;
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
        const sv39 = @import("sv39.zig");
        const stack1_pa = pmm.allocPage() orelse return false;
        if (!sv39.mapPage(USER_PROBE_STACK1_VA, stack1_pa, .{
            .read = true,
            .write = true,
            .exec = false,
            .user = true,
        })) {
            pmm.freePage(stack1_pa);
            return false;
        }
        asm volatile ("sfence.vma" ::: .{ .memory = true });
        return true;
    }

    /// SK-15: arm stimecmp so shared preempt can take timer IRQs.
    /// Does not set sstatus.SIE — the TrapFrame SPIE bit enables IE after sret.
    pub fn armSharedPreemptTimer() void {
        @import("timer.zig").init(10_000); // ~1 ms at 10 MHz
    }

    /// SK-36: clear STIE + far stimecmp after shared user-IRQ probes.
    pub fn disarmSharedPreemptTimer() void {
        @import("timer.zig").disarm();
    }

    /// SK-15/SK-28: `sret` into a TrapFrame (S-mode or U-mode).
    /// For U-mode frames (SPP=0): arm sscratch and load user SP from the frame.
    /// `sscratch` must be programmed *before* GPR restore — the frame load
    /// clobbers the register holding `ksp`.
    pub fn enterTrapFrame(frame_ptr: u64) void {
        const ksp = trap.userTrapStackTop();
        asm volatile (
            \\lla t0, 1f
            \\sd t0, 0(%[rpc])
            \\sd sp, 0(%[rsp])
            \\mv sp, %[f]
            \\ld t0, 248(sp)
            \\csrw sepc, t0
            \\ld t0, 272(sp)
            \\csrw sstatus, t0
            // Program sscratch while %[ks] is still live (before GPR restore).
            \\andi t1, t0, 0x100
            \\bnez t1, 3f
            \\csrw sscratch, %[ks]
            \\j 4f
            \\3:
            \\csrw sscratch, zero
            \\4:
            \\ld ra,   0(sp)
            \\ld gp,  16(sp)
            \\ld tp,  24(sp)
            \\ld t0,  32(sp)
            \\ld t1,  40(sp)
            \\ld t2,  48(sp)
            \\ld s0,  56(sp)
            \\ld s1,  64(sp)
            \\ld a0,  72(sp)
            \\ld a1,  80(sp)
            \\ld a2,  88(sp)
            \\ld a3,  96(sp)
            \\ld a4, 104(sp)
            \\ld a5, 112(sp)
            \\ld a6, 120(sp)
            \\ld a7, 128(sp)
            \\ld s2, 136(sp)
            \\ld s3, 144(sp)
            \\ld s4, 152(sp)
            \\ld s5, 160(sp)
            \\ld s6, 168(sp)
            \\ld s7, 176(sp)
            \\ld s8, 184(sp)
            \\ld s9, 192(sp)
            \\ld s10,200(sp)
            \\ld s11,208(sp)
            \\ld t3, 216(sp)
            \\ld t4, 224(sp)
            \\ld t5, 232(sp)
            \\ld t6, 240(sp)
            // SPP? U → frame.sp; S → pop TrapFrame.
            \\csrr t0, sstatus
            \\andi t1, t0, 0x100
            \\bnez t1, 2f
            \\ld t0, 8(sp)
            \\mv sp, t0
            \\sret
            \\2:
            \\addi sp, sp, 288
            \\sret
            \\1:
            :
            : [f] "r" (frame_ptr),
              [rpc] "r" (@intFromPtr(&resume_pc)),
              [rsp] "r" (@intFromPtr(&resume_sp)),
              [ks] "r" (ksp),
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
        return asm volatile ("mv %[r], sp"
            : [r] "=r" (-> u64));
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

/// Syscall / per-CPU surface — stub until shared kernel wires ecall (SK-9/SK-11).
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

    /// TLS base install. riscv64 keeps the thread pointer in `tp`, which the
    /// trap return path restores from the frame, and this port has no user
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
