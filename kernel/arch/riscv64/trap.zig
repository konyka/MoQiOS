//! S-mode trap entry + frame for the riscv64 skeleton (Milestone 2).
//!
//! Direct-mode `stvec`: every trap/interrupt lands at `trapEntry`, which
//! saves GPRs + CSR snapshot into a `TrapFrame` on the current stack, calls
//! `trapHandler`, then restores and `sret`s.
//!
//! M2 only needs to prove illegal-instruction traps are caught; later
//! milestones grow this into a full interrupt/syscall path.

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

/// Exception / interrupt codes.
pub const Cause = struct {
    pub const illegal_instruction: u64 = 2;
    pub const breakpoint: u64 = 3;
    pub const load_page_fault: u64 = 13;
    pub const store_page_fault: u64 = 15;
    pub const ecall_from_s: u64 = 9;
    pub const supervisor_timer: u64 = 5; // interrupt
};

/// Trap frame allocation size (16-byte aligned; matches trapEntry asm).
pub const FRAME_BYTES: usize = 288;

var trap_count: u64 = 0;
var last_scause: u64 = 0;
var last_sepc: u64 = 0;
var last_stval: u64 = 0;

/// Set by the breakpoint self-test so the handler can skip the insn.
var expect_breakpoint: bool = false;
var breakpoint_caught: bool = false;

/// Set by the page-fault self-test (M3).
var expect_page_fault: bool = false;
var page_fault_caught: bool = false;

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

/// Install `trapEntry` as the direct-mode supervisor trap vector.
pub fn init() void {
    const entry: usize = @intFromPtr(&trapEntry);
    asm volatile ("csrw stvec, %[e]"
        :
        : [e] "r" (entry),
        : .{ .memory = true });
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

/// Called from `trapEntry` with a0 = &TrapFrame.
/// Returns the TrapFrame pointer to restore (may be another task's after M5 switch).
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
        const sched = @import("sched.zig");
        return sched.onTimer(frame);
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

/// Naked trap entry: allocate TrapFrame on stack, save GPRs + CSRs, call
/// trapHandler (returns frame to restore in a0), restore, sret.
export fn trapEntry() align(4) callconv(.naked) noreturn {
    asm volatile (
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
        \\addi t0, sp, 288
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
        \\addi sp, sp, 288
        \\sret
    );
}
