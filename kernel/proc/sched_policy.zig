//! Pure scheduling-class policy logic (F3: SCHED_FIFO / SCHED_RR realtime
//! classes). No arch imports — host-testable via kernel/host_test.zig.
//!
//! Model (Linux-compatible numbering):
//!   SCHED_OTHER = 0  — normal timesharing tasks (nice band, default).
//!   SCHED_FIFO  = 1  — realtime, runs until it blocks or yields (no quantum).
//!   SCHED_RR    = 2  — realtime, per-task quantum, rotates among equal-prio
//!                      RR peers.
//!
//! Priority representation inside the kernel (Task.priority, u8, lower =
//! higher scheduling priority) follows the band convention established by
//! sched_setattr (v37.0):
//!   RT tasks:    sched_priority 1..99  → kernel priority 98..0  (band 0..98)
//!   OTHER tasks: nice -20..19          → kernel priority 0..39  (nice band)
//!   idle:        kernel priority 255
//! The OTHER nice band numerically overlaps the RT band, so selection never
//! compares raw priorities across classes — it compares `rankKey`s, which
//! place the whole RT band below (= ahead of) every OTHER task.

/// Linux policy numbers (kept identical for ABI compatibility).
pub const SCHED_OTHER: u8 = 0;
pub const SCHED_FIFO: u8 = 1;
pub const SCHED_RR: u8 = 2;

/// Linux realtime priority range for FIFO/RR.
pub const RT_PRIO_MIN: u8 = 1;
pub const RT_PRIO_MAX: u8 = 99;

/// SCHED_RR quantum in timer ticks (10 ticks × ~10 ms = ~100 ms).
/// Numerically equal to the OTHER timeslice — the distinction is that RR
/// rotates among equal-priority peers at expiry while OTHER round-robins.
pub const RR_QUANTUM_TICKS: u64 = 10;

/// Rank key offset for OTHER-class tasks. All RT keys (0..98) sit below this;
/// all OTHER keys (base + kernel priority) sit at or above it.
pub const OTHER_KEY_BASE: u16 = 100;

/// Highest rank key a bitmap-pick candidate may have. Kept at
/// OTHER_KEY_BASE + 255 so an idle-priority (255) OTHER task is never picked
/// by the bitmap fallback — identical to the pre-F3 `best_prio = 255` init.
pub const MAX_PICK_KEY: u16 = OTHER_KEY_BASE + 255;

/// True for the realtime classes (FIFO/RR).
pub fn isRtClass(policy: u8) bool {
    return policy == SCHED_FIFO or policy == SCHED_RR;
}

/// True for the classes MoQiOS implements (OTHER/FIFO/RR).
pub fn isValidClass(policy: u8) bool {
    return policy == SCHED_OTHER or isRtClass(policy);
}

/// Validate a sched_priority value for a policy (sched_setscheduler rules):
/// OTHER requires 0; FIFO/RR require 1..99.
pub fn validatePriority(policy: u8, rt_prio: i64) bool {
    if (isRtClass(policy)) return rt_prio >= RT_PRIO_MIN and rt_prio <= RT_PRIO_MAX;
    if (policy == SCHED_OTHER) return rt_prio == 0;
    return false;
}

/// Clamp an arbitrary integer into the RT priority range 1..99.
pub fn clampRtPriority(rt_prio: i64) u8 {
    if (rt_prio < RT_PRIO_MIN) return RT_PRIO_MIN;
    if (rt_prio > RT_PRIO_MAX) return RT_PRIO_MAX;
    return @intCast(rt_prio);
}

/// Map a Linux RT priority (1..99, higher = better) to the kernel priority
/// band (0..98, lower = better).
pub fn rtToKernelPriority(rt_prio: u8) u8 {
    return RT_PRIO_MAX -| rt_prio; // 99→0 … 1→98 (clamped below 0 never happens)
}

/// Inverse of rtToKernelPriority for the RT band (kernel 0..98 → RT 99..1).
pub fn kernelToRtPriority(kernel_prio: u8) u8 {
    return RT_PRIO_MAX -| kernel_prio;
}

/// Selection rank key (lower = scheduled first). RT tasks rank strictly
/// ahead of every OTHER task; within a class the kernel priority order
/// (lower number = better) is preserved, so OTHER-vs-OTHER ordering is
/// byte-identical to the pre-F3 raw-priority comparison.
pub fn rankKey(policy: u8, kernel_priority: u8) u16 {
    if (isRtClass(policy)) return kernel_priority;
    return OTHER_KEY_BASE + kernel_priority;
}

/// True when task A outranks task B (would be picked first).
pub fn beats(a_policy: u8, a_kernel_prio: u8, b_policy: u8, b_kernel_prio: u8) bool {
    return rankKey(a_policy, a_kernel_prio) < rankKey(b_policy, b_kernel_prio);
}

/// False for SCHED_FIFO: a running FIFO task never loses the CPU to a timer
/// tick — only to blocking or an explicit yield.
pub fn hasQuantumExpiry(policy: u8) bool {
    return policy != SCHED_FIFO;
}
