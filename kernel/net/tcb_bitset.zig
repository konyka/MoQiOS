//! A fixed-size bitset of TCB (or listen-slot) indices backed by u64 words, so the table can hold more than 64 entries. Every word is read
//! and changed with 64-bit atomics (x86_64 has no 128-bit atomic RMW in this build), and `snapshot` takes an atomic copy word by word; a
//! snapshot is not one atomic picture of the whole set, which every caller already tolerates (each bit is re-checked under tcp_lock or is a
//! hint). Host-testable.

pub fn Bitset(comptime n: u32) type {
    return struct {
        const Self = @This();
        pub const WORDS: u32 = (n + 63) / 64;
        pub const CAPACITY: u32 = n;

        words: [WORDS]u64 = @splat(0),

        pub fn set(self: *Self, i: u32) void {
            _ = @atomicRmw(u64, &self.words[i >> 6], .Or, @as(u64, 1) << @intCast(i & 63), .release);
        }

        pub fn clear(self: *Self, i: u32) void {
            _ = @atomicRmw(u64, &self.words[i >> 6], .And, ~(@as(u64, 1) << @intCast(i & 63)), .release);
        }

        pub fn isSet(self: *const Self, i: u32) bool {
            return (@atomicLoad(u64, &self.words[i >> 6], .acquire) >> @intCast(i & 63)) & 1 != 0;
        }

        pub fn reset(self: *Self) void {
            for (&self.words) |*w| @atomicStore(u64, w, 0, .release);
        }

        pub fn snapshot(self: *const Self) Self {
            var out: Self = .{};
            for (&out.words, 0..) |*w, k| w.* = @atomicLoad(u64, &self.words[k], .acquire);
            return out;
        }

        pub fn isEmpty(self: *const Self) bool {
            for (self.words) |w| if (w != 0) return false;
            return true;
        }

        pub fn count(self: *const Self) u32 {
            var c: u32 = 0;
            for (self.words) |w| c += @popCount(w);
            return c;
        }

        /// Lowest clear index below n, or null when every slot is set.
        pub fn firstClear(self: *const Self) ?u32 {
            for (self.words, 0..) |w, k| {
                const free = ~w;
                if (free == 0) continue;
                const i: u32 = @intCast(k * 64 + @ctz(free));
                if (i < n) return i;
            }
            return null;
        }

        /// Pop the lowest set index from this (snapshot) copy; null when it is empty.
        pub fn next(self: *Self) ?u32 {
            for (&self.words, 0..) |*w, k| {
                if (w.* == 0) continue;
                const b = @ctz(w.*);
                w.* &= w.* - 1;
                return @intCast(k * 64 + b);
            }
            return null;
        }

        /// Take the whole set, leaving it empty (non-atomic: the owner holds a lock).
        pub fn takeAll(self: *Self) Self {
            const out = self.*;
            self.words = @splat(0);
            return out;
        }
    };
}
