//! riscv64 M5 milestone glue — shared dual preempt lives in `shared/sk16.zig`.
//!
//! Kept as a thin arch wrapper so `trap.zig` / smoke markers (`M5 complete`)
//! stay stable while stacks/TrapFrames come from `proc/task` + the facade.

const uart = @import("uart.zig");
const trap = @import("trap.zig");
const sk16 = @import("../../shared/sk16.zig");

fn m5Complete() callconv(.c) noreturn {
    uart.writeString("[riscv64] M5 complete; shutting down\n");
    // SBI SRST shutdown
    asm volatile ("ecall"
        :
        : [eid] "{a7}" (@as(usize, 0x53525354)),
          [fid] "{a6}" (@as(usize, 0)),
          [a0] "{a0}" (@as(usize, 0)),
          [a1] "{a1}" (@as(usize, 0)),
        : .{ .memory = true });
    while (true) asm volatile ("wfi");
}

pub fn isEnabled() bool {
    return sk16.isEnabled();
}

pub fn onTimer(frame: *trap.TrapFrame) *trap.TrapFrame {
    return @ptrFromInt(sk16.onTimer(@intFromPtr(frame)));
}

pub fn init() void {}

/// Arm timer + enter shared dual preempt (noreturn).
pub fn start() noreturn {
    uart.writeString("  stimecmp timer armed; starting threads\n");
    sk16.run(m5Complete);
}
