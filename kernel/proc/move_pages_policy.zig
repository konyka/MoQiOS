const errno = @import("../lib/errno.zig");

const USER_ADDR_MAX: u64 = 0x0000_8000_0000_0000;
const MAX_COUNT: u64 = 4096;

pub fn validate(pid: u32, count: u64, pages: u64, nodes: u64, status: u64, flags: u64) i64 {
    // NUMA migration is not implemented; retain only the status-only stub shape.
    if (flags != 0) return errno.EINVAL;
    if (pid != 0 or pages != 0 or nodes != 0) return errno.ENOSYS;
    if (count > MAX_COUNT) return errno.EINVAL;
    if (count != 0) {
        if (status == 0 or status >= USER_ADDR_MAX) return errno.EFAULT;
        if (status > USER_ADDR_MAX - count * @sizeOf(i32)) return errno.EFAULT;
    }
    return 0;
}

test "move_pages policy requires the status-only stub shape" {
    try @import("std").testing.expectEqual(@as(i64, 0), validate(0, 2, 0, 0, 0x1000, 0));
    try @import("std").testing.expectEqual(errno.EFAULT, validate(0, 1, 0, 0, 0, 0));
    try @import("std").testing.expectEqual(errno.EINVAL, validate(0, 1, 0, 0, 0x1000, 1));
    try @import("std").testing.expectEqual(errno.ENOSYS, validate(1, 1, 0, 0, 0x1000, 0));
    try @import("std").testing.expectEqual(errno.EFAULT, validate(0, 1, 0, 0, USER_ADDR_MAX - 3, 0));
}
