//! EL1 exception handling for the aarch64 skeleton (Milestone 9-2…9-7).

const uart = @import("uart.zig");

extern const exception_vectors: opaque {};

var expect_brk: bool = false;
var brk_caught: bool = false;
var expect_page_fault: bool = false;
var page_fault_caught: bool = false;

fn putStr(s: []const u8) void {
    uart.writeString(s);
}

fn putHex(v: u64) void {
    const hex = "0123456789abcdef";
    putStr("0x");
    var i: u6 = 60;
    while (true) {
        uart.writeByte(hex[@intCast((v >> i) & 0xf)]);
        if (i == 0) break;
        i -= 4;
    }
}

fn readEsrEl1() u64 {
    return asm volatile ("mrs %[r], esr_el1"
        : [r] "=r" (-> u64),
    );
}

fn readElrEl1() u64 {
    return asm volatile ("mrs %[r], elr_el1"
        : [r] "=r" (-> u64),
    );
}

fn writeElrEl1(v: u64) void {
    asm volatile ("msr elr_el1, %[v]"
        :
        : [v] "r" (v),
    );
}

/// Current-EL sync (brk / #PF self-tests).
export fn trapHandleSync(frame: *anyopaque) callconv(.c) void {
    _ = frame;
    const esr = readEsrEl1();
    const ec = (esr >> 26) & 0x3f;
    const elr = readElrEl1();

    if (ec == 0x3c and expect_brk) {
        brk_caught = true;
        writeElrEl1(elr + 4);
        return;
    }

    if ((ec == 0x25 or ec == 0x21) and expect_page_fault) {
        page_fault_caught = true;
        writeElrEl1(elr + 4);
        return;
    }

    putStr("  unexpected sync: esr=");
    putHex(esr);
    putStr(" elr=");
    putHex(elr);
    putStr("\n");
    while (true) asm volatile ("wfi");
}

/// Lower-EL (EL0) sync — SVC and faults from user mode.
/// Returns 0 to `eret` back to EL0. SYS_EXIT never returns here.
export fn trapHandleSyncEl0(frame: *anyopaque) callconv(.c) u64 {
    const esr = readEsrEl1();
    const ec = (esr >> 26) & 0x3f;

    // EC 0x15 = SVC instruction from AArch64.
    if (ec == 0x15) {
        const user = @import("user.zig");
        const tf: *user.TrapFrame = @ptrCast(@alignCast(frame));
        return user.handleSvc(tf);
    }

    putStr("  unexpected EL0 sync: esr=");
    putHex(esr);
    putStr(" elr=");
    putHex(readElrEl1());
    putStr("\n");
    while (true) asm volatile ("wfi");
}

/// Returns the TrapFrame pointer to resume (may switch stacks under M9-7 sched).
export fn trapHandleIrq(frame: *anyopaque) callconv(.c) usize {
    const gic = @import("gic.zig");
    const intid = gic.handleIrq();
    if (intid == gic.TIMER_PPI) {
        @import("timer.zig").onInterrupt();
        const sk15 = @import("../../shared/sk15.zig");
        if (sk15.isEnabled()) {
            return sk15.onTimer(@intFromPtr(frame));
        }
        const sk16 = @import("../../shared/sk16.zig");
        if (sk16.isEnabled()) {
            return sk16.onTimer(@intFromPtr(frame));
        }
        const sk23 = @import("../../shared/sk23.zig");
        if (sk23.isEnabled()) {
            sk23.onTimerIrq();
            return @intFromPtr(frame);
        }
        const sk24 = @import("../../shared/sk24.zig");
        if (sk24.isEnabled()) {
            return sk24.onTimerIrq(@intFromPtr(frame));
        }
        const sk26 = @import("../../shared/sk26.zig");
        if (sk26.isEnabled()) {
            return sk26.onTimerIrq(@intFromPtr(frame));
        }
        const sk27 = @import("../../shared/sk27.zig");
        if (sk27.isEnabled()) {
            return sk27.onTimer(@intFromPtr(frame));
        }
        const sk28 = @import("../../shared/sk28.zig");
        if (sk28.isEnabled()) {
            return sk28.onTimer(@intFromPtr(frame));
        }
        const sk29 = @import("../../shared/sk29.zig");
        if (sk29.isEnabled()) {
            return sk29.onTimer(@intFromPtr(frame));
        }
        const sched = @import("sched.zig");
        if (sched.isEnabled()) {
            const tf: *sched.TrapFrame = @ptrCast(@alignCast(frame));
            return @intFromPtr(sched.onTimer(tf));
        }
    }
    return @intFromPtr(frame);
}

pub fn init() void {
    const vbar: usize = @intFromPtr(&exception_vectors);
    asm volatile ("msr vbar_el1, %[v]"
        :
        : [v] "r" (vbar),
    );
    asm volatile ("isb");
}

pub fn brkSelfTest() bool {
    putStr("MoQiOS aarch64: M9-2 (exception vectors)\n");
    expect_brk = true;
    brk_caught = false;
    asm volatile ("brk #0");
    expect_brk = false;
    if (brk_caught) {
        putStr("  brk trap: OK\n");
        putStr("[aarch64] M9-2 complete\n");
        return true;
    }
    putStr("  brk trap: FAILED\n");
    return false;
}

pub fn armPageFaultTest() void {
    expect_page_fault = true;
    page_fault_caught = false;
}

pub fn pageFaultWasCaught() bool {
    expect_page_fault = false;
    return page_fault_caught;
}
