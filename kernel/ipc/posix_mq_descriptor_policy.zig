//! Pure policy for POSIX MQ open descriptions and descriptor tokens.

pub const MAX_DESCRIPTORS: u32 = 32;
pub const DESCRIPTOR_BASE: u32 = 300;
pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_ACCMODE: u32 = 3;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const O_NONBLOCK: u32 = 0o4000;
pub const O_CLOEXEC: u32 = 0o2000000;
pub const ALLOWED_FLAGS: u32 = O_ACCMODE | O_CREAT | O_EXCL | O_NONBLOCK | O_CLOEXEC;

pub const OpenDescription = struct {
    queue_index: u32,
    queue_generation: u64,
    description_generation: u64,
    access: u32,
    status_flags: u32,
    cloexec: bool,
    owner_task: u32,
    open: bool = true,
};

pub const Token = struct {
    slot: u32,
    generation: u64,
};

pub const CloseResult = enum { invalid, closed, reclaim_queue };

pub fn tokenFor(slot: u32, generation: u64) Token {
    return .{ .slot = slot, .generation = generation };
}

pub fn tokenValue(token: Token) u32 {
    return DESCRIPTOR_BASE + token.slot;
}

pub fn decodeToken(mqd: u32) ?u32 {
    if (mqd < DESCRIPTOR_BASE or mqd >= DESCRIPTOR_BASE + MAX_DESCRIPTORS) return null;
    return mqd - DESCRIPTOR_BASE;
}

pub fn flagsValid(oflag: u32) bool {
    return oflag & ~ALLOWED_FLAGS == 0 and (oflag & O_ACCMODE) != 3;
}

pub fn statusFlags(oflag: u32) u32 {
    return oflag & O_NONBLOCK;
}

pub fn accessAllows(access: u32, operation: enum { send, receive }) bool {
    return switch (operation) {
        .send => access == O_WRONLY or access == O_RDWR,
        .receive => access == O_RDONLY or access == O_RDWR,
    };
}

pub fn tokenMatches(desc: OpenDescription, token: Token, queue_generation: u64) bool {
    return desc.open and desc.queue_generation == queue_generation and
        token.slot < MAX_DESCRIPTORS and token.generation == desc.description_generation;
}

pub fn closeResult(desc: OpenDescription, remaining_refs: u32, marked_removed: bool, queued_messages: u32) CloseResult {
    if (!desc.open) return .invalid;
    if (remaining_refs == 0 and marked_removed and queued_messages == 0) return .reclaim_queue;
    return .closed;
}

test "MQ descriptor policy creates distinct tokens and preserves per-open flags" {
    const std = @import("std");
    const first = tokenFor(0, 11);
    const second = tokenFor(1, 11);
    try std.testing.expect(first.slot != second.slot);
    try std.testing.expectEqual(@as(u32, DESCRIPTOR_BASE), tokenValue(first));
    try std.testing.expectEqual(@as(?u32, 1), decodeToken(tokenValue(second)));
    try std.testing.expectEqual(@as(u32, O_NONBLOCK), statusFlags(O_RDONLY | O_NONBLOCK));
}

test "MQ descriptor policy validates flags, access, generation, and close" {
    const std = @import("std");
    try std.testing.expect(flagsValid(O_RDWR | O_CREAT | O_NONBLOCK | O_CLOEXEC));
    try std.testing.expect(!flagsValid(0x80000000));
    try std.testing.expect(!flagsValid(3));
    try std.testing.expect(accessAllows(O_WRONLY, .send));
    try std.testing.expect(!accessAllows(O_WRONLY, .receive));
    const desc = OpenDescription{ .queue_index = 2, .queue_generation = 7, .description_generation = 1, .access = O_RDWR, .status_flags = 0, .cloexec = true, .owner_task = 4 };
    try std.testing.expect(tokenMatches(desc, tokenFor(3, 1), 7));
    try std.testing.expect(!tokenMatches(desc, tokenFor(3, 2), 7));
    try std.testing.expect(!tokenMatches(desc, tokenFor(3, 1), 8));
    try std.testing.expectEqual(CloseResult.reclaim_queue, closeResult(desc, 0, true, 0));
    try std.testing.expectEqual(CloseResult.closed, closeResult(desc, 1, true, 0));
}
