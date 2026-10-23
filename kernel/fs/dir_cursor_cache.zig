//! A tiny cache of resumable directory positions, kept per mounted volume.
//!
//! getdents64 asks for "the entry at cookie P" once per entry, and also once
//! more at the end of a call to find out whether the next entry still fits the
//! caller's buffer. The following call then asks for P again. A position that
//! was advanced in place would miss on that second ask and force a rescan from
//! the first entry, turning a directory listing quadratic. So advancing never
//! overwrites the position it came from: the old one stays valid and the new
//! one goes into another slot (or refreshes an existing slot at the same
//! index). Least recently used slots are recycled.
//!
//! Pure and generic over the cursor type, so it is host-tested.

const std = @import("std");

pub fn Cache(comptime Cursor: type, comptime n_slots: usize) type {
    return struct {
        const Self = @This();

        pub const Slot = struct {
            valid: bool = false,
            dir: u64 = 0,
            /// The cursor yields entry number `index` next.
            index: u64 = 0,
            stamp: u32 = 0,
            cursor: Cursor = .{},
        };

        slots: [n_slots]Slot = @splat(.{}),
        clock: u32 = 0,

        fn tick(self: *Self) u32 {
            self.clock +%= 1;
            return self.clock;
        }

        /// Cursor of directory `dir` positioned at entry `index`, if cached.
        pub fn find(self: *Self, dir: u64, index: u64) ?Cursor {
            for (&self.slots) |*s| {
                if (s.valid and s.dir == dir and s.index == index) {
                    s.stamp = self.tick();
                    return s.cursor;
                }
            }
            return null;
        }

        /// Remember that `cursor` now yields entry `index` of `dir` next.
        pub fn put(self: *Self, dir: u64, index: u64, cursor: Cursor) void {
            var victim: ?*Slot = null;
            for (&self.slots) |*s| {
                if (s.valid and s.dir == dir and s.index == index) {
                    victim = s; // same position: just refresh it
                    break;
                }
            }
            if (victim == null) {
                for (&self.slots) |*s| {
                    if (!s.valid) {
                        victim = s;
                        break;
                    }
                }
            }
            if (victim == null) {
                var best: *Slot = &self.slots[0];
                for (&self.slots) |*s| {
                    // wrapping age: larger means older
                    if (self.clock -% s.stamp > self.clock -% best.stamp) best = s;
                }
                victim = best;
            }
            victim.?.* = .{ .valid = true, .dir = dir, .index = index, .stamp = self.tick(), .cursor = cursor };
        }

        /// Drop every position of `dir` (end of directory or an error).
        pub fn forget(self: *Self, dir: u64) void {
            for (&self.slots) |*s| {
                if (s.valid and s.dir == dir) s.valid = false;
            }
        }
    };
}
