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
