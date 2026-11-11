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

/// The affinity mask sched_getaffinity reports: the task's allowed CPUs (`mask`, 0 = unrestricted) limited to the configured ones, or every
/// configured CPU when it is unrestricted. `out` is zeroed first; the result is the byte count Linux returns, which is the size of the
/// kernel's CPU mask rounded up to a multiple of 8 and at most the caller's `cpusetsize`. Returns null when `cpusetsize` is too small to
/// hold the mask for the configured CPUs (Linux: EINVAL).
pub fn buildMask(out: []u8, mask: u64, cpu_count: u32, cpusetsize: u64) ?usize {
    @memset(out, 0);
    // Bytes needed for CPU ids 0..cpu_count-1, rounded up to a whole 8-byte word like the kernel's cpumask.
    const need: usize = @intCast(((@as(u64, @max(cpu_count, 1)) + 63) / 64) * 8);
    // Linux (measured with the raw call): the size must be a multiple of 8 (7, 9, 15, 127, 129 are EINVAL) and not less than the mask
    // (0, 1, 4 are EINVAL); a larger multiple of 8 (16, 128, 200) is fine and only `need` bytes are written and returned.
    if (cpusetsize < need or cpusetsize % 8 != 0 or need > out.len) return null;
    var named: u32 = 0;
    var i: u32 = 0;
    while (i < cpu_count and i < 64) : (i += 1) {
        if (mask != 0 and (mask >> @intCast(i)) & 1 != 0) {
            out[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            named += 1;
        }
    }
    if (named == 0) {
        // Unrestricted (or a mask with no configured CPU, which setaffinity never stores): every configured CPU.
        i = 0;
        while (i < cpu_count) : (i += 1) out[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }
    return need;
}

test "affinity mask: unrestricted covers every configured CPU, a mask only its own CPUs" {
    const std = @import("std");
    var m: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 0, 1, 128));
    try std.testing.expectEqual(@as(u8, 0x01), m[0]);
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 0, 8, 128));
    try std.testing.expectEqual(@as(u8, 0xff), m[0]);
    try std.testing.expectEqual(@as(u8, 0), m[1]);
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 0, 4, 8));
    try std.testing.expectEqual(@as(u8, 0x0f), m[0]);
    // CPU 3 of 8
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 1 << 3, 8, 128));
    try std.testing.expectEqual(@as(u8, 0x08), m[0]);
    // a subset {1,2} of 4 is reported whole
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 0b110, 4, 8));
    try std.testing.expectEqual(@as(u8, 0x06), m[0]);
    // {9} on 16 CPUs lands in the second byte
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 1 << 9, 16, 8));
    try std.testing.expectEqual(@as(u8, 0), m[0]);
    try std.testing.expectEqual(@as(u8, 0x02), m[1]);
    // more than 64 CPUs need a second word
    try std.testing.expectEqual(@as(?usize, 16), buildMask(&m, 0, 65, 128));
    try std.testing.expectEqual(@as(u8, 0xff), m[7]);
    try std.testing.expectEqual(@as(u8, 0x01), m[8]);
    // a size that is not a multiple of 8 is EINVAL, whatever its value (measured: 7, 9, 15, 127, 129)
    for ([_]u64{ 7, 9, 15, 127, 129 }) |bad| try std.testing.expectEqual(@as(?usize, null), buildMask(&m, 0, 4, bad));
    // a larger multiple of 8 is fine and still reports only the mask's own length
    for ([_]u64{ 16, 128, 200 }) |ok| try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 0, 4, ok));
    // a buffer smaller than the mask is refused (Linux: EINVAL)
    try std.testing.expectEqual(@as(?usize, null), buildMask(&m, 0, 4, 4));
    try std.testing.expectEqual(@as(?usize, null), buildMask(&m, 1, 4, 0));
    try std.testing.expectEqual(@as(?usize, null), buildMask(&m, 0, 65, 8));
    // a mask with no configured CPU (cannot be stored, but must not report nothing) falls back to "all"
    try std.testing.expectEqual(@as(?usize, 8), buildMask(&m, 1 << 9, 4, 8));
    try std.testing.expectEqual(@as(u8, 0x0f), m[0]);
}

pub const SetResult = union(enum) { mask: u64, err: i64 };

/// What sched_setaffinity makes of a user mask for a machine with `cpu_count` CPUs. Measured on Linux (raw syscall, 4 CPUs allowed):
/// the size may be any non-zero number of bytes (3, 129, 200 all work: only the first 128 are read and missing bytes count as 0),
/// bits for CPUs that do not exist are ignored when a real CPU is also named, and a mask that names no existing CPU is EINVAL.
/// The result is the set of named configured CPUs; naming every configured CPU is stored as 0 ("unrestricted"), so a task stays free to
/// use every CPU and sched_getaffinity reports all of them, as Linux does.
pub fn affinityFromMask(mask: []const u8, cpu_count: u32) SetResult {
    if (mask.len == 0) return .{ .err = -22 }; // EINVAL
    const n: u32 = @min(@max(cpu_count, 1), 64);
    var set: u64 = 0;
    var named: u32 = 0;
    var cpu: u32 = 0;
    while (cpu < n) : (cpu += 1) {
        const byte = cpu / 8;
        if (byte >= mask.len) break;
        if ((mask[byte] >> @intCast(cpu % 8)) & 1 != 0) {
            set |= @as(u64, 1) << @intCast(cpu);
            named += 1;
        }
    }
    if (named == 0) return .{ .err = -22 };
    if (named == n) return .{ .mask = 0 };
    return .{ .mask = set };
}

test "setaffinity mask: all CPUs is unrestricted, a subset is kept whole, nothing real is EINVAL" {
    const std = @import("std");
    // every one of 4 CPUs (extra high bits are ignored)
    try std.testing.expectEqual(@as(u64, 0), affinityFromMask(&[_]u8{0x0f}, 4).mask);
    try std.testing.expectEqual(@as(u64, 0), affinityFromMask(&[_]u8{ 0xff, 0xff }, 4).mask);
    try std.testing.expectEqual(@as(u64, 0), affinityFromMask(&[_]u8{0xff}, 8).mask);
    // one CPU of one is "all": the single-CPU machine stays unrestricted
    try std.testing.expectEqual(@as(u64, 0), affinityFromMask(&[_]u8{0x01}, 1).mask);
    // subsets are kept whole
    try std.testing.expectEqual(@as(u64, 0b0010), affinityFromMask(&[_]u8{0x02}, 4).mask);
    try std.testing.expectEqual(@as(u64, 0b1100), affinityFromMask(&[_]u8{0x0c}, 4).mask);
    try std.testing.expectEqual(@as(u64, 0b0001), affinityFromMask(&[_]u8{0x01}, 4).mask);
    try std.testing.expectEqual(@as(u64, 0b0111), affinityFromMask(&[_]u8{0x07}, 4).mask);
    // a CPU that does not exist is ignored when a real one is named too ({1,60} on a 4-CPU machine is {1})
    try std.testing.expectEqual(@as(u64, 0b0010), affinityFromMask(&[_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0x10 }, 4).mask);
    // ... and a mask that names no existing CPU is EINVAL (only CPU 60, only CPUs 20..30, only CPU 64)
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0x10 }, 4).err);
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0xf0, 0xff, 0x07 }, 4).err);
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 4).err);
    // empty mask and zero size are EINVAL
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{ 0, 0, 0, 0 }, 4).err);
    try std.testing.expectEqual(@as(i64, -22), affinityFromMask(&[_]u8{}, 4).err);
    // a short mask: missing bytes count as 0
    try std.testing.expectEqual(@as(u64, 0b0011), affinityFromMask(&[_]u8{0x03}, 4).mask);
    // 16 CPUs: {9} is in the second byte
    try std.testing.expectEqual(@as(u64, 1 << 9), affinityFromMask(&[_]u8{ 0, 0x02 }, 16).mask);
    // every one of 64 CPUs is unrestricted; one missing is a subset
    var full: [8]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(u64, 0), affinityFromMask(&full, 64).mask);
    full[7] = 0x7f;
    try std.testing.expectEqual(~@as(u64, 0) >> 1, affinityFromMask(&full, 64).mask);
}
