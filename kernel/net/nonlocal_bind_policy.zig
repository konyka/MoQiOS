//! net.ipv4.ip_nonlocal_bind and net.ipv6.ip_nonlocal_bind (proc_dou8vec_minmax).
//! Each network family has its own byte-sized switch; nonzero values permit nonlocal bind.

const devconf = @import("devconf_policy.zig");

pub const Family = enum { v4, v6 };

var values = [2]u8{ 0, 0 };

fn index(family: Family) usize {
    return if (family == .v4) 0 else 1;
}

pub fn get(family: Family) u8 {
    return @atomicLoad(u8, &values[index(family)], .monotonic);
}

pub fn allows(family: Family) bool {
    return get(family) != 0;
}

/// One offset-zero write. An out-of-range or malformed value is EINVAL and leaves the old value unchanged.
pub fn write(family: Family, text: []const u8) i64 {
    const parsed = devconf.writeInt(text);
    if (parsed.value) |value| {
        if (value < 0 or value > 255) return -22;
        @atomicStore(u8, &values[index(family)], @intCast(value), .monotonic);
    }
    return parsed.ret;
}
