//! Pure getrusage(2) helpers: `who` classification and per-task CPU time.

pub const Who = enum { self, children, thread };

pub fn classify(who_raw: u64) ?Who {
    const who: i32 = @bitCast(@as(u32, @truncate(who_raw)));
    return switch (who) {
        0 => .self,
        -1 => .children,
        1 => .thread,
        else => null,
    };
}

/// Accumulated runtime plus the slice the task is executing right now, which
/// the context-switch accounting has not folded in yet.
pub fn runtimeUs(accumulated_us: u64, sched_in_tsc: u64, now_tsc: u64, tsc_mhz: u64) u64 {
    if (sched_in_tsc == 0 or tsc_mhz == 0 or now_tsc < sched_in_tsc) return accumulated_us;
    return accumulated_us +| (now_tsc - sched_in_tsc) / tsc_mhz;
}

pub const Timeval = struct { sec: u64, usec: u64 };

pub fn timeval(us: u64) Timeval {
    return .{ .sec = us / 1_000_000, .usec = us % 1_000_000 };
}
