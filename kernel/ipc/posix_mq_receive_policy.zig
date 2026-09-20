//! Pure size policy for POSIX message-queue receives.

pub fn bufferAcceptsMessage(buffer_len: u64, message_len: u32) bool {
    return buffer_len >= message_len;
}

test "undersized MQ receive buffers are rejected without truncation" {
    const std = @import("std");
    try std.testing.expect(bufferAcceptsMessage(5, 5));
    try std.testing.expect(bufferAcceptsMessage(6, 5));
    try std.testing.expect(!bufferAcceptsMessage(4, 5));
}
