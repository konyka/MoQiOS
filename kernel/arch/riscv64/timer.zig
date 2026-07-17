//! Supervisor timer for riscv64 skeleton (Milestone 5).
//!
//! Uses the Sstc extension (`stimecmp`) which QEMU virt + OpenSBI expose.
//! Timebase on virt is typically 10 MHz (see OpenSBI "aclint-mtimer @ 10000000Hz").

const STIE: usize = 1 << 5; // sie / sip supervisor-timer bit

var interval_ticks: u64 = 100_000; // ~10 ms at 10 MHz
var ticks: u64 = 0;
var hook: ?*const fn () void = null;

fn readTime() u64 {
    return asm volatile ("csrr %[r], time"
        : [r] "=r" (-> u64));
}

fn writeStimecmp(v: u64) void {
    // CSR 0x14D = stimecmp (Sstc). Numeric form avoids assembler name gaps.
    asm volatile ("csrw 0x14d, %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub fn init(interval: u64) void {
    if (interval != 0) interval_ticks = interval;
    // Enable supervisor timer interrupts in sie; sstatus.SIE is left to caller.
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (STIE),
        : .{ .memory = true });
    armNext();
}

/// SK-36: stop shared-preempt timer IRQs after the probe ladder.
pub fn disarm() void {
    asm volatile ("csrc sie, %[b]"
        :
        : [b] "r" (STIE),
        : .{ .memory = true });
    // Far-future deadline so a stale compare cannot fire if STIE is re-enabled.
    writeStimecmp(~@as(u64, 0));
}

pub fn setHook(h: *const fn () void) void {
    hook = h;
}

pub fn armNext() void {
    writeStimecmp(readTime() +% interval_ticks);
}

/// Called from the trap handler on supervisor-timer interrupt.
pub fn onInterrupt() void {
    ticks +%= 1;
    armNext();
    if (hook) |h| h();
}

pub fn getTicks() u64 {
    return ticks;
}
