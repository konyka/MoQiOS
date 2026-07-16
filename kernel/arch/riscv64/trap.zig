//! S-mode trap entry + frame for the riscv64 skeleton.
//!
//! Supports S-mode traps (M2–M5) and U-mode traps/syscalls (M6) via `sscratch`
//! stack switching: when running user code, `sscratch` holds the kernel trap
//! stack top; when in S-mode it is zero.

/// Saved register state at trap time. Layout must match `trapEntry` asm.
pub const TrapFrame = extern struct {
    ra: u64,
    sp: u64,
    gp: u64,
    tp: u64,
    t0: u64,
    t1: u64,
    t2: u64,
    s0: u64,
    s1: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
    a7: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
    t3: u64,
    t4: u64,
    t5: u64,
    t6: u64,
    sepc: u64,
    scause: u64,
    stval: u64,
    sstatus: u64,
};

pub const Cause = struct {
    pub const illegal_instruction: u64 = 2;
    pub const breakpoint: u64 = 3;
    pub const ecall_from_u: u64 = 8;
    pub const ecall_from_s: u64 = 9;
    pub const load_page_fault: u64 = 13;
    pub const store_page_fault: u64 = 15;
    pub const supervisor_timer: u64 = 5;
};

pub const FRAME_BYTES: usize = 288;

var trap_count: u64 = 0;
var last_scause: u64 = 0;
var last_sepc: u64 = 0;
var last_stval: u64 = 0;

var expect_breakpoint: bool = false;
var breakpoint_caught: bool = false;
var expect_page_fault: bool = false;
var page_fault_caught: bool = false;

/// Dedicated kernel stack for traps taken from U-mode.
var u_trap_stack: [8192]u8 align(16) = undefined;
/// Exported for trapEntry asm (medany `lla`).
export var u_trap_stack_top: usize = 0;

const uart = @import("uart.zig");

fn putHex(v: u64) void {
    const hex = "0123456789abcdef";
    uart.writeString("0x");
    var i: u6 = 60;
    while (true) {
        uart.writeByte(hex[@intCast((v >> i) & 0xf)]);
        if (i == 0) break;
        i -= 4;
    }
}

pub fn init() void {
    u_trap_stack_top = @intFromPtr(&u_trap_stack) + u_trap_stack.len;
    const entry: usize = @intFromPtr(&trapEntry);
    asm volatile ("csrw stvec, %[e]"
        :
        : [e] "r" (entry),
        : .{ .memory = true });
    asm volatile ("csrw sscratch, zero");
}

pub fn userTrapStackTop() usize {
    return u_trap_stack_top;
}

pub fn armBreakpointTest() void {
    expect_breakpoint = true;
    breakpoint_caught = false;
}

pub fn breakpointWasCaught() bool {
    return breakpoint_caught;
}

pub fn armPageFaultTest() void {
    expect_page_fault = true;
    page_fault_caught = false;
}

pub fn pageFaultWasCaught() bool {
    return page_fault_caught;
}

pub fn getTrapCount() u64 {
    return trap_count;
}

fn startM5() noreturn {
    const sched = @import("sched.zig");
    uart.writeString("MoQiOS riscv64: M5 (timer + sched)\n");
    sched.init();
    sched.start();
}

export fn trapHandler(frame: *TrapFrame) callconv(.c) *TrapFrame {
    trap_count += 1;
    last_scause = frame.scause;
    last_sepc = frame.sepc;
    last_stval = frame.stval;

    const interrupt = (frame.scause >> 63) != 0;
    const code = frame.scause & 0xff;

    if (interrupt and code == Cause.supervisor_timer) {
        const timer = @import("timer.zig");
        timer.onInterrupt();
        const sk15 = @import("../../shared/sk15.zig");
        if (sk15.isEnabled()) {
            return @ptrFromInt(sk15.onTimer(@intFromPtr(frame)));
        }
        const sk16 = @import("../../shared/sk16.zig");
        if (sk16.isEnabled()) {
            return @ptrFromInt(sk16.onTimer(@intFromPtr(frame)));
        }
        const sk23 = @import("../../shared/sk23.zig");
        if (sk23.isEnabled()) {
            sk23.onTimerIrq();
            return frame;
        }
        const sk24 = @import("../../shared/sk24.zig");
        if (sk24.isEnabled()) {
            return @ptrFromInt(sk24.onTimerIrq(@intFromPtr(frame)));
        }
        const sk26 = @import("../../shared/sk26.zig");
        if (sk26.isEnabled()) {
            return @ptrFromInt(sk26.onTimerIrq(@intFromPtr(frame)));
        }
        const sk27 = @import("../../shared/sk27.zig");
        if (sk27.isEnabled()) {
            return @ptrFromInt(sk27.onTimer(@intFromPtr(frame)));
        }
        const sk28 = @import("../../shared/sk28.zig");
        if (sk28.isEnabled()) {
            return @ptrFromInt(sk28.onTimer(@intFromPtr(frame)));
        }
        const sched = @import("sched.zig");
        return sched.onTimer(frame);
    }

    if (!interrupt and code == Cause.ecall_from_u) {
        const user = @import("user.zig");
        if (user.handleEcall(frame)) {
            return frame;
        }
        // sys_exit — continue into M5 (noreturn).
        startM5();
    }

    if (!interrupt and code == Cause.breakpoint and expect_breakpoint) {
        breakpoint_caught = true;
        expect_breakpoint = false;
        uart.writeString("[trap] breakpoint caught sepc=");
        putHex(frame.sepc);
        uart.writeString(" scause=");
        putHex(frame.scause);
        uart.writeByte('\n');
        frame.sepc += 4;
        return frame;
    }

    if (!interrupt and (code == Cause.load_page_fault or code == Cause.store_page_fault) and expect_page_fault) {
        page_fault_caught = true;
        expect_page_fault = false;
        uart.writeString("[trap] page fault caught sepc=");
        putHex(frame.sepc);
        uart.writeString(" stval=");
        putHex(frame.stval);
        uart.writeByte('\n');
        frame.sepc += 4;
        return frame;
    }

    uart.writeString("[trap] unhandled scause=");
    putHex(frame.scause);
    uart.writeString(" sepc=");
    putHex(frame.sepc);
    uart.writeString(" stval=");
    putHex(frame.stval);
    uart.writeByte('\n');
    while (true) asm volatile ("wfi");
}

export fn trapEntry() align(4) callconv(.naked) noreturn {
    asm volatile (
        // Swap sp with sscratch. From U: sp:=kstack, sscratch:=user_sp.
        // From S (sscratch=0): sp:=0, sscratch:=old_sp.
        \\csrrw sp, sscratch, sp
        \\bnez sp, 1f
        \\csrr sp, sscratch
        \\csrw sscratch, zero
        \\1:
        \\addi sp, sp, -288
        \\sd ra,   0(sp)
        \\sd gp,  16(sp)
        \\sd tp,  24(sp)
        \\sd t0,  32(sp)
        \\sd t1,  40(sp)
        \\sd t2,  48(sp)
        \\sd s0,  56(sp)
        \\sd s1,  64(sp)
        \\sd a0,  72(sp)
        \\sd a1,  80(sp)
        \\sd a2,  88(sp)
        \\sd a3,  96(sp)
        \\sd a4, 104(sp)
        \\sd a5, 112(sp)
        \\sd a6, 120(sp)
        \\sd a7, 128(sp)
        \\sd s2, 136(sp)
        \\sd s3, 144(sp)
        \\sd s4, 152(sp)
        \\sd s5, 160(sp)
        \\sd s6, 168(sp)
        \\sd s7, 176(sp)
        \\sd s8, 184(sp)
        \\sd s9, 192(sp)
        \\sd s10,200(sp)
        \\sd s11,208(sp)
        \\sd t3, 216(sp)
        \\sd t4, 224(sp)
        \\sd t5, 232(sp)
        \\sd t6, 240(sp)
        // Original SP: from-U still in sscratch; from-S is sp+288.
        \\csrr t0, sscratch
        \\bnez t0, 2f
        \\addi t0, sp, 288
        \\2:
        \\sd t0, 8(sp)
        \\csrr t0, sepc
        \\sd t0, 248(sp)
        \\csrr t0, scause
        \\sd t0, 256(sp)
        \\csrr t0, stval
        \\sd t0, 264(sp)
        \\csrr t0, sstatus
        \\sd t0, 272(sp)
        \\mv a0, sp
        \\call trapHandler
        \\mv sp, a0
        \\ld t0, 248(sp)
        \\csrw sepc, t0
        \\ld t0, 272(sp)
        \\csrw sstatus, t0
        // Prepare sscratch for next trap: U→kstack top, S→0.
        \\andi t1, t0, 0x100
        \\bnez t1, 3f
        \\lla t1, u_trap_stack_top
        \\ld t1, 0(t1)
        \\csrw sscratch, t1
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
        \\ld t0, 8(sp)
        \\mv sp, t0
        \\sret
    );
}
