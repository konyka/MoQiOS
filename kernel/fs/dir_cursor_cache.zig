//! A tiny cache of resumable directory positions, kept per mounted volume.
//!
//! getdents64 asks for "the entry at cookie P" once per entry, and also once
//! more at the end of a call to find out whether the next entry still fits the
//! caller's buffer. The following call then asks for P again. A position that
//! was advanced in place would miss on that second ask and force a rescan from
//! the first entry, turning a directory listing quadratic.
//!
//! Slots belong to an OWNER (one open directory descriptor). Two readers of the
//! same directory, even at the very same position, never touch each other's
//! slots; an earlier version keyed slots by (directory, position) alone and a
//! reader freeing "its" old position freed the other reader's. A reader keeps
//! at most two positions: the one it resumed from (it is asked for again after
//! the probe) and the one it moved to. Least recently used slots are recycled
//! when more readers are active than the cache can hold; correctness never
//! depends on a hit, only speed does (a miss rebuilds the cursor from the
//! first entry).
//!
//! Pure and generic over the cursor type, so it is host-tested.

pub fn Cache(comptime Cursor: type, comptime n_slots: usize) type {
    return struct {
        const Self = @This();

        pub const Slot = struct {
            valid: bool = false,
            dir: u64 = 0,
            owner: u64 = 0,
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

        /// Cursor of (`dir`, `owner`) positioned at entry `index`, if cached.
        pub fn find(self: *Self, dir: u64, owner: u64, index: u64) ?Cursor {
            for (&self.slots) |*s| {
                if (s.valid and s.dir == dir and s.owner == owner and s.index == index) {
                    s.stamp = self.tick();
                    return s.cursor;
                }
            }
            return null;
        }

        /// Remember that `cursor` now yields entry `index` of `dir` next for `owner`.
        pub fn put(self: *Self, dir: u64, owner: u64, index: u64, cursor: Cursor) void {
            var victim: ?*Slot = null;
            for (&self.slots) |*s| {
                if (s.valid and s.dir == dir and s.owner == owner and s.index == index) {
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
            victim.?.* = .{ .valid = true, .dir = dir, .owner = owner, .index = index, .stamp = self.tick(), .cursor = cursor };
        }

        /// The owner moved on. `from` is the position it resumed from (null after a
        /// miss) and stays cached once more, because getdents asks for it again after
        /// its probe. The position one step behind it is no longer needed and is
        /// released, so a reader never holds more than two slots.
        pub fn advance(self: *Self, dir: u64, owner: u64, from: ?u64, index: u64, cursor: Cursor) void {
            if (from) |f| {
                if (f > 0) {
                    for (&self.slots) |*s| {
                        if (s.valid and s.dir == dir and s.owner == owner and s.index + 1 == f) {
                            s.valid = false;
                            break;
                        }
                    }
                }
            }
            self.put(dir, owner, index, cursor);
        }

        /// Drop every position of one owner in `dir` (end of directory or an error).
        pub fn forget(self: *Self, dir: u64, owner: u64) void {
            for (&self.slots) |*s| {
                if (s.valid and s.dir == dir and s.owner == owner) s.valid = false;
            }
        }

        /// Number of slots currently held by `owner` (tests).
        pub fn held(self: *const Self, owner: u64) usize {
            var n: usize = 0;
            for (&self.slots) |*s| {
                if (s.valid and s.owner == owner) n += 1;
            }
            return n;
        }
    };
}
