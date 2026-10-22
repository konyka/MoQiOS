const std = @import("std");
const p = @import("kernel_shared").sigaltstack_policy;
const kb = @import("kernel_shared").kill_broadcast_policy;

const alt: p.AltStack = .{ .base = 0x10_0000, .size = 0x4000 };

test "onStack covers (base, base + size]" {
    try std.testing.expect(!p.onStack(alt.base, alt));
    try std.testing.expect(p.onStack(alt.base + 1, alt));
    try std.testing.expect(p.onStack(alt.base + alt.size, alt));
    try std.testing.expect(!p.onStack(alt.base + alt.size + 1, alt));
    try std.testing.expect(!p.onStack(alt.base + 8, .{}));
}

test "SA_ONSTACK handler is delivered on the alternate stack" {
    const top = p.deliveryTop(0x7F_0000, p.SA_ONSTACK, alt);
    try std.testing.expectEqual(alt.base + alt.size, top);
}

test "handlers without SA_ONSTACK stay on the interrupted stack" {
    try std.testing.expectEqual(@as(u64, 0x7F_0000), p.deliveryTop(0x7F_0000, 0, alt));
}

test "nested delivery while on the alternate stack does not reset it" {
    const rsp = alt.base + 0x1000;
    try std.testing.expectEqual(rsp, p.deliveryTop(rsp, p.SA_ONSTACK, alt));
}

test "disabled alternate stack falls back to the interrupted stack" {
    try std.testing.expectEqual(@as(u64, 0x7F_0000), p.deliveryTop(0x7F_0000, p.SA_ONSTACK, .{}));
}

test "set validates flags and size" {
    switch (p.set(0x7F_0000, .{}, 0x20_0000, 0, 0x4000)) {
        .ok => |a| try std.testing.expectEqual(@as(u64, 0x4000), a.size),
        .err => return error.Unexpected,
    }
    switch (p.set(0x7F_0000, .{}, 0x20_0000, 0, 1024)) {
        .ok => return error.Unexpected,
        .err => |e| try std.testing.expectEqual(p.ENOMEM, e),
    }
    switch (p.set(0x7F_0000, .{}, 0x20_0000, 0x10, 0x4000)) {
        .ok => return error.Unexpected,
        .err => |e| try std.testing.expectEqual(p.EINVAL, e),
    }
    switch (p.set(0x7F_0000, alt, 0, p.SS_DISABLE, 0)) {
        .ok => |a| try std.testing.expect(!a.enabled()),
        .err => return error.Unexpected,
    }
}

test "changing the stack while running on it is EPERM" {
    switch (p.set(alt.base + 0x100, alt, 0x20_0000, 0, 0x4000)) {
        .ok => return error.Unexpected,
        .err => |e| try std.testing.expectEqual(p.EPERM, e),
    }
}

test "reported flags" {
    try std.testing.expectEqual(p.SS_DISABLE, p.currentFlags(0x7F_0000, .{}));
    try std.testing.expectEqual(@as(u32, 0), p.currentFlags(0x7F_0000, alt));
    try std.testing.expectEqual(p.SS_ONSTACK, p.currentFlags(alt.base + 0x100, alt));
}

const proc_cand: kb.Candidate = .{ .is_user = true, .is_thread = false, .zombie = false, .is_init = false, .same_thread_group = false };

test "kill(-1) targets other live user processes" {
    try std.testing.expect(kb.isTarget(proc_cand));
}

test "kill(-1) skips init, the caller, threads, zombies and kernel tasks" {
    var c = proc_cand;
    c.is_init = true;
    try std.testing.expect(!kb.isTarget(c));
    c = proc_cand;
    c.same_thread_group = true;
    try std.testing.expect(!kb.isTarget(c));
    c = proc_cand;
    c.is_thread = true;
    try std.testing.expect(!kb.isTarget(c));
    c = proc_cand;
    c.zombie = true;
    try std.testing.expect(!kb.isTarget(c));
    c = proc_cand;
    c.is_user = false;
    try std.testing.expect(!kb.isTarget(c));
}

test "kill(-1) is ESRCH only with no candidates" {
    try std.testing.expectEqual(kb.ESRCH, kb.result(0));
    try std.testing.expectEqual(@as(i64, 0), kb.result(3));
}
