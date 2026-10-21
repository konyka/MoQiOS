//! Host tests for the MoqIPC call/reply slot policy: a call() reply must be
//! parked in its own reply slot so it can never collide with a third-party
//! sender blocked on the caller's endpoint (pending_msg).

const std = @import("std");
const p = @import("kernel_shared").ipc_policy;

test "reply while a third-party sender is blocked does not overwrite its message" {
    // A owns ep_A and is blocked in call(B). C sends to ep_A and blocks.
    var ep_a = p.SlotModel{};
    try std.testing.expectEqual(p.SendAction.block, ep_a.send(0xC0C0));
    // B replies to A's outstanding call.
    ep_a.reply(0xB0B0);
    // C's queued message is untouched.
    try std.testing.expectEqual(@as(?u64, 0xC0C0), ep_a.pending_msg);
    try std.testing.expect(ep_a.waiting_sender);
    // A wakes and must receive B's reply, not a signal kick.
    var reply_buf: ?u64 = null;
    try std.testing.expectEqual(p.CallWake.reply_arrived, ep_a.callTakeReply(&reply_buf));
    try std.testing.expectEqual(@as(?u64, 0xB0B0), reply_buf);
    // A's next receive() picks up C's original message.
    var got: ?u64 = null;
    try std.testing.expectEqual(p.ReceiveAction.pick_up, ep_a.receive(&got));
    try std.testing.expectEqual(@as(?u64, 0xC0C0), got);
    try std.testing.expect(!ep_a.waiting_sender);
}

test "reply parked before the third-party send is still delivered to the caller" {
    var ep_a = p.SlotModel{};
    ep_a.reply(0x1111);
    try std.testing.expectEqual(p.SendAction.block, ep_a.send(0x2222));
    var reply_buf: ?u64 = null;
    try std.testing.expectEqual(p.CallWake.reply_arrived, ep_a.callTakeReply(&reply_buf));
    try std.testing.expectEqual(@as(?u64, 0x1111), reply_buf);
    var got: ?u64 = null;
    try std.testing.expectEqual(p.ReceiveAction.pick_up, ep_a.receive(&got));
    try std.testing.expectEqual(@as(?u64, 0x2222), got);
}

test "receive never consumes a parked reply as an inbound message" {
    var ep_a = p.SlotModel{};
    ep_a.reply(0xAAAA);
    var got: ?u64 = null;
    // No sender waiting: receive blocks instead of taking the reply.
    try std.testing.expectEqual(p.ReceiveAction.block, ep_a.receive(&got));
    try std.testing.expectEqual(@as(?u64, null), got);
    try std.testing.expectEqual(@as(?u64, 0xAAAA), ep_a.reply_msg);
}

test "callWake: reply slot presence alone decides delivery" {
    try std.testing.expectEqual(p.CallWake.reply_arrived, p.callWake(true));
    try std.testing.expectEqual(p.CallWake.signal_kick, p.callWake(false));
}

test "signal kick wake leaves a third-party sender's queued message intact" {
    var ep_a = p.SlotModel{};
    try std.testing.expectEqual(p.SendAction.block, ep_a.send(0x7777));
    var reply_buf: ?u64 = null;
    try std.testing.expectEqual(p.CallWake.signal_kick, ep_a.callTakeReply(&reply_buf));
    try std.testing.expectEqual(@as(?u64, null), reply_buf);
    try std.testing.expectEqual(@as(?u64, 0x7777), ep_a.pending_msg);
    try std.testing.expect(ep_a.waiting_sender);
    try std.testing.expectEqual(@as(?u64, null), ep_a.reply_msg);
}

test "abandoning a call clears only the reply slot, never a sender's message" {
    var ep_a = p.SlotModel{};
    try std.testing.expectEqual(p.SendAction.block, ep_a.send(0x7777));
    ep_a.reply(0x5555);
    ep_a.cancelCall();
    try std.testing.expectEqual(@as(?u64, null), ep_a.reply_msg);
    try std.testing.expectEqual(@as(?u64, 0x7777), ep_a.pending_msg);
    try std.testing.expect(ep_a.waiting_sender);
}
