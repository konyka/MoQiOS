//! The capget/capset/status view of a task's capabilities. The kernel keeps them as the packed `SysCap` flags; user space (libcap, /proc/<pid>/status)
//! speaks Linux's numbering: CAP_CHOWN 0, CAP_DAC_OVERRIDE 1, CAP_FOWNER 3, CAP_KILL 5, CAP_SETGID 6, CAP_SETUID 7, ... CAP_SYS_TIME 25, CAP_MKNOD 27.
//! Capabilities the kernel does not model (CAP_SETPCAP, CAP_FSETID, ...) are never reported and can never be requested.
//!
//! `cap_sys_mount` is the kernel's own split of CAP_SYS_ADMIN (Linux mount needs CAP_SYS_ADMIN), so both are reported as bit 21. Asking for bit 21
//! back through `decode` only restores the flags the caller already held, so a process that holds just the mount flag cannot turn it into
//! cap_sys_admin by writing its own capabilities back.
const std = @import("std");
const SysCap = @import("capability_profile.zig").SysCap;

pub const V1: u32 = 0x19980330;
pub const V2: u32 = 0x20071026;
pub const V3: u32 = 0x20080522;

/// The bounding set Linux shows for a process that never dropped from it: CAP_CHOWN (0) to CAP_CHECKPOINT_RESTORE (40). The kernel has no
/// bounding set, so every task reports this.
pub const BOUNDING: u64 = 0x0000_01ff_ffff_ffff;

const Entry = struct { field: []const u8, number: u6 };

const table = [_]Entry{
    .{ .field = "cap_chown", .number = 0 },
    .{ .field = "cap_dac_override", .number = 1 },
    .{ .field = "cap_fowner", .number = 3 },
    .{ .field = "cap_kill", .number = 5 },
    .{ .field = "cap_setgid", .number = 6 },
    .{ .field = "cap_setuid", .number = 7 },
    .{ .field = "cap_net_bind", .number = 10 },
    .{ .field = "cap_net_admin", .number = 12 },
    .{ .field = "cap_net_raw", .number = 13 },
    .{ .field = "cap_ipc_lock", .number = 14 },
    .{ .field = "cap_sys_rawio", .number = 17 },
    .{ .field = "cap_sys_ptrace", .number = 19 },
    .{ .field = "cap_sys_admin", .number = 21 },
    .{ .field = "cap_sys_mount", .number = 21 },
    .{ .field = "cap_sys_reboot", .number = 22 },
    .{ .field = "cap_sys_nice", .number = 23 },
    .{ .field = "cap_sys_resource", .number = 24 },
    .{ .field = "cap_sys_time", .number = 25 },
    .{ .field = "cap_mknod", .number = 27 },
};

/// The flags as a Linux capability bitmask.
pub fn encode(c: SysCap) u64 {
    var bits: u64 = 0;
    inline for (table) |e| {
        if (@field(c, e.field)) bits |= @as(u64, 1) << e.number;
    }
    return bits;
}

/// The flags a Linux bitmask names, limited to those in `allowed` (the set the caller may draw from; see the module comment for bit 21).
pub fn decode(bits: u64, allowed: SysCap) SysCap {
    var c: SysCap = .{};
    inline for (table) |e| {
        if ((bits >> e.number) & 1 != 0 and @field(allowed, e.field)) @field(c, e.field) = true;
    }
    return c;
}

pub fn union_(a: SysCap, b: SysCap) SysCap {
    return @bitCast(@as(u32, @bitCast(a)) | @as(u32, @bitCast(b)));
}

/// How many 32-bit words per set the header version uses (V1 has one, V2 and V3 two), or null for an unknown version.
pub fn wordsFor(version: u32) ?usize {
    return switch (version) {
        V1 => 1,
        V2, V3 => 2,
        else => null,
    };
}

pub fn low(bits: u64) u32 {
    return @truncate(bits);
}

pub fn high(bits: u64) u32 {
    return @truncate(bits >> 32);
}

test "cap abi: the kernel flags use Linux numbers" {
    const c: SysCap = .{ .cap_setuid = true, .cap_setgid = true };
    try std.testing.expectEqual(@as(u64, 0xc0), encode(c));
    try std.testing.expectEqual(@as(u64, 1 << 5), encode(.{ .cap_kill = true }));
    try std.testing.expectEqual(@as(u64, 1 << 13), encode(.{ .cap_net_raw = true }));
    try std.testing.expectEqual(@as(u64, 1 << 21), encode(.{ .cap_sys_admin = true }));
    try std.testing.expectEqual(@as(u64, 0), encode(.{}));
}

test "cap abi: every flag has a number and the numbers round-trip" {
    const all = @import("capability_profile.zig").ALL_CAPS;
    const bits = encode(all);
    try std.testing.expect(bits != 0);
    try std.testing.expectEqual(@as(u32, @bitCast(all)), @as(u32, @bitCast(decode(bits, all))));
    inline for (@typeInfo(SysCap).@"struct".fields) |f| {
        if (f.type != bool) continue;
        var one: SysCap = .{};
        @field(one, f.name) = true;
        try std.testing.expect(encode(one) != 0);
        try std.testing.expectEqual(@as(u32, @bitCast(one)), @as(u32, @bitCast(decode(encode(one), one))));
    }
}

test "cap abi: bit 21 only restores the flags the caller already held" {
    const mount_only: SysCap = .{ .cap_sys_mount = true };
    const back = decode(1 << 21, mount_only);
    try std.testing.expect(back.cap_sys_mount);
    try std.testing.expect(!back.cap_sys_admin);
    const both = decode(1 << 21, .{ .cap_sys_mount = true, .cap_sys_admin = true });
    try std.testing.expect(both.cap_sys_mount and both.cap_sys_admin);
    // A number the kernel does not model is dropped, and so is one outside the allowed set.
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(decode(1 << 8, mount_only))));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(decode(1 << 7, mount_only))));
}

test "cap abi: header versions and word split" {
    try std.testing.expectEqual(@as(?usize, 1), wordsFor(V1));
    try std.testing.expectEqual(@as(?usize, 2), wordsFor(V2));
    try std.testing.expectEqual(@as(?usize, 2), wordsFor(V3));
    try std.testing.expectEqual(@as(?usize, null), wordsFor(0x12345));
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), low(0x1_deadbeef));
    try std.testing.expectEqual(@as(u32, 1), high(0x1_deadbeef));
    try std.testing.expectEqual(@as(u64, 0x1ffffffffff), BOUNDING);
}
