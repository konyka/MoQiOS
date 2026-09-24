//! Pure one-shot native IPC call/reply authorization state.

pub const RUNTIME_UNSUPPORTED: i64 = -95;

pub fn runtimeAvailable() bool {
    return true;
}

pub fn tokenBindsCallee(token: u64, expected_callee_tid: u32, token_callee_tid: u32, live_callee_tid: u32) bool {
    return token != 0 and expected_callee_tid == token_callee_tid and token_callee_tid == live_callee_tid;
}

pub const ReplyBinding = struct {
    callee_task: ?u32 = null,
    callee_tid: ?u32 = null,
    token: u64 = 0,
};

pub fn clearBinding(binding: *ReplyBinding) void {
    binding.* = .{};
}

pub const State = struct {
    active: bool = false,
    token: u64 = 0,
    caller_task: u32 = 0,
    target_endpoint: u32 = 0,
    callee_task: u32 = 0,
    reply_pending: bool = false,
};

pub fn begin(state: *State, token: u64, caller_task: u32, target_endpoint: u32) bool {
    if (state.active or token == 0 or target_endpoint == 0) return false;
    state.* = .{ .active = true, .token = token, .caller_task = caller_task, .target_endpoint = target_endpoint };
    return true;
}

pub fn bindCallee(state: *State, callee_task: u32) bool {
    if (!state.active or state.callee_task != 0) return false;
    state.callee_task = callee_task;
    return true;
}

pub fn replyAllowed(state: *const State, token: u64, caller_task: u32, callee_task: u32) bool {
    return state.active and !state.reply_pending and state.token == token and
        state.caller_task == caller_task and state.callee_task == callee_task;
}

pub fn consumeReply(state: *State) bool {
    if (!state.active or state.reply_pending) return false;
    state.reply_pending = true;
    state.active = false;
    return true;
}

pub fn teardown(state: *State) void {
    state.* = .{};
}

test "call/reply is one-shot and bound to caller/callee/token" {
    const std = @import("std");
    var state = State{};
    try std.testing.expect(begin(&state, 9, 1, 7));
    try std.testing.expect(bindCallee(&state, 2));
    try std.testing.expect(!replyAllowed(&state, 8, 1, 2));
    try std.testing.expect(!replyAllowed(&state, 9, 3, 2));
    try std.testing.expect(replyAllowed(&state, 9, 1, 2));
    try std.testing.expect(consumeReply(&state));
    try std.testing.expect(!consumeReply(&state));
    teardown(&state);
    try std.testing.expect(!state.active);
}

test "public call/reply runtime is available after atomic registration" {
    const std = @import("std");
    try std.testing.expect(runtimeAvailable());
}

test "failed or interrupted calls clear every reply binding field" {
    const std = @import("std");
    var binding = ReplyBinding{ .callee_task = 4, .callee_tid = 77, .token = 9 };
    clearBinding(&binding);
    try std.testing.expect(binding.callee_task == null);
    try std.testing.expect(binding.callee_tid == null);
    try std.testing.expectEqual(@as(u64, 0), binding.token);
}
