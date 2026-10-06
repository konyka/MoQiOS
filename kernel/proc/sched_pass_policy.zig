//! Scheduler pass semantics (pure).
//!
//! A pass is entered by the hardware timer (`tick`), a reschedule IPI
//! (`ipi`) or the yield trap (`yield`, int 252). Only `tick` advances
//! time-based work; forced passes must neither run maintenance nor refill
//! the current task's quantum when it keeps the CPU.

pub const PassKind = enum(u8) { tick = 0, ipi = 1, yield = 2 };

/// Decode `PerCpu.force_reschedule`; any unknown non-zero value is an IPI.
pub fn fromForceFlag(flag: u8) PassKind {
    return switch (flag) {
        0 => .tick,
        @intFromEnum(PassKind.yield) => .yield,
        else => .ipi,
    };
}

pub fn isTimeTick(kind: PassKind) bool {
    return kind == .tick;
}

/// Forced pass with a running RT current: an IPI preempts only for strictly
/// better work; a yield also hands over to an equal-rank peer (POSIX moves
/// the yielder to the tail of its priority list).
pub fn rtKeepsCpu(kind: PassKind, cur_key: u16, best_key: ?u16) bool {
    const best = best_key orelse return true;
    return switch (kind) {
        .yield => best > cur_key,
        .tick, .ipi => best >= cur_key,
    };
}

/// Slice to restore when a forced pass keeps the current task.
pub fn sliceAfterKeep(saved_slice: u64, full_slice: u64) u64 {
    return if (saved_slice == 0) full_slice else saved_slice;
}
