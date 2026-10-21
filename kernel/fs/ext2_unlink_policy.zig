//! ext2 unlink/rename lifetime policy: an inode whose last directory entry is
//! removed is reclaimed only once no open-file slot still references it
//! (POSIX "unlinked but open" semantics). Pure decisions, host-testable.

/// What to do with an inode after one of its directory entries is removed.
pub const UnlinkAction = enum {
    /// Other hard links remain: just store the decremented links_count.
    decrement,
    /// Last link and nobody has it open: free blocks + inode now.
    free_now,
    /// Last link but still open: persist links_count = 0, mark the open
    /// slots pending, and free on the last close.
    defer_until_close,
};

pub fn onLinkRemoved(links_count: u32, open_slots: u32) UnlinkAction {
    if (links_count > 1) return .decrement;
    if (open_slots == 0) return .free_now;
    return .defer_until_close;
}

/// Decide whether dropping one reference from an open slot finalizes a
/// pending unlink: the slot must be released (its last reference) and no
/// other slot may still reference the same inode.
pub fn reclaimOnClose(unlink_pending: bool, slot_refs_before: u32, other_open_slots: u32) bool {
    return unlink_pending and slot_refs_before <= 1 and other_open_slots == 0;
}
