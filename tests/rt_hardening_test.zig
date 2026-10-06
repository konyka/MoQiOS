//! Host tests for the real-time / security hardening plan
//! (docs/realtime-security-hardening-plan.md).

const std = @import("std");
const kt = @import("kernel_shared");

const sleep_policy = kt.sleep_policy;
const rusage_policy = kt.rusage_policy;
const time_policy = kt.time_policy;
const cpu_protect_policy = kt.cpu_protect_policy;
const wake_preempt_policy = kt.wake_preempt_policy;
const sched_pass_policy = kt.sched_pass_policy;
const deadline_hint = kt.deadline_hint;
const sched_policy = kt.sched_policy;

const maxU64 = std.math.maxInt(u64);

// ── P1-1: sleep planning ────────────────────────────────────────────────

fn expectSleep(plan: sleep_policy.Plan, deadline: u64) !void {
    switch (plan) {
        .sleep => |d| try std.testing.expectEqual(deadline, d),
        else => return error.TestExpectedSleep,
    }
}

test "relative sleep validates the timespec and saturates the deadline" {
    const p = sleep_policy;
    try std.testing.expect(p.planRelative(0, 0, 1_000) == .immediate);
    try expectSleep(p.planRelative(1, 500, 1_000), 1_000 + 1_000_000_500);
    try std.testing.expect(p.planRelative(-1, 0, 1_000) == .invalid);
    try std.testing.expect(p.planRelative(0, -1, 1_000) == .invalid);
    try std.testing.expect(p.planRelative(0, 1_000_000_000, 1_000) == .invalid);
    // Unrepresentable requests mean "until a signal", never an overflow panic.
    try expectSleep(p.planRelative(std.math.maxInt(i64), 999_999_999, 5), maxU64);
    try expectSleep(p.planRelative(1, 0, maxU64 - 10), maxU64);
}

test "clock sleep rejects unknown clocks and flags" {
    const p = sleep_policy;
    try std.testing.expect(p.planClock(2, 0, 0, 100, 1_000, 0) == .invalid);
    try std.testing.expect(p.planClock(time_policy.CLOCK_MONOTONIC, 2, 0, 100, 1_000, 0) == .invalid);
    try std.testing.expect(p.planClock(time_policy.CLOCK_MONOTONIC, 0, 0, 1_000_000_000, 1_000, 0) == .invalid);
    try std.testing.expect(p.planClock(time_policy.CLOCK_MONOTONIC, time_policy.TIMER_ABSTIME, -1, 0, 1_000, 0) == .invalid);
}

test "clock sleep converts absolute deadlines into monotonic deadlines" {
    const p = sleep_policy;
    const abs = time_policy.TIMER_ABSTIME;
    try std.testing.expect(p.planClock(time_policy.CLOCK_MONOTONIC, abs, 0, 500, 1_000, 0) == .immediate);
    try expectSleep(p.planClock(time_policy.CLOCK_MONOTONIC, abs, 0, 3_000, 1_000, 0), 3_000);
    // Wall now = 1_000 + 5_000; the wall deadline 10_000 is 4_000 ns away.
    try expectSleep(p.planClock(time_policy.CLOCK_REALTIME, abs, 0, 10_000, 1_000, 5_000), 5_000);
    // Relative sleeps ignore the wall offset.
    try expectSleep(p.planClock(time_policy.CLOCK_REALTIME, 0, 0, 100, 1_000, 5_000), 1_100);
    try expectSleep(p.planClock(time_policy.CLOCK_MONOTONIC, abs, std.math.maxInt(i64), 0, 1_000, 0), maxU64);
}

test "only relative sleeps report the remaining time" {
    const p = sleep_policy;
    try std.testing.expect(p.writesRemaining(0));
    try std.testing.expect(!p.writesRemaining(time_policy.TIMER_ABSTIME));
    const r = p.remaining(5_000_000_123 + 100, 100);
    try std.testing.expectEqual(@as(u64, 5), r.sec);
    try std.testing.expectEqual(@as(u64, 123), r.nsec);
    const done = p.remaining(10, 20);
    try std.testing.expectEqual(@as(u64, 0), done.sec);
    try std.testing.expectEqual(@as(u64, 0), done.nsec);
}

// ── P1-1: getrusage accounting ──────────────────────────────────────────

test "getrusage accepts only SELF, CHILDREN and THREAD" {
    const p = rusage_policy;
    try std.testing.expectEqual(@as(?p.Who, .self), p.classify(0));
    try std.testing.expectEqual(@as(?p.Who, .children), p.classify(@bitCast(@as(i64, -1))));
    try std.testing.expectEqual(@as(?p.Who, .thread), p.classify(1));
    try std.testing.expectEqual(@as(?p.Who, null), p.classify(2));
    try std.testing.expectEqual(@as(?p.Who, null), p.classify(5));
    // `who` is a C int: only the low 32 bits are significant.
    try std.testing.expectEqual(@as(?p.Who, .children), p.classify(0xFFFF_FFFF));
}

test "getrusage adds the in-flight slice of a running task" {
    const p = rusage_policy;
    try std.testing.expectEqual(@as(u64, 100), p.runtimeUs(100, 0, 999, 1_000));
    try std.testing.expectEqual(@as(u64, 3_100), p.runtimeUs(100, 1_000, 3_001_000, 1_000));
    try std.testing.expectEqual(@as(u64, 100), p.runtimeUs(100, 5_000, 4_000, 1_000));
    try std.testing.expectEqual(@as(u64, 100), p.runtimeUs(100, 1_000, 9_000, 0));
    try std.testing.expectEqual(maxU64, p.runtimeUs(maxU64 - 1, 1, maxU64, 1));
    const tv = p.timeval(3_500_001);
    try std.testing.expectEqual(@as(u64, 3), tv.sec);
    try std.testing.expectEqual(@as(u64, 500_001), tv.usec);
}

// ── P1-2: CPU protection bits ───────────────────────────────────────────

test "CR4 protection bits follow CPUID leaf 7" {
    const p = cpu_protect_policy;
    const none = p.features(6, 0xFFFF_FFFF, 0xFFFF_FFFF);
    try std.testing.expect(!none.smep and !none.umip and !none.smap);
    try std.testing.expectEqual(@as(u64, 0), p.cr4Bits(none));

    const smep = p.features(7, p.CPUID7_EBX_SMEP, 0);
    try std.testing.expect(smep.smep and !smep.umip and !smep.smap);
    try std.testing.expectEqual(p.CR4_SMEP, p.cr4Bits(smep));

    const umip = p.features(7, 0, p.CPUID7_ECX_UMIP);
    try std.testing.expect(!umip.smep and umip.umip);
    try std.testing.expectEqual(p.CR4_UMIP, p.cr4Bits(umip));
}

test "SMAP is enabled together with SMEP and UMIP" {
    const p = cpu_protect_policy;
    const all = p.features(7, p.CPUID7_EBX_SMEP | p.CPUID7_EBX_SMAP, p.CPUID7_ECX_UMIP);
    try std.testing.expect(all.smap);
    try std.testing.expectEqual(p.CR4_SMEP | p.CR4_UMIP | p.CR4_SMAP, p.cr4Bits(all));
    try std.testing.expectEqual(@as(u64, 1 << 20), p.CR4_SMEP);
    try std.testing.expectEqual(@as(u64, 1 << 11), p.CR4_UMIP);
    try std.testing.expectEqual(@as(u64, 1 << 21), p.CR4_SMAP);
}

// ── P2-1: wake preemption ───────────────────────────────────────────────

test "local wake preempts only for a strictly better-ranked task" {
    const p = wake_preempt_policy;
    // RT prio 50 (key 49) woken while OTHER (key 120) runs here.
    try std.testing.expectEqual(p.Action.preempt_local, p.decide(49, 120, true));
    // Equal rank on the same CPU waits for the quantum: no ping-pong.
    try std.testing.expectEqual(p.Action.none, p.decide(120, 120, true));
    try std.testing.expectEqual(p.Action.none, p.decide(130, 120, true));
    // The idle task (OTHER prio 255) is always beaten.
    const idle = sched_policy.rankKey(sched_policy.SCHED_OTHER, 255);
    try std.testing.expectEqual(p.Action.preempt_local, p.decide(139, idle, true));
    // No running current here (blocking / early boot): the CPU picks anyway.
    try std.testing.expectEqual(p.Action.none, p.decide(0, null, true));
}

test "remote wake kicks unless the woken task is strictly worse" {
    const p = wake_preempt_policy;
    try std.testing.expectEqual(p.Action.kick_remote, p.decide(49, 120, false));
    // Equal rank still kicks: a signal to the remote current is the same task.
    try std.testing.expectEqual(p.Action.kick_remote, p.decide(120, 120, false));
    try std.testing.expectEqual(p.Action.none, p.decide(120, 49, false));
    // Unknown / blocked remote current: kick conservatively.
    try std.testing.expectEqual(p.Action.kick_remote, p.decide(200, null, false));
}

// ── P2-2: forced scheduler passes ───────────────────────────────────────

test "reschedule IPI keeps a running RT task unless something strictly better is ready" {
    const p = sched_pass_policy;
    try std.testing.expect(p.rtKeepsCpu(.ipi, 49, null));
    try std.testing.expect(p.rtKeepsCpu(.ipi, 49, 49));
    try std.testing.expect(p.rtKeepsCpu(.ipi, 49, 120));
    try std.testing.expect(!p.rtKeepsCpu(.ipi, 49, 10));
}

test "RT sched_yield gives the CPU to an equal-priority peer" {
    const p = sched_pass_policy;
    try std.testing.expect(!p.rtKeepsCpu(.yield, 49, 49));
    try std.testing.expect(!p.rtKeepsCpu(.yield, 49, 10));
    try std.testing.expect(p.rtKeepsCpu(.yield, 49, 120));
    try std.testing.expect(p.rtKeepsCpu(.yield, 49, null));
}

test "a forced pass that keeps the task preserves its RR quantum" {
    const p = sched_pass_policy;
    try std.testing.expectEqual(@as(u64, 3), p.sliceAfterKeep(3, 10));
    try std.testing.expectEqual(@as(u64, 10), p.sliceAfterKeep(0, 10));
}

test "only hardware ticks drive time-based maintenance" {
    const p = sched_pass_policy;
    try std.testing.expect(p.isTimeTick(.tick));
    try std.testing.expect(!p.isTimeTick(.ipi));
    try std.testing.expect(!p.isTimeTick(.yield));
    try std.testing.expectEqual(p.PassKind.tick, p.fromForceFlag(0));
    try std.testing.expectEqual(p.PassKind.ipi, p.fromForceFlag(@intFromEnum(p.PassKind.ipi)));
    try std.testing.expectEqual(p.PassKind.yield, p.fromForceFlag(@intFromEnum(p.PassKind.yield)));
    try std.testing.expectEqual(p.PassKind.ipi, p.fromForceFlag(0xEE));
}

// ── P2-3: timer deadline hint ───────────────────────────────────────────

test "deadline hint gates the tick fast path" {
    var h: deadline_hint.DeadlineHint = .{};
    try std.testing.expect(!h.due(0));
    try std.testing.expect(!h.due(1 << 40));
    h.arm(80);
    h.arm(50);
    h.arm(90);
    try std.testing.expect(!h.due(49));
    try std.testing.expect(h.due(50));
    h.beginScan();
    try std.testing.expect(!h.due(1 << 40));
    h.arm(90);
    try std.testing.expect(!h.due(89));
    try std.testing.expect(h.due(90));
}

test "deadline hint stays a lower bound of every armed timer (model)" {
    const N = 16;
    var expiry: [N]?u64 = @splat(null);
    var h: deadline_hint.DeadlineHint = .{};
    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const r = prng.random();
    var now: u64 = 1;
    var step: usize = 0;
    while (step < 20_000) : (step += 1) {
        const i = r.uintLessThan(usize, N);
        switch (r.uintLessThan(u8, 4)) {
            0 => { // settime arm
                const e = now + r.uintLessThan(u64, 200);
                expiry[i] = e;
                h.arm(e);
            },
            1 => expiry[i] = null, // disarm leaves a stale (lower) hint: harmless
            2 => { // tick: scan only when the hint says something is due
                now += r.uintLessThan(u64, 20);
                if (h.due(now)) {
                    h.beginScan();
                    for (&expiry, 0..) |*e, k| {
                        const v = e.* orelse continue;
                        // A timer armed mid-scan (lock dropped to wake waiters).
                        if (k == i and r.boolean()) {
                            const late = now + 5;
                            expiry[(k + 1) % N] = late;
                            h.arm(late);
                        }
                        if (v <= now) e.* = null else h.arm(v);
                    }
                }
            },
            else => now += 1,
        }
        var min: ?u64 = null;
        for (expiry) |e| if (e) |v| {
            if (min == null or v < min.?) min = v;
        };
        if (min) |m| {
            // Never miss: whenever the earliest armed timer is due, so is the hint.
            if (now >= m) try std.testing.expect(h.due(now));
            try std.testing.expect(h.due(m));
        }
    }
}

// ── P2-4: idle-class tasks never displace runnable work ─────────────────

fn chooseFrom(keys: []const u16) ?u32 {
    var c: sched_policy.PopChoice = .{};
    for (keys, 0..) |k, pos| c.consider(@intCast(pos), k);
    return c.choice();
}

test "queue pop prefers the best RT task, oldest first on ties" {
    const idle = sched_policy.rankKey(sched_policy.SCHED_OTHER, 255);
    try std.testing.expectEqual(@as(?u32, 2), chooseFrom(&.{ 120, idle, 49, 49, 10 + 100 }));
    try std.testing.expectEqual(@as(?u32, 3), chooseFrom(&.{ 120, 70, 70, 10 }));
}

test "queue pop skips idle-class entries while normal work is queued" {
    const idle = sched_policy.rankKey(sched_policy.SCHED_OTHER, 255);
    try std.testing.expectEqual(@as(?u32, 1), chooseFrom(&.{ idle, 120, 110 }));
    try std.testing.expectEqual(@as(?u32, 0), chooseFrom(&.{ 125, 120 }));
    try std.testing.expectEqual(@as(?u32, 0), chooseFrom(&.{ idle, idle }));
    try std.testing.expectEqual(@as(?u32, null), chooseFrom(&.{}));
}

test "a runnable task is never traded for an idle-class pick on its own CPU" {
    const idle = sched_policy.rankKey(sched_policy.SCHED_OTHER, 255);
    try std.testing.expect(sched_policy.keepsCpuOverIdle(120, idle, true));
    try std.testing.expect(sched_policy.keepsCpuOverIdle(49, idle, true));
    try std.testing.expect(!sched_policy.keepsCpuOverIdle(120, 125, true));
    // Re-pinned elsewhere (sched_setaffinity): it must leave even for idle.
    try std.testing.expect(!sched_policy.keepsCpuOverIdle(120, idle, false));
    // The idle task itself has nothing to keep.
    try std.testing.expect(!sched_policy.keepsCpuOverIdle(idle, idle, true));
}

// ── P2-5: epoll timeouts on the monotonic ns clock ──────────────────────

test "epoll timeout deadline is an absolute monotonic ns value" {
    const ep = kt.epoll_policy;
    try std.testing.expectEqual(@as(?u64, 1_000 + 20 * std.time.ns_per_ms), ep.timeoutDeadlineNs(1_000, 20));
    try std.testing.expectEqual(@as(?u64, null), ep.timeoutDeadlineNs(1_000, 0));
    try std.testing.expectEqual(@as(?u64, null), ep.timeoutDeadlineNs(1_000, -1));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), ep.timeoutDeadlineNs(std.math.maxInt(u64) - 5, 1));
    const big = ep.timeoutDeadlineNs(0, std.math.maxInt(i32)).?;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i32)) * std.time.ns_per_ms, big);
}

// ── P2-6: framebuffer console off the IRQ-off write path ────────────────

const fbcon_core = kt.fbcon_core;
const fbcon_render = kt.fbcon_render;
const font_w = kt.fbcon_font.GLYPH_W;
const font_h = kt.fbcon_font.GLYPH_H;

fn Screen(comptime cols: u16, comptime rows: u16) type {
    return struct {
        const pitch: u32 = cols * font_w * 4;
        pixels: [pitch * rows * font_h]u8 align(4) = @splat(0xAB),

        fn surface(self: *@This()) fbcon_render.Surface {
            return .{ .buf = &self.pixels, .pitch = pitch };
        }
    };
}

fn renderReference(comptime S: type, core: *const fbcon_core.Core) S {
    var ref: S = .{};
    var r: fbcon_render.Renderer = .{};
    r.requestRepaint();
    while (r.repaintStep(core, ref.surface()) == .more) {}
    return ref;
}

test "console writes paint only the changed cells, however much they scroll" {
    const S = Screen(8, 3);
    var screen: S = .{};
    var core = fbcon_core.Core.init(8, 3);
    var r: fbcon_render.Renderer = .{};

    r.write(&core, screen.surface(), "ab");
    try std.testing.expectEqual(@as(u64, 2 + 1), r.glyphs_painted); // 2 glyphs + cursor restore
    r.write(&core, screen.surface(), "\n\n"); // cursor on the last row, no scroll yet
    try std.testing.expect(!r.repaint_pending);

    const before = screen.pixels;
    const flood = "\n0123456" ** 40;
    r.glyphs_painted = 0;
    r.write(&core, screen.surface(), flood);
    try std.testing.expectEqual(@as(u64, 0), r.glyphs_painted);
    try std.testing.expect(r.repaint_pending);
    // A scroll never moves pixels inside the framebuffer: everything already
    // on screen stays byte-identical until the deferred repaint runs.
    try std.testing.expectEqualSlices(u8, &before, &screen.pixels);
}

test "a pending repaint advances exactly one text row per step" {
    const S = Screen(6, 4);
    var screen: S = .{};
    var core = fbcon_core.Core.init(6, 4);
    var r: fbcon_render.Renderer = .{};
    r.write(&core, screen.surface(), "a\nb\nc\nd\ne\n");
    try std.testing.expect(r.repaint_pending);

    var steps: u32 = 0;
    while (true) {
        r.glyphs_painted = 0;
        const step = r.repaintStep(&core, screen.surface());
        steps += 1;
        try std.testing.expect(r.glyphs_painted <= 6);
        if (step == .done) break;
        try std.testing.expectEqual(fbcon_render.Step.more, step);
    }
    try std.testing.expectEqual(@as(u32, 4), steps);
    try std.testing.expectEqual(fbcon_render.Step.idle, r.repaintStep(&core, screen.surface()));
    try std.testing.expectEqualSlices(u8, &renderReference(S, &core).pixels, &screen.pixels);
}

test "the idle repaint yields to an active console writer" {
    const q = fbcon_render.QUIET_NS;
    try std.testing.expect(!fbcon_render.repaintMayRun(1_000, 1_000));
    try std.testing.expect(!fbcon_render.repaintMayRun(1_000 + q - 1, 1_000));
    try std.testing.expect(fbcon_render.repaintMayRun(1_000 + q, 1_000));
    // A newer stamp from another CPU's clock reads as "just written".
    try std.testing.expect(!fbcon_render.repaintMayRun(1_000, 5_000));
    // Nothing written yet: a pending repaint may run.
    try std.testing.expect(fbcon_render.repaintMayRun(q, 0));
}

test "interleaved writes and repaint steps converge to the cell grid" {
    const S = Screen(10, 5);
    var screen: S = .{};
    var core = fbcon_core.Core.init(10, 5);
    var r: fbcon_render.Renderer = .{};
    r.requestRepaint();

    var prng = std.Random.DefaultPrng.init(0xfbc0_2026);
    const rand = prng.random();
    const alphabet = "abcXYZ019 .-\n\n\n\r\t\x08";
    var round: u32 = 0;
    while (round < 4000) : (round += 1) {
        if (rand.boolean()) {
            var chunk: [12]u8 = undefined;
            const n = rand.intRangeAtMost(usize, 1, chunk.len);
            for (chunk[0..n]) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
            r.write(&core, screen.surface(), chunk[0..n]);
        } else {
            _ = r.repaintStep(&core, screen.surface());
        }
        if (!r.repaint_pending and rand.uintLessThan(u32, 8) == 0) {
            // Quiescent: the screen must already show exactly the grid.
            try std.testing.expectEqualSlices(u8, &renderReference(S, &core).pixels, &screen.pixels);
        }
    }
    while (r.repaintStep(&core, screen.surface()) != .idle) {}
    try std.testing.expectEqualSlices(u8, &renderReference(S, &core).pixels, &screen.pixels);
}
