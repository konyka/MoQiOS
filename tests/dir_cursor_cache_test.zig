const std = @import("std");
const dcc = @import("kernel_shared").dir_cursor_cache;

const Cur = struct { tag: u32 = 0 };
const Cache = dcc.Cache(Cur, 4);

test "an advanced position never replaces the one it came from" {
    // The getdents pattern: serve entry P, probe P+1 (does it fit?), then the
    // next call asks for P+1 again. Both asks must hit.
    var c: Cache = .{};
    c.put(7, 10, .{ .tag = 10 });
    const at10 = c.find(7, 10).?;
    try std.testing.expectEqual(@as(u32, 10), at10.tag);
    c.put(7, 11, .{ .tag = 11 }); // advanced from 10: 10 must stay available
    try std.testing.expectEqual(@as(u32, 10), c.find(7, 10).?.tag);
    try std.testing.expectEqual(@as(u32, 11), c.find(7, 11).?.tag);
    // asking for 11 again (the probe, then the real call) keeps hitting
    try std.testing.expect(c.find(7, 11) != null);
    try std.testing.expect(c.find(7, 11) != null);
}

test "a sequential listing with probes never misses after the first entry" {
    var c: Cache = .{};
    var misses: usize = 0;
    var cur: Cur = .{};
    var idx: u64 = 0;
    while (idx < 5000) {
        // serve entry idx
        if (idx == 0) {
            cur = .{};
        } else if (c.find(1, idx)) |hit| {
            cur = hit;
        } else {
            misses += 1;
            cur = .{ .tag = @intCast(idx) };
        }
        cur.tag = @intCast(idx + 1);
        c.put(1, idx + 1, cur);
        // probe idx+1 (did not fit), then the next call asks for it again
        try std.testing.expect(c.find(1, idx + 1) != null);
        idx += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), misses);
}

test "two readers of one directory and a reader of another do not evict each other" {
    var c: Cache = .{};
    c.put(1, 100, .{ .tag = 1 });
    c.put(1, 500, .{ .tag = 2 });
    c.put(2, 100, .{ .tag = 3 });
    try std.testing.expectEqual(@as(u32, 1), c.find(1, 100).?.tag);
    try std.testing.expectEqual(@as(u32, 2), c.find(1, 500).?.tag);
    try std.testing.expectEqual(@as(u32, 3), c.find(2, 100).?.tag);
    try std.testing.expect(c.find(2, 500) == null);
    try std.testing.expect(c.find(3, 100) == null);
}

test "putting the same position twice refreshes it instead of using a second slot" {
    var c: Cache = .{};
    for (0..20) |i| c.put(9, 42, .{ .tag = @intCast(i) });
    try std.testing.expectEqual(@as(u32, 19), c.find(9, 42).?.tag);
    // three other positions still fit alongside it
    c.put(9, 1, .{});
    c.put(9, 2, .{});
    c.put(9, 3, .{});
    try std.testing.expect(c.find(9, 42) != null);
}

test "the least recently used slot is recycled when the cache is full" {
    var c: Cache = .{};
    c.put(1, 1, .{ .tag = 1 });
    c.put(1, 2, .{ .tag = 2 });
    c.put(1, 3, .{ .tag = 3 });
    c.put(1, 4, .{ .tag = 4 });
    _ = c.find(1, 1); // touch 1: now 2 is the oldest
    c.put(1, 5, .{ .tag = 5 });
    try std.testing.expect(c.find(1, 2) == null);
    try std.testing.expect(c.find(1, 1) != null);
    try std.testing.expect(c.find(1, 5) != null);
}

test "the age comparison survives clock wraparound" {
    var c: Cache = .{};
    c.clock = 0xFFFF_FFFE;
    c.put(1, 1, .{ .tag = 1 });
    c.put(1, 2, .{ .tag = 2 });
    c.put(1, 3, .{ .tag = 3 }); // clock wraps past zero here
    c.put(1, 4, .{ .tag = 4 });
    c.put(1, 5, .{ .tag = 5 }); // evicts the oldest: position 1
    try std.testing.expect(c.find(1, 1) == null);
    try std.testing.expect(c.find(1, 2) != null);
    try std.testing.expect(c.find(1, 5) != null);
}

test "forget drops only the named directory" {
    var c: Cache = .{};
    c.put(1, 5, .{});
    c.put(1, 6, .{});
    c.put(2, 5, .{});
    c.forget(1);
    try std.testing.expect(c.find(1, 5) == null);
    try std.testing.expect(c.find(1, 6) == null);
    try std.testing.expect(c.find(2, 5) != null);
}
