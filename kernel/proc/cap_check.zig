/// Centralized POSIX capability checks (Task #8).
///
/// Thin facade over the per-task `effective_caps` / `permitted_caps` /
/// `inheritable_caps` bitmasks declared on `Task`. Syscall handlers call
/// `capable()` (returns bool) or `requireCap()` (returns -EPERM when missing)
/// before performing privileged operations.
///
/// The capability system is **architecture-agnostic** — this module is
/// imported from x86_64 syscall paths today; it has no x86-specific code so
/// future architectures (e.g. riscv64) reuse it as-is.
const task_mod = @import("task.zig");
const capability = @import("../ipc/capability.zig");

/// EPERM — POSIX "operation not permitted".
pub const EPERM: i64 = -1;

/// Check if `t` has a specific capability in its effective set.
/// `cap_field` is the field name on `capability.SysCap`, e.g. "cap_kill".
pub fn capable(t: *task_mod.Task, comptime cap_field: []const u8) bool {
    return @field(t.effective_caps, cap_field);
}

/// Check capability and return -EPERM if not capable, 0 otherwise.
pub fn requireCap(t: *task_mod.Task, comptime cap_field: []const u8) i64 {
    if (@field(t.effective_caps, cap_field)) return 0;
    return EPERM;
}

/// Drop a single capability from the effective set.
/// Used by privileged servers that wish to permanently relinquish a power.
pub fn dropCap(t: *task_mod.Task, comptime cap_field: []const u8) void {
    @field(t.effective_caps, cap_field) = false;
}

/// Compute the new effective set on exec(): effective = permitted & inheritable.
/// Mirrors the Linux capability(7) transition rule for non-privileged binaries.
pub fn computeExecCaps(t: *task_mod.Task) void {
    const p: u32 = @bitCast(t.permitted_caps);
    const i: u32 = @bitCast(t.inheritable_caps);
    t.effective_caps = @bitCast(p & i);
}
