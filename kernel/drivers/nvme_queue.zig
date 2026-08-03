//! NVMe I/O queue selection policy — pure decision logic, host-testable.
//!
//! The interrupt-driven submit path in nvme.zig calls `pickQueue` to decide
//! which I/O queue (and therefore which MSI-X vector / ISR CPU) a command
//! lands on. Keeping the policy pure lets tests/main.zig exercise it without
//! booting the kernel.

/// Pick the I/O queue for one submission.
///
/// - `cpu_id`: submitting CPU (callers pass 0 when the per-CPU block is not
///   installed yet — early boot — and for kernel threads such as the
///   writeback daemon, which are pinned to queue 0 to keep the per-CPU
///   spread of user-task submissions undisturbed).
/// - `num_queues`: number of live I/O queues (may be 0 pre-init).
/// - `busy_mask`: bit q set ⇔ queue q's command channel is owned
///   (`io_in_flight[q]`); bits at or above `num_queues` are ignored.
/// - `rr_hint`: current value of the round-robin counter; read-only input —
///   the caller advances the counter when the fallback path is taken.
///
/// Policy: prefer `cpu_id % num_queues` so a task's consecutive submissions
/// land on the same queue and its MSI-X interrupt fires on the submitting
/// CPU (no cross-CPU lock contention / IPI storms). When the preferred
/// queue's channel is busy, fall back to `rr_hint % num_queues` so
/// submitters spread over the remaining queues instead of parking behind
/// one queue while the others idle.
pub fn pickQueue(cpu_id: u32, num_queues: u32, busy_mask: u32, rr_hint: u32) u32 {
    if (num_queues <= 1) return 0;
    const preferred = cpu_id % num_queues;
    if (busy_mask & (@as(u32, 1) << @intCast(preferred)) == 0) return preferred;
    return rr_hint % num_queues;
}
