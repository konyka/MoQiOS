const std = @import("std");
const dcc = @import("kernel_shared").dir_cursor_cache;

const Cur = struct { tag: u32 = 0 };
const Cache = dcc.Cache(Cur, 8);

/// A reader as getdents drives it: per call, `fit` entries are returned, then
/// one more is fetched and does not fit (the probe), and the next call asks for
/// that same entry again. Every fetch is "take the cursor at my position, step
/// it, remember where it stands".
const Reader = struct {
    owner: u64,
    dir: u64,
    fit: u32,
    pos: u64 = 0,
    misses: u32 = 0,
    fetches: u32 = 0,

    fn fetch(self: *Reader, c: *Cache) void {
        self.fetches += 1;
        const hit = c.find(self.dir, self.owner, self.pos);
        if (hit == null) self.misses += 1;
        c.advance(self.dir, self.owner, if (hit != null) self.pos else null, self.pos + 1, .{ .tag = @intCast(self.pos + 1) });
    }

    fn call(self: *Reader, c: *Cache) void {
        var i: u32 = 0;
        while (i < self.fit) : (i += 1) {
            self.fetch(c);
            self.pos += 1;
        }
        self.fetch(c); // the probe: the position does not move
    }
};

fn run(c: *Cache, readers: []Reader, entries: u64) void {
    var more = true;
    while (more) {
        more = false;
        for (readers) |*r| {
            if (r.pos < entries) {
                r.call(c);
                more = true;
            }
        }
    }
}

fn totalMisses(readers: []const Reader) u32 {
    var m: u32 = 0;
    for (readers) |r| m += r.misses;
    return m;
}

test "one reader: the probe and the retake both hit" {
    var c: Cache = .{};
    var r = [_]Reader{.{ .owner = 1, .dir = 5, .fit = 3 }};
    run(&c, &r, 1900);
    try std.testing.expectEqual(@as(u32, 1), r[0].misses); // only the very first fetch
    try std.testing.expect(c.held(1) <= 2);
}

test "readers in lockstep at the same position never evict each other" {
    // Identical positions, identical buffer sizes: the case that thrashed when
    // slots were keyed by position alone.
    var c: Cache = .{};
    var r = [_]Reader{
        .{ .owner = 1, .dir = 5, .fit = 3 },
        .{ .owner = 2, .dir = 5, .fit = 3 },
    };
    run(&c, &r, 1900);
    try std.testing.expectEqual(@as(u32, 2), totalMisses(&r));
}

test "readers with different buffer sizes of one directory" {
    for ([_][2]u32{ .{ 3, 2 }, .{ 5, 4 }, .{ 1, 1 }, .{ 7, 1 } }) |fits| {
        var c: Cache = .{};
        var r = [_]Reader{
            .{ .owner = 1, .dir = 5, .fit = fits[0] },
            .{ .owner = 2, .dir = 5, .fit = fits[1] },
        };
        run(&c, &r, 1900);
        try std.testing.expectEqual(@as(u32, 2), totalMisses(&r));
    }
}

test "four readers fit in eight slots; each holds at most two" {
    var c: Cache = .{};
    var r = [_]Reader{
        .{ .owner = 1, .dir = 5, .fit = 3 },
        .{ .owner = 2, .dir = 5, .fit = 2 },
        .{ .owner = 3, .dir = 6, .fit = 4 },
        .{ .owner = 4, .dir = 6, .fit = 1 },
    };
    run(&c, &r, 600);
    try std.testing.expectEqual(@as(u32, 4), totalMisses(&r));
    for (r) |x| try std.testing.expect(c.held(x.owner) <= 2);
}

test "more readers than the cache holds still list correctly, only slower" {
    // Correctness never depends on a hit: a miss rebuilds the cursor. Past the
    // capacity round-robin access defeats LRU, so misses are expected here.
    var c: Cache = .{};
    var r = [_]Reader{
        .{ .owner = 1, .dir = 5, .fit = 3 }, .{ .owner = 2, .dir = 5, .fit = 3 },
        .{ .owner = 3, .dir = 5, .fit = 3 }, .{ .owner = 4, .dir = 5, .fit = 3 },
        .{ .owner = 5, .dir = 5, .fit = 3 }, .{ .owner = 6, .dir = 5, .fit = 3 },
    };
    run(&c, &r, 120);
    for (r) |x| try std.testing.expect(x.pos >= 120); // every reader reached the end
    try std.testing.expect(totalMisses(&r) > 6); // and the limit is real, so say so
}

test "an owner never sees another owner's or another directory's position" {
    var c: Cache = .{};
    c.put(5, 1, 40, .{ .tag = 40 });
    try std.testing.expect(c.find(5, 2, 40) == null); // other owner
    try std.testing.expect(c.find(6, 1, 40) == null); // other directory
    try std.testing.expect(c.find(5, 1, 41) == null); // other position
    try std.testing.expectEqual(@as(u32, 40), c.find(5, 1, 40).?.tag);
}

test "forget drops one owner's positions in one directory only" {
    var c: Cache = .{};
    c.put(5, 1, 10, .{});
    c.put(5, 1, 11, .{});
    c.put(5, 2, 10, .{});
    c.put(6, 1, 10, .{});
    c.forget(5, 1);
    try std.testing.expect(c.find(5, 1, 10) == null);
    try std.testing.expect(c.find(5, 1, 11) == null);
    try std.testing.expect(c.find(5, 2, 10) != null);
    try std.testing.expect(c.find(6, 1, 10) != null);
}

test "the least recently used slot is recycled when the cache is full" {
    var c: Cache = .{};
    var i: u64 = 0;
    while (i < 8) : (i += 1) c.put(1, i, 0, .{ .tag = @intCast(i) });
    _ = c.find(1, 0, 0); // touch owner 0: owner 1 is now the oldest
    c.put(1, 99, 0, .{});
    try std.testing.expect(c.find(1, 1, 0) == null);
    try std.testing.expect(c.find(1, 0, 0) != null);
    try std.testing.expect(c.find(1, 99, 0) != null);
}

test "the age comparison survives clock wraparound" {
    var c: Cache = .{};
    c.clock = 0xFFFF_FFFC;
    var i: u64 = 0;
    while (i < 9) : (i += 1) c.put(1, i, 0, .{}); // the clock wraps past zero in here
    try std.testing.expect(c.find(1, 0, 0) == null); // oldest was recycled
    try std.testing.expect(c.find(1, 8, 0) != null);
    try std.testing.expect(c.find(1, 1, 0) != null);
}
