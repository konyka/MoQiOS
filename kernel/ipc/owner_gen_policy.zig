//! Owner-identity generation check for task-slot registrations.
//!
//! posix_timer records the raw task SLOT INDEX of the creating task
//! (owner_task_idx); posix_mq keys mq_notify on the owner's thread group id
//! instead and does not need this check. After the owner
//! exits and reapZombies recycles the slot, an unrelated new task occupies
//! it: getTask() proves occupancy, not identity. Recording the owner's tid
//! (monotonically increasing, never reused while the kernel runs) alongside
//! the slot index lets the signal path reject a recycled slot.

/// True when the recorded owner tid matches the tid of the task currently
/// occupying the slot — i.e. the registration still refers to the same task.
/// `current_tid` is null when the slot is empty (getTask returned null).
pub fn ownerMatches(recorded_tid: u32, current_tid: ?u32) bool {
    const cur = current_tid orelse return false; // slot empty
    return cur == recorded_tid;
}
