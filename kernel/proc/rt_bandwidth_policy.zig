//! Per-CPU RT runtime throttle (Linux-style sched_rt_runtime / period).
//!
//! Without a cap, a spinning SCHED_FIFO/RR task never gives the CPU to
//! SCHED_OTHER: fork of a second RR child (hello44) and any OTHER work on
//! that CPU stall until the RT task blocks. With a cap, RT as a class may
//! run for RUNTIME_TICKS of every PERIOD_TICKS (~95% of 1 s at 100 Hz);
//! the remainder is OTHER's, even if RT work is still runnable.
//!
//! Strict RR (quantum expiry never hands the CPU to a lower-ranked task)
//! is only safe together with this throttle.

/// 100 Hz × 1 s. Matches TIMESLICE accounting: one hardware tick = one unit.
pub const PERIOD_TICKS: u32 = 100;
/// 95 % of the period, Linux's default sched_rt_runtime_us / sched_rt_period_us.
pub const RUNTIME_TICKS: u32 = 95;

pub const Bucket = struct {
    period_start: u64 = 0,
    used: u32 = 0,

    pub fn roll(self: *Bucket, now_tick: u64) void {
        if (now_tick -| self.period_start >= PERIOD_TICKS) {
            self.period_start = now_tick;
            self.used = 0;
        }
    }

    /// Account one hardware tick spent running an RT task.
    pub fn onRtTick(self: *Bucket, now_tick: u64) void {
        self.roll(now_tick);
        self.used +|= 1;
    }

    pub fn throttled(self: *const Bucket, now_tick: u64) bool {
        _ = now_tick;
        return self.used >= RUNTIME_TICKS;
    }
};

/// RR at quantum expiry: keep the CPU when the pick is strictly worse and
/// the RT band still has budget. Equal keys rotate (POSIX RR).
pub fn rrKeepsOver(cur_key: u16, next_key: u16, throttled: bool) bool {
    if (throttled) return false;
    return next_key > cur_key;
}

/// Combine the rank-based keep decision (`rank_keeps`, from rtKeepsCpu) with
/// the throttle: a throttled RT task always yields to OTHER.
pub fn mayKeep(throttled: bool, rank_keeps: bool) bool {
    return !throttled and rank_keeps;
}
