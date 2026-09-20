//! Pure command classification for lock-safe shmctl user copies.

pub const IPC_STAT: i32 = 2;
pub const IPC_SET: i32 = 1;

pub fn copyBeforeLock(cmd: i32) bool {
    return cmd == IPC_SET;
}

pub fn copyAfterUnlock(cmd: i32) bool {
    return cmd == IPC_STAT;
}

pub fn encodeKey(key: i32) u64 {
    return @bitCast(@as(i64, key));
}

test "shmctl copies user buffers outside the IRQ lock" {
    const std = @import("std");
    try std.testing.expect(copyBeforeLock(IPC_SET));
    try std.testing.expect(copyAfterUnlock(IPC_STAT));
    try std.testing.expect(!copyBeforeLock(IPC_STAT));
    try std.testing.expect(!copyAfterUnlock(IPC_SET));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), encodeKey(-1));
}
