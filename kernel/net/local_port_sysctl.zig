//! net.ipv4.ip_local_port_range and ip_unprivileged_port_start, including their non-overlap checks.
//! Socket IP_LOCAL_PORT_RANGE narrowing remains in tcp_port_policy, which receives the system range explicitly.

const devconf = @import("devconf_policy.zig");
const tcp = @import("tcp_port_policy.zig");

var current: u32 = tcp.EPHEMERAL_RANGE;
var unprivileged_start: u32 = 1024;

pub fn get() u32 {
    return @atomicLoad(u32, &current, .monotonic);
}

pub fn unprivilegedStart() u32 {
    return @atomicLoad(u32, &unprivileged_start, .monotonic);
}

/// ipv4_privileged_ports: accept 0..65535 only when the automatic range starts at or above the new threshold.
pub fn writeUnprivilegedStart(text: []const u8) i64 {
    const parsed = devconf.writeInt(text);
    if (parsed.value) |value| {
        if (value < 0 or value > 65535 or (get() & 0xffff) < @as(u32, @intCast(value))) return -22;
        @atomicStore(u32, &unprivileged_start, @intCast(value), .monotonic);
    }
    return parsed.ret;
}

/// Parse at most two integers, preserving the old high endpoint when only one is present. Commit only after both pass
/// proc_dointvec_minmax's u16 range and ipv4_local_port_range's high >= low >= ip_unprivileged_port_start checks.
pub fn write(text: []const u8) i64 {
    if (text.len == 0) return 0;
    const first = devconf.writeInt(text);
    const low = first.value orelse return first.ret;
    const used: usize = @intCast(first.ret);
    var high: i32 = @intCast(get() >> 16);
    var second_ret: i64 = 0;
    if (used < text.len) {
        const second = devconf.writeInt(text[used..]);
        if (second.value) |value| {
            high = value;
        } else if (second.ret != 0) {
            return second.ret;
        }
        second_ret = second.ret;
    }
    if (low < 0 or high < low or high > 65535 or low < @as(i32, @intCast(unprivilegedStart()))) return -22;
    @atomicStore(u32, &current, @as(u32, @intCast(low)) | (@as(u32, @intCast(high)) << 16), .monotonic);
    return first.ret + second_ret;
}
