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

/// The affinity mask sched_getaffinity reports: the one CPU a task is pinned to, or every configured CPU when it is not pinned
/// (`affinity` < 0). `out` is zeroed first; the result is the byte count Linux returns, which is the size of the kernel's CPU mask
/// rounded up to a multiple of 8 and at most the caller's `cpusetsize`. Returns null when `cpusetsize` is too small to hold the mask
/// for the configured CPUs (Linux: EINVAL).
pub fn buildMask(out: []u8, affinity: i16, cpu_count: u32, cpusetsize: u64) ?usize {
    @memset(out, 0);
    // Bytes needed for CPU ids 0..cpu_count-1, rounded up to a whole 8-byte word like the kernel's cpumask.
    const need: usize = @intCast(((@as(u64, @max(cpu_count, 1)) + 63) / 64) * 8);
    // Linux (measured with the raw call): the size must be a multiple of 8 (7, 9, 15, 127, 129 are EINVAL) and not less than the mask
    // (0, 1, 4 are EINVAL); a larger multiple of 8 (16, 128, 200) is fine and only `need` bytes are written and returned.
    if (cpusetsize < need or cpusetsize % 8 != 0 or need > out.len) return null;
    if (affinity >= 0 and @as(u32, @intCast(affinity)) < cpu_count) {
        const bit: u32 = @intCast(affinity);
        out[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
    } else {
        var i: u32 = 0;
        while (i < cpu_count) : (i += 1) out[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }
    return need;
}

test "affinity mask: unpinned covers every configured CPU, pinned only its own" {
    const std = @import("std");
    var m: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, -1, 1, 128));
    try std.testing.expectEqual(@as(u8, 0x01), m[0]);
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, -1, 8, 128));
    try std.testing.expectEqual(@as(u8, 0xff), m[0]);
    try std.testing.expectEqual(@as(u8, 0), m[1]);
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, -1, 4, 8));
    try std.testing.expectEqual(@as(u8, 0x0f), m[0]);
    // pinned to CPU 3 of 8
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 3, 8, 128));
    try std.testing.expectEqual(@as(u8, 0x08), m[0]);
    // more than 64 CPUs need a second word
    try std.testing.expectEqual(@as(?usize, 16), buildMask(&m, -1, 65, 128));
    try std.testing.expectEqual(@as(u8, 0xff), m[7]);
    try std.testing.expectEqual(@as(u8, 0x01), m[8]);
    // a size that is not a multiple of 8 is EINVAL, whatever its value (measured: 7, 9, 15, 127, 129)
    for ([_]u64{ 7, 9, 15, 127, 129 }) |bad| try std.testing.expectEqual(@as(?usize, null), buildMask(&m, -1, 4, bad));
    // a larger multiple of 8 is fine and still reports only the mask's own length
    for ([_]u64{ 16, 128, 200 }) |ok| try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, -1, 4, ok));
    // a buffer smaller than the mask is refused (Linux: EINVAL), even for a pinned task
    try std.testing.expectEqual(@as(?usize, null), buildMask(&m, -1, 4, 4));
    try std.testing.expectEqual(@as(?usize, null), buildMask(&m, 0, 4, 0));
    try std.testing.expectEqual(@as(?usize, null), buildMask(&m, -1, 65, 8));
    // a pin outside the configured CPUs (cannot happen, but must not index out of range) falls back to "all"
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 9, 4, 8));
    try std.testing.expectEqual(@as(u8, 0x0f), m[0]);
}
