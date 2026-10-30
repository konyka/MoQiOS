//! Open-file offsets that dup()/fork() descriptors share.
//!
//! POSIX makes dup(2) and fork(2) copy the descriptor but not the open file
//! description, so both ends read and write at one position. A descriptor
//! starts with a private offset (`slot == 0`); the first time it is
//! duplicated, the offset moves into this pool and both descriptors refer to
//! the slot. The count tracks how many descriptors point at it; the slot is
//! reusable once the last one is released.

pub fn Pool(comptime N: usize) type {
    return struct {
        const Self = @This();
        offsets: [N + 1]u64 = @splat(0),
        refs: [N + 1]u16 = @splat(0),

        /// Move `offset` into a fresh slot with one holder. Null when the pool is full.
        pub fn promote(self: *Self, offset: u64) ?u16 {
            var i: usize = 1;
            while (i <= N) : (i += 1) {
                if (self.refs[i] == 0) {
                    self.refs[i] = 1;
                    self.offsets[i] = offset;
                    return @intCast(i);
                }
            }
            return null;
        }

        pub fn retain(self: *Self, slot: u16) void {
            if (slot == 0 or slot > N or self.refs[slot] == 0) return;
            self.refs[slot] +|= 1;
        }

        /// Drop one holder; true when that was the last and the slot is free again.
        pub fn release(self: *Self, slot: u16) bool {
            if (slot == 0 or slot > N or self.refs[slot] == 0) return false;
            self.refs[slot] -= 1;
            return self.refs[slot] == 0;
        }

        pub fn load(self: *const Self, slot: u16) u64 {
            return self.offsets[slot];
        }

        pub fn store(self: *Self, slot: u16, v: u64) void {
            self.offsets[slot] = v;
        }
    };
}
