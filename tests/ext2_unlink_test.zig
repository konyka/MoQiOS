//! Host tests for ext2 unlink/rename-overwrite lifetime: an inode whose last
//! link is removed while still open is reclaimed only on the last close.

const std = @import("std");
const p = @import("kernel_shared").ext2_unlink_policy;

test "ext2 unlink of a hard-linked inode only decrements links_count" {
    try std.testing.expectEqual(p.UnlinkAction.decrement, p.onLinkRemoved(2, 0));
    try std.testing.expectEqual(p.UnlinkAction.decrement, p.onLinkRemoved(3, 4));
}

test "ext2 unlink of the last link frees immediately when nothing has it open" {
    try std.testing.expectEqual(p.UnlinkAction.free_now, p.onLinkRemoved(1, 0));
    // A corrupt links_count of 0 must still reclaim rather than underflow.
    try std.testing.expectEqual(p.UnlinkAction.free_now, p.onLinkRemoved(0, 0));
}

test "ext2 unlink of the last link defers reclaim while any slot is open" {
    try std.testing.expectEqual(p.UnlinkAction.defer_until_close, p.onLinkRemoved(1, 1));
    try std.testing.expectEqual(p.UnlinkAction.defer_until_close, p.onLinkRemoved(1, 5));
    try std.testing.expectEqual(p.UnlinkAction.defer_until_close, p.onLinkRemoved(0, 1));
}

test "ext2 close reclaims a pending inode only on its very last reference" {
    // Last reference of the last slot: reclaim.
    try std.testing.expect(p.reclaimOnClose(true, 1, 0));
    // fork/clone still holds the slot: just drop a reference.
    try std.testing.expect(!p.reclaimOnClose(true, 2, 0));
    // Another slot (separate open) still references the inode.
    try std.testing.expect(!p.reclaimOnClose(true, 1, 1));
    // Not unlinked: an ordinary close never frees the inode.
    try std.testing.expect(!p.reclaimOnClose(false, 1, 0));
}
