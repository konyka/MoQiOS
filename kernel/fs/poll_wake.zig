//! poll()/select() wake-up: see poll_wake_policy.zig for the protocol.

const std = @import("std");
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const pw = @import("poll_wake_policy.zig");

var generation_counter: u32 = 0;
var waiter_bm: u64 = 0;

/// Snapshot to take before scanning descriptors.
pub fn generation() u32 {
    return @atomicLoad(u32, &generation_counter, .seq_cst);
}

/// A readiness change happened somewhere: wake every poll/select waiter.
/// Cheap when nobody waits (one atomic add and one load).
pub fn notify() void {
    _ = @atomicRmw(u32, &generation_counter, .Add, 1, .seq_cst);
    if (@atomicLoad(u64, &waiter_bm, .seq_cst) == 0) return;
    const taken = @atomicRmw(u64, &waiter_bm, .Xchg, 0, .seq_cst);
    var bits = pw.takeAll(taken).wake;
    while (bits != 0) {
        const i: u32 = @intCast(@ctz(bits));
        bits &= bits - 1;
        task_mod.unblockTask(i);
    }
}

/// Sleep until `deadline_ns`, a notification (since the `seen` snapshot) or a
/// signal. 0 = rescan, -EINTR on an actionable signal.
pub fn waitUntil(seen: u32, deadline_ns: u64) i64 {
    const tsc = @import("../arch/x86_64/tsc.zig");
    const sig_mod = @import("../proc/signal.zig");

    const cur_idx = sched.currentTaskIndex() orelse return -14;
    const cur = task_mod.getTask(cur_idx) orelse return -14;
    const bit = pw.waiterBit(cur_idx);

    if (sig_mod.pendingFatal(cur)) |s| task_mod.exitTask(128 + @as(i32, @intCast(s)));
    if (sig_mod.pendingActionable(cur)) return -4;
    if (tsc.nanos() >= deadline_ns) return 0;

    // Publish before blocking: a notification after this point finds the bit
    // and wakes us; one before it moved the generation.
    _ = @atomicRmw(u64, &waiter_bm, .Or, bit, .seq_cst);
    @atomicStore(u64, &cur.sleep_deadline_ns, deadline_ns, .release);
    _ = @atomicRmw(u64, &sched.sleep_bm, .Or, bit, .seq_cst);
    task_mod.blockTask(cur_idx);

    if (!pw.mustSkipSleep(seen, generation())) {
        sched.forceReschedule();
    }
    // The yield may not have switched (nothing else to run here): repair the
    // state exactly like every other blocking wait.
    sched.repairCurrentAfterBlock();

    cur.sleep_deadline_ns = 0;
    _ = @atomicRmw(u64, &sched.sleep_bm, .And, ~bit, .seq_cst);
    _ = @atomicRmw(u64, &waiter_bm, .And, ~bit, .seq_cst);

    if (sig_mod.pendingFatal(cur)) |s| task_mod.exitTask(128 + @as(i32, @intCast(s)));
    if (sig_mod.pendingActionable(cur)) return -4;
    return 0;
}
