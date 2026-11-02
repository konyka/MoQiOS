//! Pure policy for mlock/munlock: a bounded per-address-space table of locked page ranges and Linux's limit
//! rules. No kernel state, so the host tests can exercise all of it.
//!
//! What "locked" means here: the pages are excluded from swap reclaim (swap.zig skips them) and MADV_DONTNEED /
//! MADV_FREE refuse them (EINVAL, as Linux does for VM_LOCKED). The table is per Mm: a fork child starts empty,
//! like Linux, and CLONE_VM threads share it. mlockall(MCL_CURRENT) records every page the address space holds
//! right now; MCL_FUTURE sets Mm.lock_future, after which mmap, brk and mremap growth lock what they create.

/// Most separate locked ranges one address space can hold. A call that would need more fails with ENOMEM and
/// leaves the table unchanged. (Mm must stay within the 1024-byte slab class: tests/main.zig checks it.)
pub const MAX_RANGES: usize = 24;

pub const Range = struct { start: u64 = 0, pages: u64 = 0 };

pub const Table = struct {
    ranges: [MAX_RANGES]Range = [_]Range{.{}} ** MAX_RANGES,
    count: usize = 0,

    fn end(r: Range) u64 {
        return r.start +| r.pages;
    }

    pub fn clear(self: *Table) void {
        self.* = .{};
    }

    /// Total locked pages.
    pub fn total(self: *const Table) u64 {
        var n: u64 = 0;
        for (self.ranges[0..self.count]) |r| n += r.pages;
        return n;
    }

    /// How many pages of [start, start+pages) are already locked.
    pub fn overlapPages(self: *const Table, start: u64, pages: u64) u64 {
        if (pages == 0) return 0;
        const e = start +| pages;
        var n: u64 = 0;
        for (self.ranges[0..self.count]) |r| {
            const lo = @max(start, r.start);
            const hi = @min(e, end(r));
            if (hi > lo) n += hi - lo;
        }
        return n;
    }

    pub fn contains(self: *const Table, page: u64) bool {
        return self.overlapPages(page, 1) == 1;
    }

    /// Whether every page of [start, start+pages) is locked.
    pub fn covers(self: *const Table, start: u64, pages: u64) bool {
        return self.overlapPages(start, pages) == pages;
    }

    /// Whether any page of [start, start+pages) is locked.
    pub fn touches(self: *const Table, start: u64, pages: u64) bool {
        return self.overlapPages(start, pages) != 0;
    }

    /// Lock [start, start+pages), merging with every range it overlaps or touches. False when it would need a
    /// slot the table does not have; the table is then unchanged.
    pub fn lock(self: *Table, start: u64, pages: u64) bool {
        if (pages == 0) return true;
        var lo = start;
        var hi = start +| pages;
        var merged: usize = 0;
        var keep: [MAX_RANGES]Range = undefined;
        var kept: usize = 0;
        for (self.ranges[0..self.count]) |r| {
            if (r.start <= hi and lo <= end(r)) {
                lo = @min(lo, r.start);
                hi = @max(hi, end(r));
                merged += 1;
            } else {
                keep[kept] = r;
                kept += 1;
            }
        }
        if (kept == MAX_RANGES) return false;
        keep[kept] = .{ .start = lo, .pages = hi - lo };
        kept += 1;
        self.ranges = [_]Range{.{}} ** MAX_RANGES;
        @memcpy(self.ranges[0..kept], keep[0..kept]);
        self.count = kept;
        return true;
    }

    /// Whether lock(start, pages) would succeed: it needs a free slot only when it touches no existing range.
    pub fn canLock(self: *const Table, start: u64, pages: u64) bool {
        if (pages == 0 or self.count < MAX_RANGES) return true;
        const hi = start +| pages;
        for (self.ranges[0..self.count]) |r| {
            if (r.start <= hi and start <= end(r)) return true;
        }
        return false;
    }

    /// Whether releasing [start, start+pages) fits: only a hole strictly inside one range adds a range.
    pub fn canRelease(self: *const Table, start: u64, pages: u64) bool {
        if (pages == 0) return true;
        const e = start +| pages;
        for (self.ranges[0..self.count]) |r| {
            if (start > r.start and e < end(r)) return self.count < MAX_RANGES;
        }
        return true;
    }

    /// Drop [start, start+pages) from the table unconditionally. Used where the pages are already gone (munmap,
    /// MAP_FIXED replacement, an mremap shrink) and the call must not fail: if a split has no free slot the
    /// right-hand piece is forgotten, which leaves those pages unlocked. That is the safe direction (the quota
    /// is released, nothing is pinned that should not be).
    pub fn releaseLossy(self: *Table, start: u64, pages: u64) void {
        if (self.release(start, pages)) return;
        const e = start +| pages;
        for (self.ranges[0..self.count]) |*r| {
            if (start > r.start and e < end(r.*)) {
                r.pages = start - r.start;
                return;
            }
        }
    }

    /// The table after relocating the locked pages of [old_start, +old_pages) to [new_start, +new_pages) (an
    /// mremap move). Pages that no longer fit in the new, shorter range are dropped. Returns null when the
    /// relocated pieces need slots the table does not have; `self` is never modified, the caller commits the
    /// returned copy only once the move itself succeeded.
    pub fn moved(self: *const Table, old_start: u64, old_pages: u64, new_start: u64, new_pages: u64) ?Table {
        var next = self.*;
        var pieces: [MAX_RANGES]Range = undefined;
        var n: usize = 0;
        for (self.ranges[0..self.count]) |r| {
            const lo = @max(r.start, old_start);
            const hi = @min(end(r), old_start +| old_pages);
            if (hi <= lo) continue;
            const off = lo - old_start;
            if (off >= new_pages) continue;
            pieces[n] = .{ .start = new_start + off, .pages = @min(hi - lo, new_pages - off) };
            n += 1;
        }
        next.releaseLossy(old_start, old_pages);
        for (pieces[0..n]) |p| {
            if (!next.lock(p.start, p.pages)) return null;
        }
        return next;
    }

    /// Unlock [start, start+pages), truncating or splitting ranges. False (table unchanged) when a split would
    /// need a slot that does not exist.
    pub fn release(self: *Table, start: u64, pages: u64) bool {
        if (pages == 0) return true;
        if (!self.canRelease(start, pages)) return false;
        const e = start +| pages;
        var out: [MAX_RANGES]Range = undefined;
        var n: usize = 0;
        for (self.ranges[0..self.count]) |r| {
            const r_end = end(r);
            if (e <= r.start or start >= r_end) {
                out[n] = r;
                n += 1;
                continue;
            }
            if (start > r.start) {
                out[n] = .{ .start = r.start, .pages = start - r.start };
                n += 1;
            }
            if (e < r_end) {
                out[n] = .{ .start = e, .pages = r_end - e };
                n += 1;
            }
        }
        self.ranges = [_]Range{.{}} ** MAX_RANGES;
        @memcpy(self.ranges[0..n], out[0..n]);
        self.count = n;
        return true;
    }
};

/// mlock2's only flag: lock when the page is first touched instead of now. Anonymous memory here is populated
/// eagerly, so the pages are already resident and the flag changes nothing observable besides being accepted.
pub const MLOCK_ONFAULT: u32 = 1;

/// mlock2 accepts MLOCK_ONFAULT or nothing; any other bit is EINVAL, checked before anything else.
pub fn mlock2FlagsValid(flags: u32) bool {
    return flags & ~MLOCK_ONFAULT == 0;
}

/// Linux can_do_mlock(): the call is allowed at all when the task holds CAP_IPC_LOCK or RLIMIT_MEMLOCK is not zero.
/// Otherwise it fails with EPERM before anything else is looked at (even for a zero length).
pub fn mayAttempt(limit_bytes: u64, cap_ipc_lock: bool) bool {
    return cap_ipc_lock or limit_bytes != 0;
}

/// Whether locking `request` pages, `already_in_request` of which are locked already, keeps the address space
/// within RLIMIT_MEMLOCK. `locked` is the current total. CAP_IPC_LOCK is not limited.
pub fn fitsLimit(limit_bytes: u64, cap_ipc_lock: bool, locked: u64, request: u64, already_in_request: u64) bool {
    if (cap_ipc_lock) return true;
    const limit_pages = limit_bytes / 4096;
    const added = request -| already_in_request;
    const next = @addWithOverflow(locked, added);
    if (next[1] != 0) return false;
    return next[0] <= limit_pages;
}

/// What a mapping that is to be locked (MAP_LOCKED, or any mapping while mlockall(MCL_FUTURE) is in force) is
/// told before it is made.
pub const Gate = enum { ok, eperm, eagain };

/// Linux do_mmap(): MAP_LOCKED needs can_do_mlock() (EPERM) before anything is charged; then mlock_future_ok():
/// the locked total plus the new pages must fit RLIMIT_MEMLOCK (EAGAIN, not ENOMEM), unless the caller holds
/// CAP_IPC_LOCK. MCL_FUTURE alone never reports EPERM. A mapping that is not locked is never looked at.
pub fn mapGate(map_locked: bool, future: bool, limit_bytes: u64, cap_ipc_lock: bool, locked: u64, new_pages: u64) Gate {
    if (!map_locked and !future) return .ok;
    if (map_locked and !mayAttempt(limit_bytes, cap_ipc_lock)) return .eperm;
    if (!fitsLimit(limit_bytes, cap_ipc_lock, locked, new_pages, 0)) return .eagain;
    return .ok;
}

/// Linux mremap(): growing a mapping whose pages are locked must keep the locked total within RLIMIT_MEMLOCK,
/// else EAGAIN (mlock_future_ok with the VMA's own VM_LOCKED). A mapping that is not locked grows freely.
pub fn growGate(tail_locked: bool, limit_bytes: u64, cap_ipc_lock: bool, locked: u64, add_pages: u64) Gate {
    return mapGate(false, tail_locked, limit_bytes, cap_ipc_lock, locked, add_pages);
}

/// Linux mlockall(MCL_CURRENT): ENOMEM unless everything the address space holds fits RLIMIT_MEMLOCK (Linux compares
/// total_vm; here it is the number of pages that would be locked). CAP_IPC_LOCK is not limited.
pub fn currentFits(limit_bytes: u64, cap_ipc_lock: bool, total_pages: u64) bool {
    if (cap_ipc_lock) return true;
    return total_pages <= limit_bytes / 4096;
}
