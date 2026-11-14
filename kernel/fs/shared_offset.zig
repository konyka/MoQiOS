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
        status: [N + 1]u32 = @splat(0),
        refs: [N + 1]u16 = @splat(0),
        /// F_SETOWN / F_SETSIG of the shared description: pid (> 0), -pgrp (< 0) or 0; the signal, 0 for SIGIO.
        owners: [N + 1]i32 = @splat(0),
        signals: [N + 1]u8 = @splat(0),

        /// Move `offset` into a fresh slot with one holder. Null when the pool is full.
        pub fn promote(self: *Self, offset: u64) ?u16 {
            var i: usize = 1;
            while (i <= N) : (i += 1) {
                if (self.refs[i] == 0) {
                    self.refs[i] = 1;
                    self.offsets[i] = offset;
                    self.status[i] = 0;
                    self.owners[i] = 0;
                    self.signals[i] = 0;
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

        /// File status flags (O_NONBLOCK, O_APPEND, ...) of the shared description.
        pub fn flags(self: *const Self, slot: u16) u32 {
            return self.status[slot];
        }

        pub fn setFlags(self: *Self, slot: u16, v: u32) void {
            self.status[slot] = v;
        }

        pub fn owner(self: *const Self, slot: u16) i32 {
            return self.owners[slot];
        }

        pub fn setOwner(self: *Self, slot: u16, v: i32) void {
            self.owners[slot] = v;
        }

        pub fn signal(self: *const Self, slot: u16) u8 {
            return self.signals[slot];
        }

        pub fn setSignal(self: *Self, slot: u16, v: u8) void {
            self.signals[slot] = v;
        }
    };
}
