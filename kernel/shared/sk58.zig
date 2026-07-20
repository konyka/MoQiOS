//! SK-58 — portable timestamp/tick sources for TCP on non-x86.
//!
//! tcp.zig's generateIss() used a raw `rdtsc` (x86-only) for its initial send
//! sequence, and nowMs() reads the tick counter. Both now go through the arch
//! facade (`arch.tsc.read` = rdtsc / rdtime / cntvct_el0; `getTickCount`),
//! removing the last hard x86 asm from the TCP time path. This probe validates
//! those two sources actually work on riscv64/aarch64: tsc.read() is monotonic
//! non-decreasing across a busy wait, and getTickCount() is callable without
//! faulting — so a future TCP port can rely on them.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-58] portable tcp time sources non-x86: OK\n");
        return;
    }

    // tsc.read() must be monotonic non-decreasing across a short busy wait.
    const t1 = arch.tsc.read();
    var spin: u32 = 0;
    var sink: u32 = 0;
    while (spin < 100_000) : (spin += 1) sink +%= spin;
    const t2 = arch.tsc.read();
    if (t2 < t1) {
        arch.serial.writeString("[SK-58] FAILED: tsc went backwards\n");
        return;
    }

    // Fold like generateIss() does — must not fault and should be usable.
    const iss: u32 = @truncate(t2 ^ (t2 >> 32));
    _ = iss;

    // getTickCount() must be callable (value may be 0 pre-timer, that's fine).
    _ = arch.interrupts.getTickCount();

    // Keep `sink` observable so the busy loop isn't optimized away.
    if (sink == 0xFFFF_FFFF) {
        arch.serial.writeString("[SK-58] (sentinel)\n");
    }

    arch.serial.writeString("[SK-58] portable tcp time sources non-x86: OK\n");
}
