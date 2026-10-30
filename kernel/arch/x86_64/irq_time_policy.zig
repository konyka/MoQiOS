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
    /// Vector of the outermost interrupt currently being timed, and of the
    /// longest one so far (with the TSC at which it started).
    cur_vector: u8 = 0,
    max_vector: u8 = 0,
    max_start_tsc: u64 = 0,
    /// Longest outermost interrupt since the last `takeWindow`, with its
    /// vector and start: lets a reader that samples before and after an
    /// interval learn what ran long inside it, not just since boot.
    win_cycles: u64 = 0,
    win_vector: u8 = 0,
    win_start_tsc: u64 = 0,

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

    /// `enter` that also records which vector the outermost level is.
    pub fn enterVec(self: *Acc, now: u64, from_user: bool, vector: u8) void {
        self.enter(now, from_user);
        if (self.depth == 1) self.cur_vector = vector;
    }

    pub fn exit(self: *Acc, now: u64) void {
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.depth != 0) return;
        const d = if (now >= self.start_tsc) now - self.start_tsc else 0;
        self.total_cycles +|= d;
        if (d > self.max_cycles) {
            self.max_cycles = d;
            self.max_vector = self.cur_vector;
            self.max_start_tsc = self.start_tsc;
        }
        self.count +|= 1;
        if (d > self.win_cycles) {
            self.win_cycles = d;
            self.win_vector = self.cur_vector;
            self.win_start_tsc = self.start_tsc;
        }
    }

    pub const Window = struct { cycles: u64, vector: u8, start_tsc: u64 };

    /// The longest interrupt since the previous call, then start a new window.
    pub fn takeWindow(self: *Acc) Window {
        const w: Window = .{ .cycles = self.win_cycles, .vector = self.win_vector, .start_tsc = self.win_start_tsc };
        self.win_cycles = 0;
        self.win_vector = 0;
        self.win_start_tsc = 0;
        return w;
    }
};

pub fn cyclesToUs(cycles: u64, tsc_mhz: u64) u64 {
    if (tsc_mhz == 0) return 0;
    return cycles / tsc_mhz;
}

test "outermost interrupts are timed once, nested ones are not double counted" {
    const std = @import("std");
    var a: Acc = .{};
    a.enterVec(100, false, 32);
    a.enterVec(150, false, 33); // nested: still the outer vector
    a.exit(180);
    a.exit(300);
    try std.testing.expectEqual(@as(u64, 200), a.total_cycles);
    try std.testing.expectEqual(@as(u64, 1), a.count);
    try std.testing.expectEqual(@as(u8, 32), a.max_vector);
}

test "a window reports the longest interrupt since the last take, then resets" {
    const std = @import("std");
    var a: Acc = .{};
    a.enterVec(0, true, 14);
    a.exit(1000); // long, before the window
    _ = a.takeWindow();
    a.enterVec(2000, true, 240);
    a.exit(2100);
    a.enterVec(3000, true, 14);
    a.exit(3800);
    const w = a.takeWindow();
    try std.testing.expectEqual(@as(u64, 800), w.cycles);
    try std.testing.expectEqual(@as(u8, 14), w.vector);
    try std.testing.expectEqual(@as(u64, 3000), w.start_tsc);
    const again = a.takeWindow();
    try std.testing.expectEqual(@as(u64, 0), again.cycles);
    // the boot-wide maximum is untouched by taking a window
    try std.testing.expectEqual(@as(u64, 1000), a.max_cycles);
}
