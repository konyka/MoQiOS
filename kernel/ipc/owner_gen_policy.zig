//! Owner-identity generation check for task-slot registrations.
//!
//! posix_timer and posix_mq record the raw task SLOT INDEX of the
//! registering task (owner_task_idx / notify_task_idx). After the owner
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
