//! Per-CPU interrupt time accounting (pure part).
//!
//! Every interrupt entry on a CPU adds the cycles spent between entry and
//! exit of the dispatcher. Nested interrupts are counted only at the
//! outermost level, so time is never counted twice.

pub const MAX_CPUS = 64;

pub const Acc = struct {
    depth: u32 = 0,
    start_tsc: u64 = 0,
    total_cycles: u64 = 0,
    max_cycles: u64 = 0,
    count: u64 = 0,

    /// `from_user`: the interrupted context was user mode, so this entry is
    /// the outermost one whatever `depth` says. Some kernel paths entered
    /// from an interrupt never return through it (a task killed from a
    /// fault handler, a switch that resumes another task's frame), which
    /// would otherwise leave `depth` stuck above zero and stop all counting.
    pub fn enter(self: *Acc, now: u64, from_user: bool) void {
        if (from_user) self.depth = 0;
        if (self.depth == 0) self.start_tsc = now;
        self.depth += 1;
    }

    pub fn exit(self: *Acc, now: u64) void {
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.depth != 0) return;
        const d = if (now >= self.start_tsc) now - self.start_tsc else 0;
        self.total_cycles +|= d;
        if (d > self.max_cycles) self.max_cycles = d;
        self.count +|= 1;
    }
};

pub fn cyclesToUs(cycles: u64, tsc_mhz: u64) u64 {
    if (tsc_mhz == 0) return 0;
    return cycles / tsc_mhz;
}
