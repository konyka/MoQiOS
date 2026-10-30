//! UTS names (uname/sethostname/setdomainname) shared by every entry point.
//!
//! struct utsname is six 65-byte NUL-padded fields: sysname, nodename,
//! release, version, machine, domainname. nodename and domainname are the
//! mutable hostname and domainname.

pub const FIELD: usize = 65;
pub const FIELDS: usize = 6;
pub const UNAME_SIZE: usize = FIELD * FIELDS;
pub const MAX_NAME: u32 = 64;

pub const SYSNAME = "MoQiOS";
pub const RELEASE = "0.1.0";
pub const VERSION = "MoQiOS 0.1.0";
pub const MACHINE = "x86_64";
pub const DEFAULT_HOSTNAME = "moqios";

pub var hostname: [MAX_NAME]u8 = @splat(0);
pub var hostname_len: u32 = 0;
pub var domainname: [MAX_NAME]u8 = @splat(0);
pub var domainname_len: u32 = 0;
var initialised: bool = false;

/// The hostname starts as DEFAULT_HOSTNAME; an explicit empty name set later
/// stays empty (hostname_len == 0 alone cannot tell the two apart).
pub fn ensureInit() void {
    if (initialised) return;
    initialised = true;
    @memcpy(hostname[0..DEFAULT_HOSTNAME.len], DEFAULT_HOSTNAME);
    hostname_len = DEFAULT_HOSTNAME.len;
}

pub fn nameLenValid(len: u32) bool {
    return len <= MAX_NAME;
}

/// The 390-byte utsname image for the given names (each clamped to 64 bytes).
pub fn unameBytes(host: []const u8, domain: []const u8) [UNAME_SIZE]u8 {
    var out: [UNAME_SIZE]u8 = @splat(0);
    const fields = [FIELDS][]const u8{ SYSNAME, host, RELEASE, VERSION, MACHINE, domain };
    for (fields, 0..) |f, i| {
        const n = @min(f.len, MAX_NAME);
        @memcpy(out[i * FIELD ..][0..n], f[0..n]);
    }
    return out;
}

pub fn currentUname() [UNAME_SIZE]u8 {
    ensureInit();
    return unameBytes(hostname[0..hostname_len], domainname[0..domainname_len]);
}

test "uname image carries the mutable names in the right fields" {
    const std = @import("std");
    const b = unameBytes("box", "lan");
    try std.testing.expectEqualStrings("MoQiOS", std.mem.sliceTo(b[0..FIELD], 0));
    try std.testing.expectEqualStrings("box", std.mem.sliceTo(b[FIELD .. 2 * FIELD], 0));
    try std.testing.expectEqualStrings("x86_64", std.mem.sliceTo(b[4 * FIELD .. 5 * FIELD], 0));
    try std.testing.expectEqualStrings("lan", std.mem.sliceTo(b[5 * FIELD .. 6 * FIELD], 0));
    const empty = unameBytes("", "");
    try std.testing.expectEqual(@as(u8, 0), empty[FIELD]);
    try std.testing.expectEqual(@as(u8, 0), empty[5 * FIELD]);
}

test "a 64-byte name fits its field with the NUL terminator" {
    const std = @import("std");
    const long: [64]u8 = @splat('h');
    const b = unameBytes(&long, "");
    try std.testing.expectEqual(@as(u8, 'h'), b[FIELD + 63]);
    try std.testing.expectEqual(@as(u8, 0), b[FIELD + 64]);
    try std.testing.expect(nameLenValid(64));
    try std.testing.expect(!nameLenValid(65));
}
