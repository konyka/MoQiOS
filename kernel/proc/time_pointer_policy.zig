//! Pure user-pointer errno policy for time syscalls.

pub fn invalidPointerErrno(ptr: u64, user_limit: u64) i64 {
    return if (ptr == 0 or ptr >= user_limit) -14 else 0;
}

test "time output pointers use EFAULT for null or kernel addresses" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, -14), invalidPointerErrno(0, 0x8000));
    try std.testing.expectEqual(@as(i64, -14), invalidPointerErrno(0x8000, 0x8000));
    try std.testing.expectEqual(@as(i64, 0), invalidPointerErrno(0x4000, 0x8000));
}
