//! Phase-0 strict validation for the implemented clone ABI surface.

pub const CLONE_VM: u64 = 0x100;
pub const CLONE_FS: u64 = 0x200;
pub const CLONE_FILES: u64 = 0x400;
pub const CLONE_SIGHAND: u64 = 0x800;
pub const CLONE_THREAD: u64 = 0x10000;
pub const CLONE_SETTLS: u64 = 0x80000;
pub const CLONE_PARENT_SETTID: u64 = 0x100000;
pub const CLONE_CHILD_CLEARTID: u64 = 0x200000;

// CLONE_THREAD is the thread-group membership (`Task.is_thread`: getpid reports the tgid, waitpid skips the member, exec is
// refused). Signal handlers (CLONE_SIGHAND) and the fs context (CLONE_FS) live in the Mm's group page (mm/group_state.zig), so a
// CLONE_VM child shares them by construction and a child without CLONE_VM cannot: those flags need CLONE_VM here (Linux allows
// CLONE_FS alone, which this kernel has no separate object for).
pub const IMPLEMENTED_FLAGS: u64 = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SETTLS;
pub const TID_FLAGS: u64 = CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID;

/// The low byte of clone's flags is the signal the parent gets when the child exits (Linux CSIGNAL, copy_process exit_signal): any
/// signal up to 64, or 0 for none. A child whose exit signal is not SIGCHLD is a "clone child": only waitpid with __WCLONE or __WALL
/// sees it (eligible_child). Above 64 is EINVAL (valid_signal). A thread (CLONE_THREAD) reports to nobody, so its value is unused.
pub const CSIGNAL: u64 = 0xff;
pub const SIGCHLD: u64 = 17;
pub const MAX_SIGNAL: u64 = 64;

pub fn exitSignalOk(flags: u64) bool {
    return flags & CSIGNAL <= MAX_SIGNAL;
}

/// The exit signal a new child records: the CSIGNAL byte for a process, SIGCHLD's value for a thread (never sent).
pub fn exitSignalOf(flags: u64) u8 {
    if (flags & CLONE_THREAD != 0) return @intCast(SIGCHLD);
    return @intCast(flags & CSIGNAL);
}

/// clone3_args_valid / kernel_clone_args checks on clone_args.exit_signal: the CSIGNAL bits of `flags` must be clear (clone3 has its
/// own field), the field must be a valid signal with nothing above the low byte, and a thread may not name one. The flags clone()
/// then runs with: `flags` plus the exit signal in the low byte. Null is EINVAL.
pub fn clone3Flags(flags: u64, exit_signal: u64) ?u64 {
    if (flags & CSIGNAL != 0) return null;
    if (exit_signal & ~CSIGNAL != 0 or exit_signal > MAX_SIGNAL) return null;
    if (flags & CLONE_THREAD != 0 and exit_signal != 0) return null;
    return flags | exit_signal;
}

pub fn valid(flags: u64, has_mm: bool) bool {
    if (!exitSignalOk(flags)) return false;
    if (flags & ~(IMPLEMENTED_FLAGS | TID_FLAGS | CSIGNAL) != 0) return false;
    if (flags & (TID_FLAGS | CLONE_THREAD | CLONE_SIGHAND | CLONE_FS) != 0 and flags & CLONE_VM == 0) return false;
    // copy_process: thread groups must share signals.
    if (flags & CLONE_THREAD != 0 and flags & CLONE_SIGHAND == 0) return false;
    if (flags & CLONE_VM != 0 and !has_mm) return false;
    return true;
}

/// Top of the canonical user half (exclusive).
pub const USER_ADDR_LIMIT: u64 = 0x0000_8000_0000_0000;

pub const ClonePtrError = enum { ok, bad_stack, bad_tls, parent_tid_required, child_tid_required, bad_tid_flags_ptr };

/// Validate the register-supplied addresses of a clone request.
///
/// new_stack and tls become RSP and FS_BASE of the child: a non-canonical or
/// kernel-half value would fault on the child's first dispatch (a #GP from
/// wrmsr in ring 0, or the user-frame guard halting every CPU). A stack
/// below the stack floor underflowed the initial stack-limit computation.
/// tid pointers are only consulted for the flags that name them, so an
/// unused argument register holding garbage is not an error.
pub fn checkPointers(flags: u64, new_stack: u64, tls: u64) ClonePtrError {
    if (new_stack != 0 and (new_stack >= USER_ADDR_LIMIT or new_stack < 0x1_0000 + 0x4_0000)) return .bad_stack;
    if (flags & CLONE_SETTLS != 0 and tls >= USER_ADDR_LIMIT) return .bad_tls;
    return .ok;
}

test "clone pointer policy rejects unusable stack and tls values" {
    const std = @import("std");
    try std.testing.expectEqual(ClonePtrError.ok, checkPointers(0, 0, 0));
    try std.testing.expectEqual(ClonePtrError.ok, checkPointers(CLONE_VM, 0x7f_0000, 0));
    try std.testing.expectEqual(ClonePtrError.bad_stack, checkPointers(0, 0x1000, 0));
    try std.testing.expectEqual(ClonePtrError.bad_stack, checkPointers(0, 0x8000_0000_0000, 0));
    try std.testing.expectEqual(ClonePtrError.bad_stack, checkPointers(0, 0xFFFF_8000_0000_0000, 0));
    try std.testing.expectEqual(ClonePtrError.bad_tls, checkPointers(CLONE_SETTLS, 0, 0x8000_0000_0000_0000));
    // tls is ignored without CLONE_SETTLS
    try std.testing.expectEqual(ClonePtrError.ok, checkPointers(0, 0, 0xFFFF_FFFF_FFFF_FFFF));
}

test "clone policy rejects ignored TID flags and incoherent thread combinations" {
    const std = @import("std");
    try std.testing.expect(valid(CLONE_VM | CLONE_THREAD | CLONE_SIGHAND, true));
    try std.testing.expect(!valid(CLONE_VM | CLONE_FILES | CLONE_THREAD | CLONE_SETTLS, true));
    try std.testing.expect(valid(CLONE_VM | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SETTLS, true));
    try std.testing.expect(!valid(CLONE_THREAD, true));
    try std.testing.expect(!valid(CLONE_SIGHAND, true));
    try std.testing.expect(valid(CLONE_VM | CLONE_PARENT_SETTID, true));
    try std.testing.expect(valid(CLONE_VM | CLONE_CHILD_CLEARTID, true));
    try std.testing.expect(!valid(CLONE_VM, false));
    // clone(SIGCHLD) is fork; any other signal up to 64 makes a clone child (hello450), beyond is EINVAL.
    try std.testing.expect(valid(SIGCHLD, true));
    try std.testing.expect(valid(CLONE_VM | SIGCHLD, true));
    try std.testing.expect(valid(10, true));
    try std.testing.expect(!valid(65, true));
}
