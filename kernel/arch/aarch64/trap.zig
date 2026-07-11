//! EL1 exception handling for the aarch64 skeleton (Milestone 9-2).
//!
//! Installs `exception_vectors` into VBAR_EL1 and self-tests with `brk #0`.

const uart = @import("uart.zig");

extern const exception_vectors: opaque {};

var expect_brk: bool = false;
var brk_caught: bool = false;

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

/// Called from `sync_el1h_entry` with a pointer to the saved register frame.
export fn trapHandleSync(frame: *anyopaque) callconv(.c) void {
    _ = frame;
    const esr = readEsrEl1();
    const ec = (esr >> 26) & 0x3f;
    const elr = readElrEl1();

    // EC 0x3c = BRK instruction from AArch64.
    if (ec == 0x3c and expect_brk) {
        brk_caught = true;
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
