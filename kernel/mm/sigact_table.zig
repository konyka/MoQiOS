//! Signal dispositions of one thread group, kept in Mm.
//!
//! They belong to the address space, not to a thread: every pthread is created with CLONE_SIGHAND, so a handler installed
//! by one thread is the handler every other thread runs, and a signal sent to the process runs the handler installed
//! last. A fork child (new Mm) starts with a copy; exec resets caught signals to default in the new image's table.
//! Entries are single words written by the thread that calls sigaction (or that delivers a SA_RESETHAND signal) and read
//! by signal senders and receivers without a lock, as they always were.

pub const SigActions = struct {
    /// Handler addresses. 0 = default, 1 = ignore. Index 0 = signal 1 (SIGHUP) ... index 63 = signal 64 (SIGRTMAX).
    handlers: [64]u64,
    /// Per-signal sa_mask: added to the task mask while that handler runs (the signal frame saves it, sigreturn restores it).
    masks: [64]u64,
    /// Per-signal sa_flags (SA_NODEFER, SA_RESETHAND, SA_ONSTACK honoured at delivery).
    flags: [64]u64,
};
