//! Pure signal-disposition rules applied when execve commits a new image.

pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;

/// Disposition a signal has in the new image given its disposition in the
/// old one (POSIX exec): caught signals revert to SIG_DFL — the handler
/// address belonged to the replaced image — while SIG_IGN and SIG_DFL stay.
pub fn execHandlerAfter(old: u64) u64 {
    return if (old == SIG_IGN) SIG_IGN else SIG_DFL;
}
