//! Host tests for the SysV msgrcv selection policy: selection must follow
//! enqueue order (seq), never ring position.

const std = @import("std");
const p = @import("kernel_shared").sysv_msg_select_policy;

const Slot = p.Slot;

fn slot(mtype: i64, seq: u64) Slot {
    return .{ .used = true, .mtype = mtype, .seq = seq };
}

test "msgtyp 0 picks the oldest message even when a newer one back-filled an earlier slot" {
    // Ring after: A(1,seq0) B(2,seq1) C(1,seq2); msgrcv(type 2) took B leaving
    // a hole at slot 1; queue full -> msgsnd back-filled slot 1 with D(seq3).
    const slots = [_]Slot{ .{}, slot(1, 3), slot(1, 2), .{} };
    // Slot 0 consumed too: oldest remaining is C (seq 2) at slot 2, not D.
    try std.testing.expectEqual(@as(?usize, 2), p.select(&slots, 0));
}

test "msgtyp 0 FIFO across a wrapped ring" {
    const slots = [_]Slot{ slot(5, 10), slot(5, 11), slot(5, 8), slot(5, 9) };
    try std.testing.expectEqual(@as(?usize, 2), p.select(&slots, 0));
}

test "msgtyp > 0 picks the oldest message of exactly that type" {
    const slots = [_]Slot{ slot(3, 7), slot(4, 1), slot(3, 5), slot(3, 6) };
    try std.testing.expectEqual(@as(?usize, 2), p.select(&slots, 3));
    try std.testing.expectEqual(@as(?usize, 1), p.select(&slots, 4));
    try std.testing.expectEqual(@as(?usize, null), p.select(&slots, 9));
}

test "msgtyp < 0 picks the lowest type <= |msgtyp|, oldest within that type" {
    const slots = [_]Slot{ slot(2, 9), slot(1, 4), slot(5, 0), slot(1, 3), slot(2, 1) };
    try std.testing.expectEqual(@as(?usize, 3), p.select(&slots, -2));
    try std.testing.expectEqual(@as(?usize, 3), p.select(&slots, -5));
    // Only type 5 is excluded below -4; types 1 and 2 still win.
    try std.testing.expectEqual(@as(?usize, 3), p.select(&slots, -4));
    const high = [_]Slot{ slot(5, 0), slot(7, 1) };
    try std.testing.expectEqual(@as(?usize, null), p.select(&high, -4));
}

test "msgtyp minInt clamps to maxInt and matches every type" {
    const slots = [_]Slot{ slot(std.math.maxInt(i64), 0), slot(9, 2), slot(9, 1) };
    try std.testing.expectEqual(@as(?usize, 2), p.select(&slots, std.math.minInt(i64)));
}

test "empty or all-unused slots select nothing" {
    const slots = [_]Slot{ .{}, .{}, .{} };
    try std.testing.expectEqual(@as(?usize, null), p.select(&slots, 0));
    try std.testing.expectEqual(@as(?usize, null), p.select(&slots, 1));
    try std.testing.expectEqual(@as(?usize, null), p.select(&slots, -1));
}
