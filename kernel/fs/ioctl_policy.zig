//! Pure ioctl request classification and FIONREAD arithmetic.
//!
//! Terminal requests only make sense on a terminal: on a pipe, socket, file
//! or device that is not a tty they fail with ENOTTY (that is what isatty()
//! relies on). FIONREAD answers for every descriptor; FIOCLEX/FIONCLEX take
//! no argument.

pub const TCGETS: u64 = 0x5401;
pub const TCSETS: u64 = 0x5402;
pub const TCSETSW: u64 = 0x5403;
pub const TCSETSF: u64 = 0x5404;
pub const TIOCGPGRP: u64 = 0x540F;
pub const TIOCSPGRP: u64 = 0x5410;
pub const TIOCGWINSZ: u64 = 0x5413;
pub const TIOCSWINSZ: u64 = 0x5414;
pub const FIONREAD: u64 = 0x541B;
pub const FIONBIO: u64 = 0x5421;
pub const FIONCLEX: u64 = 0x5450;
pub const FIOCLEX: u64 = 0x5451;

pub fn isTerminalRequest(cmd: u64) bool {
    return switch (cmd) {
        TCGETS, TCSETS, TCSETSW, TCSETSF, TIOCGPGRP, TIOCSPGRP, TIOCGWINSZ, TIOCSWINSZ => true,
        else => false,
    };
}

/// What a descriptor is, as far as terminal requests care.
pub const Target = enum { terminal, other };

/// ENOTTY (-25) when a terminal request meets a non-terminal descriptor.
pub fn terminalCheck(cmd: u64, target: Target) i64 {
    if (isTerminalRequest(cmd) and target != .terminal) return -25;
    return 0;
}

/// FIONREAD on a file: bytes between the offset and the end, never negative.
pub fn fileReadable(size: u64, offset: u64) u32 {
    if (offset >= size) return 0;
    const left = size - offset;
    return @intCast(@min(left, 0x7FFF_FFFF));
}

test "terminal requests need a terminal" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, -25), terminalCheck(TCGETS, .other));
    try std.testing.expectEqual(@as(i64, -25), terminalCheck(TIOCGWINSZ, .other));
    try std.testing.expectEqual(@as(i64, -25), terminalCheck(TIOCGPGRP, .other));
    try std.testing.expectEqual(@as(i64, 0), terminalCheck(TCGETS, .terminal));
    try std.testing.expectEqual(@as(i64, 0), terminalCheck(FIONREAD, .other));
    try std.testing.expectEqual(@as(i64, 0), terminalCheck(FIONBIO, .other));
    try std.testing.expectEqual(@as(i64, 0), terminalCheck(FIOCLEX, .other));
    try std.testing.expect(isTerminalRequest(TCSETSW));
    try std.testing.expect(!isTerminalRequest(0x12345));
}

test "FIONREAD on a file counts the bytes after the offset" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 6), fileReadable(10, 4));
    try std.testing.expectEqual(@as(u32, 0), fileReadable(10, 10));
    try std.testing.expectEqual(@as(u32, 0), fileReadable(10, 99));
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), fileReadable(1 << 40, 0));
}
