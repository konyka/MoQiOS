const errno = @import("../lib/errno.zig");

pub fn validatePid(pid: u32, current_tid: u32, target_exists: bool) i64 {
    if (!target_exists or (pid != 0 and pid != current_tid)) return errno.ESRCH;
    return 0;
}

test "sched_getaffinity pid policy accepts self and zero only" {
    try @import("std").testing.expectEqual(@as(i64, 0), validatePid(0, 42, true));
    try @import("std").testing.expectEqual(@as(i64, 0), validatePid(42, 42, true));
    try @import("std").testing.expectEqual(errno.ESRCH, validatePid(41, 42, true));
    try @import("std").testing.expectEqual(errno.ESRCH, validatePid(42, 42, false));
}
