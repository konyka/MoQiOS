//! recv(2) flags shared by the stream and datagram socket kinds, as pure rules.

const std = @import("std");

pub const MSG_PEEK: u32 = 0x2;
pub const MSG_TRUNC: u32 = 0x20;
pub const MSG_WAITALL: u32 = 0x100;

pub fn peek(flags: u32) bool {
    return flags & MSG_PEEK != 0;
}

pub fn truncReportsFullLength(flags: u32) bool {
    return flags & MSG_TRUNC != 0;
}

/// MSG_WAITALL is meaningful for stream sockets only, and never together with
/// MSG_PEEK (a peek leaves the data in place, so waiting for more of it would
/// never make progress) or a non-blocking request.
pub fn waitAll(flags: u32, stream: bool, nonblock: bool) bool {
    return stream and !nonblock and flags & MSG_WAITALL != 0 and flags & MSG_PEEK == 0;
}

pub const Step = enum { done, again, stop };

/// One step of a MSG_WAITALL loop after a read returned `result` with `got`
/// bytes already delivered out of `want`: a full buffer finishes it; more data
/// asks for another read; EOF, an error or a signal ends it with what we have
/// (the caller returns the short count, or the error if nothing was read).
pub fn waitAllStep(want: usize, got: usize, result: i64) Step {
    if (result <= 0) return .stop;
    if (got + @as(usize, @intCast(result)) >= want) return .done;
    return .again;
}

test "flags decode" {
    try std.testing.expect(peek(MSG_PEEK | 0x40));
    try std.testing.expect(!peek(0x40));
    try std.testing.expect(truncReportsFullLength(MSG_TRUNC));
    try std.testing.expect(waitAll(MSG_WAITALL, true, false));
    try std.testing.expect(!waitAll(MSG_WAITALL, false, false));
    try std.testing.expect(!waitAll(MSG_WAITALL, true, true));
    try std.testing.expect(!waitAll(MSG_WAITALL | MSG_PEEK, true, false));
    try std.testing.expect(!waitAll(0, true, false));
}
