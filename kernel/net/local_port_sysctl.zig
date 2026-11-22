//! net.ipv4.ip_local_port_range (ipv4_local_port_range): the system UDP/TCP automatic-port range.
//! Socket IP_LOCAL_PORT_RANGE narrowing remains in tcp_port_policy, which receives this value explicitly.

const devconf = @import("devconf_policy.zig");
const tcp = @import("tcp_port_policy.zig");

var current: u32 = tcp.EPHEMERAL_RANGE;

pub fn get() u32 {
    return @atomicLoad(u32, &current, .monotonic);
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
    if (low < 1024 or high < low or high > 65535) return -22;
    @atomicStore(u32, &current, @as(u32, @intCast(low)) | (@as(u32, @intCast(high)) << 16), .monotonic);
    return first.ret + second_ret;
}
