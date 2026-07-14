//! aarch64 M9-7 milestone glue — shared dual preempt lives in `shared/sk16.zig`.
//!
//! `TrapFrame` / `FRAME_BYTES` stay here so `vectors.S` + `arch_impl` keep a
//! stable layout. Thread stacks and switch state come from `proc/task` + facade.

const uart = @import("uart.zig");
const gic = @import("gic.zig");
const sk16 = @import("../../shared/sk16.zig");

pub const FRAME_BYTES: usize = 192;

/// Must match `irq_el1h_entry` layout in vectors.S.
pub const TrapFrame = extern struct {
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x29: u64,
    x30: u64,
    _pad: u64 = 0,
    elr: u64,
    spsr: u64,
};

comptime {
    if (@sizeOf(TrapFrame) != FRAME_BYTES) @compileError("TrapFrame size mismatch");
}

fn m97Complete() callconv(.c) noreturn {
    uart.writeString("[aarch64] M9-7 complete\n");
    gic.disableCpuIrq();
    while (true) asm volatile ("wfi");
}

pub fn isEnabled() bool {
    return sk16.isEnabled();
}

pub fn onTimer(frame: *TrapFrame) *TrapFrame {
    return @ptrFromInt(sk16.onTimer(@intFromPtr(frame)));
}

pub fn init() void {}

/// Enter shared dual preempt (noreturn). Timer/GIC armed via facade.
pub fn start() noreturn {
    uart.writeString("MoQiOS aarch64: M9-7 (timer + sched)\n");
    sk16.run(m97Complete);
}
