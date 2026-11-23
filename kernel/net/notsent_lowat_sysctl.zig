//! net.ipv4.tcp_notsent_lowat (proc_douintvec, default UINT_MAX): the TCP_NOTSENT_LOWAT a socket uses while its own is 0.

const std = @import("std");
const devconf = @import("devconf_policy.zig");

var current: u32 = std.math.maxInt(u32);

pub fn get() u32 {
    return @atomicLoad(u32, &current, .monotonic);
}

/// One unsigned int; a negative, oversized or malformed write is EINVAL and leaves the value.
pub fn write(text: []const u8) i64 {
    const parsed = devconf.writeUint(text);
    if (parsed.value) |v| @atomicStore(u32, &current, v, .monotonic);
    return parsed.ret;
}

pub fn format(out: []u8) usize {
    const s = std.fmt.bufPrint(out, "{d}\n", .{get()}) catch return 0;
    return s.len;
}
