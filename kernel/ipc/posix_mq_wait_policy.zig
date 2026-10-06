//! Pure ownership and terminal-transition policy for POSIX MQ waiters.

pub const Direction = enum { send, receive };
pub const Terminal = enum { queued, woken, cancelled, timed_out };

pub const Token = struct {
    task_slot: u32,
    task_incarnation: u64,
    queue_index: u32,
    queue_generation: u64,
    direction: Direction,
    waiter_generation: u64,
};

pub const Waiter = struct {
    token: Token,
    state: Terminal = .queued,
    linked: bool = false,
    prev: ?u32 = null,
    next: ?u32 = null,
};

pub const FifoQueue = struct {
    head: ?u32 = null,
    tail: ?u32 = null,

    pub fn push(self: *FifoQueue, waiter: *Waiter, id: u32) void {
        waiter.prev = self.tail;
        waiter.next = null;
        waiter.linked = true;
        if (self.tail == null) self.head = id;
        self.tail = id;
    }

    pub fn pop(self: *FifoQueue, id: u32, next_id: ?u32) bool {
        if (self.head != id) return false;
        self.head = next_id;
        if (self.head == null) self.tail = null;
        return true;
    }
};

pub fn tokenMatches(expected: Token, actual: Token) bool {
    return expected.task_slot == actual.task_slot and
        expected.task_incarnation == actual.task_incarnation and
        expected.queue_index == actual.queue_index and
        expected.queue_generation == actual.queue_generation and
        expected.direction == actual.direction and
        expected.waiter_generation == actual.waiter_generation;
}

pub fn claim(waiter: *Waiter, terminal: Terminal) bool {
    if (waiter.state != .queued) return false;
    waiter.state = terminal;
    return true;
}

pub fn detach(waiter: *Waiter) bool {
    if (!waiter.linked) return false;
    waiter.linked = false;
    waiter.prev = null;
    waiter.next = null;
    return true;
}

pub fn queuePush(waiter: *Waiter) void {
    waiter.linked = true;
}

test "MQ waiter terminal transition is claimed exactly once" {
    const std = @import("std");
    var waiter = Waiter{ .token = .{
        .task_slot = 2,
        .task_incarnation = 7,
        .queue_index = 3,
        .queue_generation = 11,
        .direction = .send,
        .waiter_generation = 19,
    } };
    try std.testing.expect(claim(&waiter, .woken));
    try std.testing.expect(!claim(&waiter, .timed_out));
    try std.testing.expectEqual(Terminal.woken, waiter.state);
}

test "MQ waiter token rejects queue and task ABA" {
    const std = @import("std");
    const token = Token{
        .task_slot = 1,
        .task_incarnation = 2,
        .queue_index = 3,
        .queue_generation = 4,
        .direction = .receive,
        .waiter_generation = 5,
    };
    var changed = token;
    changed.queue_generation += 1;
    try std.testing.expect(tokenMatches(token, token));
    try std.testing.expect(!tokenMatches(token, changed));
    changed = token;
    changed.task_incarnation += 1;
    try std.testing.expect(!tokenMatches(token, changed));
}

test "MQ waiter queue is FIFO and detach is idempotent" {
    const std = @import("std");
    var first = Waiter{ .token = undefined };
    var second = Waiter{ .token = undefined };
    var third = Waiter{ .token = undefined };
    var queue = FifoQueue{};
    queue.push(&first, 1);
    queue.push(&second, 2);
    queue.push(&third, 3);
    try std.testing.expectEqual(@as(?u32, 1), queue.head);
    try std.testing.expectEqual(@as(?u32, 3), queue.tail);
    try std.testing.expect(queue.pop(1, 2));
    try std.testing.expectEqual(@as(?u32, 2), queue.head);
    try std.testing.expect(!queue.pop(1, 3));
    try std.testing.expect(queue.pop(2, 3));
    try std.testing.expect(queue.pop(3, null));
    queuePush(&first);
    try std.testing.expect(first.linked);
    try std.testing.expect(detach(&first));
    try std.testing.expect(!detach(&first));
    try std.testing.expect(second.linked);
    try std.testing.expect(third.linked);
}

test "MQ waiter exit cancellation wins over a later wake" {
    const std = @import("std");
    var waiter = Waiter{ .token = undefined };
    queuePush(&waiter);
    try std.testing.expect(claim(&waiter, .cancelled));
    try std.testing.expect(!claim(&waiter, .woken));
    try std.testing.expect(detach(&waiter));
}
