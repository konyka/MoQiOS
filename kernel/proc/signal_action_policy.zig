//! Pure rules for SIGKILL/SIGSTOP, which can never be caught, ignored or
//! blocked.

pub const SIGKILL: u32 = 9;
pub const SIGSTOP: u32 = 19;

/// Mask bits for SIGKILL/SIGSTOP (bit N = signal N+1).
pub const UNBLOCKABLE: u64 = (@as(u64, 1) << (SIGKILL - 1)) | (@as(u64, 1) << (SIGSTOP - 1));

/// sigaction may install a new action for `signum` only when it is neither
/// SIGKILL nor SIGSTOP; a pure query (no new action) is always allowed.
pub fn actionChangeAllowed(signum: u32, installing: bool) bool {
    if (!installing) return true;
    return signum != SIGKILL and signum != SIGSTOP;
}

/// A requested signal mask with the unblockable signals removed.
pub fn sanitizeMask(mask: u64) u64 {
    return mask & ~UNBLOCKABLE;
}

/// Whether a send of `signum` is dropped on the spot (Linux sig_ignored): the target does not block it and its action ignores it
/// (`handler` 1 is SIG_IGN; 0 is SIG_DFL, which ignores when `default_ignores`). A blocked signal is kept, since the action may change
/// before it is unblocked. SIGKILL and SIGSTOP are never dropped.
pub fn droppedAtSend(signum: u32, handler: u64, default_ignores: bool, blocked: bool) bool {
    if (signum == SIGKILL or signum == SIGSTOP or blocked) return false;
    return handler == 1 or (handler == 0 and default_ignores);
}

const testing = @import("std").testing;

test "an unblocked ignored signal is dropped at send; a blocked one is kept" {
    try testing.expect(droppedAtSend(10, 1, false, false));
    try testing.expect(!droppedAtSend(10, 1, false, true));
    try testing.expect(droppedAtSend(17, 0, true, false)); // SIGCHLD left at SIG_DFL
    try testing.expect(!droppedAtSend(10, 0, false, false)); // SIG_DFL that terminates
    try testing.expect(!droppedAtSend(10, 0x401000, false, false)); // a handler
    try testing.expect(!droppedAtSend(SIGKILL, 1, false, false));
    try testing.expect(!droppedAtSend(SIGSTOP, 1, false, false));
}
