//! A fixed-size set of slot numbers with the "lowest free slot" and "iterate the used ones" operations the tmpfs table needs, for more
//! slots than one machine word holds. `bits` words of 64; slot 0 is reserved by the caller (the root directory) and never handed out.

pub fn SlotBitmap(comptime words: usize) type {
    return struct {
        const Self = @This();
        pub const capacity: usize = words * 64;
        w: [words]u64 = @splat(0),

        pub fn set(self: *Self, idx: usize) void {
            self.w[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
        }
        pub fn clear(self: *Self, idx: usize) void {
            self.w[idx / 64] &= ~(@as(u64, 1) << @intCast(idx % 64));
        }
        pub fn isSet(self: *const Self, idx: usize) bool {
            return (self.w[idx / 64] >> @intCast(idx % 64)) & 1 != 0;
        }
        /// The lowest slot above `reserved_below` that is not in use, or null when every slot is taken.
        pub fn lowestFree(self: *const Self, reserved_below: usize) ?usize {
            var wi: usize = reserved_below / 64;
            while (wi < words) : (wi += 1) {
                var free = ~self.w[wi];
                if (wi == reserved_below / 64) free &= ~((@as(u64, 1) << @intCast(reserved_below % 64)) -% 1);
                if (free != 0) return wi * 64 + @ctz(free);
            }
            return null;
        }
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.w) |x| n += @popCount(x);
            return n;
        }
        /// Iterate the slots in use, lowest first.
        pub const Iterator = struct {
            bm: *const Self,
            wi: usize = 0,
            cur: u64 = 0,
            started: bool = false,
            pub fn next(it: *Iterator) ?usize {
                if (!it.started) {
                    it.started = true;
                    it.cur = if (words > 0) it.bm.w[0] else 0;
                }
                while (true) {
                    if (it.cur != 0) {
                        const bit = @ctz(it.cur);
                        it.cur &= it.cur - 1;
                        return it.wi * 64 + bit;
                    }
                    it.wi += 1;
                    if (it.wi >= words) return null;
                    it.cur = it.bm.w[it.wi];
                }
            }
        };
        pub fn iterator(self: *const Self) Iterator {
            return .{ .bm = self };
        }
    };
}

test "slot bitmap: lowest free skips the reserved root, crosses word boundaries, and reports full" {
    const std = @import("std");
    var b: SlotBitmap(4) = .{};
    try std.testing.expectEqual(@as(usize, 256), SlotBitmap(4).capacity);
    b.set(0); // the root
    try std.testing.expectEqual(@as(?usize, 1), b.lowestFree(1));
    var i: usize = 1;
    while (i < 64) : (i += 1) b.set(i);
    try std.testing.expectEqual(@as(?usize, 64), b.lowestFree(1)); // the first word is full
    b.set(64);
    b.set(65);
    try std.testing.expectEqual(@as(?usize, 66), b.lowestFree(1));
    b.clear(10); // a hole in the first word is found again
    try std.testing.expectEqual(@as(?usize, 10), b.lowestFree(1));
    b.set(10);
    i = 66;
    while (i < 256) : (i += 1) b.set(i);
    try std.testing.expectEqual(@as(?usize, null), b.lowestFree(1)); // every slot is taken
    try std.testing.expectEqual(@as(usize, 256), b.count());
    b.clear(255);
    try std.testing.expectEqual(@as(?usize, 255), b.lowestFree(1));
    try std.testing.expect(!b.isSet(255) and b.isSet(254));
}

test "slot bitmap: an empty table hands out slot 1 and never slot 0 even when slot 0 is clear" {
    const std = @import("std");
    var b: SlotBitmap(4) = .{};
    try std.testing.expectEqual(@as(?usize, 1), b.lowestFree(1));
    // a reserved prefix bigger than one word starts in the middle of the table
    try std.testing.expectEqual(@as(?usize, 70), b.lowestFree(70));
}

test "slot bitmap: the iterator visits exactly the used slots in increasing order, across all words" {
    const std = @import("std");
    var b: SlotBitmap(4) = .{};
    const used = [_]usize{ 0, 1, 5, 63, 64, 100, 127, 128, 200, 255 };
    for (used) |u| b.set(u);
    var it = b.iterator();
    var k: usize = 0;
    while (it.next()) |s| : (k += 1) {
        try std.testing.expect(k < used.len);
        try std.testing.expectEqual(used[k], s);
    }
    try std.testing.expectEqual(used.len, k);
    var empty: SlotBitmap(4) = .{};
    var it2 = empty.iterator();
    try std.testing.expectEqual(@as(?usize, null), it2.next());
}
