//! Pure signal-delivery mask and flag rules (POSIX sigaction semantics).
//!
//! While a handler for `signum` runs, the task mask is the interrupted mask
//! plus the handler's sa_mask plus `signum` itself (unless SA_NODEFER). The
//! interrupted mask is saved in the signal frame and restored by sigreturn.
//! SIGKILL and SIGSTOP are never blocked.

pub const SA_NODEFER: u64 = 0x4000_0000;
pub const SA_RESETHAND: u64 = 0x8000_0000;

const UNBLOCKABLE: u64 = (@as(u64, 1) << 8) | (@as(u64, 1) << 18);

fn bit(signum: u32) u64 {
    return @as(u64, 1) << @intCast(signum - 1);
}

/// Task mask to install for the duration of `signum`'s handler.
pub fn handlerMask(current_mask: u64, signum: u32, sa_mask: u64, sa_flags: u64) u64 {
    var m = current_mask | sa_mask;
    if (sa_flags & SA_NODEFER == 0) m |= bit(signum);
    return m & ~UNBLOCKABLE;
}

/// Handler slot value after delivering `signum` with `sa_flags`:
/// SA_RESETHAND reverts the disposition to SIG_DFL (one-shot handler).
pub fn handlerAfterDelivery(handler: u64, sa_flags: u64) u64 {
    return if (sa_flags & SA_RESETHAND != 0) 0 else handler;
}

/// Mask restored by sigreturn from the saved frame value.
pub fn restoredMask(saved_mask: u64) u64 {
    return saved_mask & ~UNBLOCKABLE;
}
