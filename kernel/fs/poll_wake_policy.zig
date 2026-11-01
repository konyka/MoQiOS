//! Wake-up protocol of poll()/select() as pure rules.
//!
//! Every readiness change in the kernel already calls `epollNotify`. poll and
//! select piggyback on it: a global generation counter is bumped on each
//! notification and the tasks that are waiting (a bitmap, one bit per task
//! slot) are woken. A waiter snapshots the generation BEFORE it scans the
//! descriptors; after it has published itself and gone to sleep it re-reads
//! the generation, so a notification that raced the scan is never lost. The
//! short sleep slice stays as the fallback for sources that do not notify.

/// Whether a waiter that snapshotted `seen` must skip sleeping because a
/// notification already happened since.
pub fn mustSkipSleep(seen: u32, current: u32) bool {
    return seen != current;
}

/// The next generation (wraps; only inequality matters).
pub fn nextGeneration(g: u32) u32 {
    return g +% 1;
}

/// Bit for a task slot in the waiter bitmap.
pub fn waiterBit(task_idx: u32) u64 {
    return @as(u64, 1) << @intCast(task_idx & 63);
}

/// The waiters to wake for a notification, and the bitmap that remains after
/// they have been taken (each waiter is woken once, then re-arms itself).
pub const Take = struct { wake: u64, remaining: u64 };

pub fn takeAll(bm: u64) Take {
    return .{ .wake = bm, .remaining = 0 };
}
