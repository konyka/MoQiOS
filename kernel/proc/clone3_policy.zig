//! Pure ABI bounds for clone3's extensible clone_args structure.

pub const MIN_SIZE: u64 = 64;
pub const CURRENT_SIZE: u64 = 88;
pub const FLAGS_OFFSET: usize = 0;
pub const CHILD_TID_OFFSET: usize = 16;
pub const PARENT_TID_OFFSET: usize = 24;
pub const STACK_OFFSET: usize = 40;
pub const TLS_OFFSET: usize = 56;
pub const PIDFD_OFFSET: usize = 8;
pub const EXIT_SIGNAL_OFFSET: usize = 32;
pub const STACK_SIZE_OFFSET: usize = 48;
pub const SET_TID_OFFSET: usize = 64;
pub const SET_TID_SIZE_OFFSET: usize = 72;
pub const CGROUP_OFFSET: usize = 80;

pub fn sizeValid(size: u64) bool {
    return size >= MIN_SIZE and size <= CURRENT_SIZE;
}

pub fn copySize(size: u64) usize {
    return @intCast(@min(size, CURRENT_SIZE));
}

pub fn unsupportedFieldsZero(
    pidfd: u64,
    exit_signal: u64,
    stack_size: u64,
    set_tid: u64,
    set_tid_size: u64,
    cgroup: u64,
) bool {
    return pidfd == 0 and exit_signal == 0 and stack_size == 0 and
        set_tid == 0 and set_tid_size == 0 and cgroup == 0;
}

test "clone3 accepts bounded structures and copies only the supplied prefix" {
    const std = @import("std");
    try std.testing.expect(!sizeValid(63));
    try std.testing.expect(sizeValid(64));
    try std.testing.expect(sizeValid(88));
    try std.testing.expect(!sizeValid(89));
    try std.testing.expectEqual(@as(usize, 64), copySize(64));
    try std.testing.expectEqual(@as(usize, 88), copySize(88));
    try std.testing.expect(unsupportedFieldsZero(0, 0, 0, 0, 0, 0));
    try std.testing.expect(!unsupportedFieldsZero(1, 0, 0, 0, 0, 0));
}
