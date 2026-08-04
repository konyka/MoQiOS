//! Atomic task-claim protocol (J2: fine-grained scheduler picking).
//!
//! A task may run on a CPU only after that CPU wins a cmpxchg on the task's
//! state word (.ready → .running). This replaces the old exclusion invariant
//! "holding sched_lock prevents another CPU from picking the same task" with
//! claim-based exclusion, so the pick path (per-CPU queue pop, work stealing,
//! bitmap fallback) runs without the global scheduler lock.
//!
//! State machine (every cross-CPU-visible transition goes through here):
//!
//!   .ready   -- tryClaim ---------> .running   exactly one CPU wins
//!   .running -- releaseToReady ---> .ready     owner CPU only; fails when the
//!                                              task blocked / exited while
//!                                              the switch was in flight
//!   .blocked -- store(.ready) ----> .ready     wake paths (task_lock held)
//!   .running -- store(.blocked) --> .blocked   the running task blocks itself
//!   .running -- store(.zombie) ---> .zombie    exitTask (the task itself)
//!
//! Safety argument: a task is claimable only while .ready. The transitions
//! OUT of .ready are exactly one — tryClaim — so two CPUs can never both own
//! a task. Transitions out of .running are made only by the CPU running the
//! task (block/exit) or by the owner CPU finishing a context switch
//! (releaseToReady), so a plain wake store can never race a successful claim:
//! wakers only fire on .blocked tasks, which are unclaimable by definition.
//!
//! Pure module: no arch imports — host-testable via kernel/host_test.zig.

/// Canonical task-state enum. `task.zig` re-exports this as `task.TaskState`
/// so the whole kernel shares one definition (values are ABI-stable).
pub const TaskState = enum(u8) {
    ready = 0,
    running = 1,
    blocked = 2,
    zombie = 3,
};

const READY: u8 = @intFromEnum(TaskState.ready);
const RUNNING: u8 = @intFromEnum(TaskState.running);

inline fn asByte(state: *TaskState) *u8 {
    return @ptrCast(state);
}

inline fn asByteConst(state: *const TaskState) *const u8 {
    return @ptrCast(state);
}

/// Try to claim a task for the calling CPU: .ready → .running.
/// Returns true iff this caller won the race. On success the caller owns the
/// task exclusively — no other CPU can claim it until the owner releases it
/// (or the task itself blocks/exits while running on the owner).
pub fn tryClaim(state: *TaskState) bool {
    return @cmpxchgStrong(u8, asByte(state), READY, RUNNING, .acq_rel, .monotonic) == null;
}

/// Release a claimed task back to .ready. Returns false when the task left
/// .running underneath the in-flight switch (it blocked or exited) — in that
/// case the caller must NOT re-enqueue it; the block/exit path owns the next
/// transition.
pub fn releaseToReady(state: *TaskState) bool {
    return @cmpxchgStrong(u8, asByte(state), RUNNING, READY, .acq_rel, .monotonic) == null;
}

/// Atomic load — advisory reads on the pick/fast paths (queue filters,
/// single-task fast path, FIFO/RT guards).
pub inline fn load(state: *const TaskState) TaskState {
    return @enumFromInt(@atomicLoad(u8, asByteConst(state), .acquire));
}

/// Atomic store for the non-contended lifecycle transitions (wake / block /
/// exit). These never race with a *successful* claim (see the safety argument
/// above), but they must still be atomic so no plain store ever tears against
/// a concurrent cmpxchg on the same byte.
pub inline fn store(state: *TaskState, s: TaskState) void {
    @atomicStore(u8, asByte(state), @intFromEnum(s), .release);
}
