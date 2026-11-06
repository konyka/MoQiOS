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

pub const SetResult = union(enum) { pin: i16, err: i64 };

/// What sched_setaffinity makes of a user mask for a machine with `cpu_count` CPUs. Measured on Linux (raw syscall, 4 CPUs allowed):
/// the size may be any non-zero number of bytes (3, 129, 200 all work: only the first 128 are read and missing bytes count as 0),
/// bits for CPUs that do not exist are ignored when a real CPU is also named, and a mask that names no existing CPU is EINVAL.
/// The scheduler can only keep one pin per task, so: a mask that names every configured CPU removes the pin (-1: the task may run
/// anywhere, and sched_getaffinity then reports every CPU, as Linux does); any other non-empty set pins to its lowest CPU. That second
/// rule is a known limit: a two-CPU subset is narrowed to its first CPU.
pub fn affinityFromMask(mask: []const u8, cpu_count: u32) SetResult {
    if (mask.len == 0) return .{ .err = -22 }; // EINVAL
    const n: u32 = @max(cpu_count, 1);
    var lowest: i32 = -1;
    var named: u32 = 0;
    var cpu: u32 = 0;
    while (cpu < n) : (cpu += 1) {
        const byte = cpu / 8;
        if (byte >= mask.len) break;
        if ((mask[byte] >> @intCast(cpu % 8)) & 1 != 0) {
            if (lowest < 0) lowest = @intCast(cpu);
            named += 1;
        }
    }
    if (named == 0) return .{ .err = -22 };
    if (named == n) return .{ .pin = -1 };
    return .{ .pin = @intCast(lowest) };
}

test "setaffinity mask: all CPUs unpins, a subset pins to its lowest, nothing real is EINVAL" {
    const std = @import("std");
    // every one of 4 CPUs (extra high bits are ignored)
    try std.testing.expectEqual(@as(i16, -1), affinityFromMask(&[_]u8{0x0f}, 4).pin);
    try std.testing.expectEqual(@as(i16, -1), affinityFromMask(&[_]u8{ 0xff, 0xff }, 4).pin);
    try std.testing.expectEqual(@as(i16, -1), affinityFromMask(&[_]u8{0xff}, 8).pin);
    // one CPU of one is "all": the single-CPU machine stays unpinned
    try std.testing.expectEqual(@as(i16, -1), affinityFromMask(&[_]u8{0x01}, 1).pin);
    // subsets: the lowest CPU
    try std.testing.expectEqual(@as(i16, 1), affinityFromMask(&[_]u8{0x02}, 4).pin);
    try std.testing.expectEqual(@as(i16, 2), affinityFromMask(&[_]u8{0x0c}, 4).pin);
    try std.testing.expectEqual(@as(i16, 0), affinityFromMask(&[_]u8{0x01}, 4).pin);
    try std.testing.expectEqual(@as(i16, 0), affinityFromMask(&[_]u8{0x07}, 4).pin);
    // a CPU that does not exist is ignored when a real one is named too ({1,60} on a 4-CPU machine pins to 1)
    try std.testing.expectEqual(@as(i16, 1), affinityFromMask(&[_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0x10 }, 4).pin);
    // ... and a mask that names no existing CPU is EINVAL (only CPU 60, only CPUs 20..30, only CPU 64)
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0x10 }, 4).err);
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0xf0, 0xff, 0x07 }, 4).err);
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 4).err);
    // empty mask and zero size are EINVAL
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0, 0 }, 4).err);
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{}, 4).err);
    // a short mask: missing bytes count as 0 ({0,1} in one byte on 4 CPUs is a subset, so it pins to 0)
    try std.testing.expectEqual(@as(i16, 0), affinityFromMask(&[_]u8{0x03}, 4).pin);
    // 70 CPUs: all of them (two words) unpin, a missing high word means a subset
    var full: [9]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(i16, -1), affinityFromMask(&full, 70).pin);
    try std.testing.expectEqual(@as(i16, 0), affinityFromMask(full[0..8], 70).pin);
}
