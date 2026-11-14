//! The table behind flock() and fcntl() record locks, without any kernel state (host-tested).
//!
//! Two kinds of lock live in one table and never conflict with each other, as on Linux:
//!   - flock locks cover the whole file and belong to an open file description;
//!   - POSIX (fcntl) locks cover a byte range and belong to the descriptor table of a process.
//! `owner` is that identity, chosen by the caller. A POSIX owner has at most one lock on any byte: setting a range merges it with
//! the owner's adjacent or overlapping locks of the same type and cuts it out of the owner's locks of the other type; unlocking a
//! range cuts it out, splitting a lock that spans it. Ranges are inclusive; `end == max` reaches to the end of the file.

const std = @import("std");

/// Linux OFFSET_MAX: the largest loff_t. A lock ending here reaches to the end of the file (l_len 0).
pub const OFFSET_MAX: u64 = std.math.maxInt(i64);

pub const Kind = enum(u8) { flock, posix };

pub const Lock = struct {
    inode: u64,
    owner: u64,
    pid: u32,
    kind: Kind,
    write: bool,
    start: u64 = 0,
    end: u64 = OFFSET_MAX,
};

pub const Range = struct { start: u64, end: u64 };

pub const RangeError = error{ Invalid, Overflow };

/// struct flock's (l_start, l_len) against `base` (0, the file position or the file size for l_whence SEEK_SET/CUR/END), as
/// Linux flock64_to_posix_lock: Overflow (EOVERFLOW) past OFFSET_MAX, Invalid (EINVAL) for a range starting before byte 0. A zero
/// length reaches to the end of the file; a negative one covers the bytes before the start.
pub fn rangeOf(base: i64, start: i64, len: i64) RangeError!Range {
    const max: i64 = std.math.maxInt(i64);
    if (start > max - base) return error.Overflow;
    const s = base + start;
    if (s < 0) return error.Invalid;
    if (len > 0) {
        if (len - 1 > max - s) return error.Overflow;
        return .{ .start = @intCast(s), .end = @intCast(s + (len - 1)) };
    }
    if (len < 0) {
        if (s + len < 0) return error.Invalid;
        return .{ .start = @intCast(s + len), .end = @intCast(s - 1) };
    }
    return .{ .start = @intCast(s), .end = OFFSET_MAX };
}

/// l_len for a lock reported by F_GETLK (0 = to the end of the file).
pub fn lengthOf(l: *const Lock) i64 {
    if (l.end == OFFSET_MAX) return 0;
    const n = l.end - l.start + 1;
    return if (n > std.math.maxInt(i64)) 0 else @intCast(n);
}

/// One blocked F_SETLKW: lock owner `owner` waits for a lock held by `waits_for` (0 = slot unused).
pub const Wait = struct { owner: u64 = 0, waits_for: u64 = 0 };

/// Linux MAX_DEADLK_ITERATIONS: how many owners deep the cycle search follows before it gives up and lets the caller wait.
pub const MAX_DEADLK_ITERATIONS = 10;

/// Linux posix_locks_deadlock: would `caller` waiting for `blocker` close a cycle? Follows what each blocking owner is itself
/// waiting for; true when the chain comes back to `caller`.
pub fn wouldDeadlock(caller: u64, blocker: u64, waits: []const Wait) bool {
    var cur = blocker;
    var i: usize = 0;
    while (true) {
        if (cur == caller) return true;
        if (i > MAX_DEADLK_ITERATIONS) return false;
        i += 1;
        const next = for (waits) |w| {
            if (w.owner != 0 and w.owner == cur) break w.waits_for;
        } else return false;
        cur = next;
    }
}

pub fn Table(comptime N: usize) type {
    return struct {
        const Self = @This();
        locks: [N]Lock = undefined,
        count: usize = 0,

        fn removeAt(self: *Self, i: usize) void {
            self.locks[i] = self.locks[self.count - 1];
            self.count -= 1;
        }

        fn mine(l: *const Lock, inode: u64, kind: Kind, owner: u64) bool {
            return l.inode == inode and l.kind == kind and l.owner == owner;
        }

        /// The first lock of another owner that stops `owner` taking this lock, or null when it can be taken.
        pub fn conflict(self: *const Self, inode: u64, kind: Kind, owner: u64, write: bool, start: u64, end: u64) ?Lock {
            for (self.locks[0..self.count]) |l| {
                if (l.inode != inode or l.kind != kind or l.owner == owner) continue;
                if (!write and !l.write) continue;
                if (kind == .posix and (l.start > end or l.end < start)) continue;
                return l;
            }
            return null;
        }

        /// Take or convert `owner`'s flock on `inode`. False when the table is full.
        pub fn setFlock(self: *Self, inode: u64, owner: u64, pid: u32, write: bool) bool {
            for (self.locks[0..self.count]) |*l| {
                if (mine(l, inode, .flock, owner)) {
                    l.write = write;
                    return true;
                }
            }
            if (self.count == N) return false;
            self.locks[self.count] = .{ .inode = inode, .owner = owner, .pid = pid, .kind = .flock, .write = write };
            self.count += 1;
            return true;
        }

        /// Drop `owner`'s flock on `inode`; true when there was one.
        pub fn dropFlock(self: *Self, inode: u64, owner: u64) bool {
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                if (mine(&self.locks[i], inode, .flock, owner)) {
                    self.removeAt(i);
                    return true;
                }
            }
            return false;
        }

        /// Cut [start, end] out of `owner`'s POSIX locks on `inode`. Needs one free entry when a lock spans the range; false
        /// (and nothing changed) when that entry is missing. Sets `changed` when any lock lost bytes.
        pub fn unlockPosix(self: *Self, inode: u64, owner: u64, start: u64, end: u64, changed: *bool) bool {
            for (self.locks[0..self.count]) |l| {
                if (mine(&l, inode, .posix, owner) and l.start < start and l.end > end and self.count == N) return false;
            }
            var i: usize = 0;
            while (i < self.count) {
                const l = &self.locks[i];
                if (!mine(l, inode, .posix, owner) or l.start > end or l.end < start) {
                    i += 1;
                    continue;
                }
                changed.* = true;
                if (l.start < start and l.end > end) {
                    var tail = l.*;
                    tail.start = end + 1;
                    l.end = start - 1;
                    self.locks[self.count] = tail;
                    self.count += 1;
                    i += 1;
                } else if (l.start < start) {
                    l.end = start - 1;
                    i += 1;
                } else if (l.end > end) {
                    l.start = end + 1;
                    i += 1;
                } else {
                    self.removeAt(i);
                }
            }
            return true;
        }

        /// Make [start, end] of `inode` a `write` (else read) lock of `owner`. False (and nothing changed) when the table has no
        /// room for the worst case, a lock of the other type split in two around the new one.
        pub fn setPosix(self: *Self, inode: u64, owner: u64, pid: u32, write: bool, start: u64, end: u64) bool {
            if (self.count + 2 > N) return false;
            var s = start;
            var e = end;
            var i: usize = 0;
            while (i < self.count) {
                const l = &self.locks[i];
                if (mine(l, inode, .posix, owner) and l.write == write and l.start <= e +| 1 and l.end +| 1 >= s) {
                    s = @min(s, l.start);
                    e = @max(e, l.end);
                    self.removeAt(i);
                    continue;
                }
                i += 1;
            }
            var changed = false;
            _ = self.unlockPosix(inode, owner, s, e, &changed);
            self.locks[self.count] = .{ .inode = inode, .owner = owner, .pid = pid, .kind = .posix, .write = write, .start = s, .end = e };
            self.count += 1;
            return true;
        }

        /// Drop every lock of `kind` that `owner` holds on `inode` (every inode when `inode` is null); true when any went.
        pub fn dropOwner(self: *Self, inode: ?u64, kind: Kind, owner: u64) bool {
            var dropped = false;
            var i: usize = 0;
            while (i < self.count) {
                const l = &self.locks[i];
                if (l.kind == kind and l.owner == owner and (inode == null or l.inode == inode.?)) {
                    self.removeAt(i);
                    dropped = true;
                    continue;
                }
                i += 1;
            }
            return dropped;
        }
    };
}
