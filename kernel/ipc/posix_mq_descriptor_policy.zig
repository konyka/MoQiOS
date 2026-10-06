//! Pure contracts for POSIX MQ descriptor validation.

pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_NONBLOCK: u32 = 0o4000;
pub const O_CLOEXEC: u32 = 0o2000000;
pub const ACCESS_MASK: u32 = 3;
pub const O_ACCMODE: u32 = ACCESS_MASK;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const KNOWN_FLAGS: u32 = ACCESS_MASK | O_NONBLOCK | O_CLOEXEC | 0o100 | 0o200;

pub const Operation = enum { send, receive };

pub fn flagsValid(flags: u32) bool {
    return (flags & ~KNOWN_FLAGS) == 0 and (flags & ACCESS_MASK) != 3;
}

pub fn canSend(access: u32) bool {
    return access == O_WRONLY or access == O_RDWR;
}

pub fn canReceive(access: u32) bool {
    return access == O_RDONLY or access == O_RDWR;
}

pub fn accessAllows(access: u32, operation: Operation) bool {
    return switch (operation) {
        .send => canSend(access),
        .receive => canReceive(access),
    };
}

pub fn statusFlags(flags: u32) u32 {
    return flags & O_NONBLOCK;
}

pub fn survivesExec(cloexec: bool) bool {
    return !cloexec;
}

test "MQ descriptor policy isolates access and exec flags" {
    const std = @import("std");
    try std.testing.expect(flagsValid(O_RDONLY | O_NONBLOCK));
    try std.testing.expect(!flagsValid(3));
    try std.testing.expect(!flagsValid(0x400));
    try std.testing.expect(canSend(O_WRONLY));
    try std.testing.expect(!canSend(O_RDONLY));
    try std.testing.expect(canReceive(O_RDONLY));
    try std.testing.expect(!canReceive(O_WRONLY));
    try std.testing.expect(survivesExec(false));
    try std.testing.expect(!survivesExec(true));
}
