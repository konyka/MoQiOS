//! Pure formatting of the TCB table snapshot behind /proc/tcpstats: how many slots are in each connection state, how many are
//! unreferenced leftovers, and two counters that say whether a full table has hurt anyone (SYNs dropped for lack of a slot, TIME_WAIT
//! slots given away). Host-testable; tcp.zig takes the snapshot under tcp_lock.

pub const STATE_COUNT = 11;

pub const state_names = [STATE_COUNT][]const u8{ "closed", "syn_sent", "syn_received", "established", "fin_wait_1", "fin_wait_2", "closing", "time_wait", "close_wait", "last_ack", "listen" };

pub const Stats = struct {
    per_state: [STATE_COUNT]u32 = @splat(0),
    /// Active slots no descriptor references (ref_count == 0): finished connections waiting for their timer.
    orphans: u32 = 0,
    active: u32 = 0,
    capacity: u32 = 0,
    /// SYNs a listener could not answer because every slot was taken.
    syn_dropped: u64 = 0,
    /// TIME_WAIT slots handed to a new connection on a full table.
    time_wait_evicted: u64 = 0,
};

/// "closed=N syn_sent=N ... listen=N orphans=N active=N capacity=N syn_dropped=N time_wait_evicted=N\n", cut off at the buffer's end.
pub fn format(s: Stats, buf: []u8) usize {
    var n: usize = 0;
    for (state_names, 0..) |name, i| {
        n = put(buf, n, if (i == 0) "" else " ");
        n = put(buf, n, name);
        n = put(buf, n, "=");
        n = putNum(buf, n, s.per_state[i]);
    }
    const tail = [_]struct { name: []const u8, value: u64 }{
        .{ .name = " orphans=", .value = s.orphans },
        .{ .name = " active=", .value = s.active },
        .{ .name = " capacity=", .value = s.capacity },
        .{ .name = " syn_dropped=", .value = s.syn_dropped },
        .{ .name = " time_wait_evicted=", .value = s.time_wait_evicted },
    };
    for (tail) |t| {
        n = put(buf, n, t.name);
        n = putNum(buf, n, t.value);
    }
    n = put(buf, n, "\n");
    return n;
}

fn put(buf: []u8, at: usize, text: []const u8) usize {
    var n = at;
    for (text) |c| {
        if (n == buf.len) return n;
        buf[n] = c;
        n += 1;
    }
    return n;
}

fn putNum(buf: []u8, at: usize, value: u64) usize {
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v = value;
    if (v == 0) {
        digits[0] = '0';
        d = 1;
    }
    while (v != 0) : (v /= 10) {
        digits[d] = '0' + @as(u8, @intCast(v % 10));
        d += 1;
    }
    var n = at;
    while (d > 0) {
        d -= 1;
        if (n == buf.len) return n;
        buf[n] = digits[d];
        n += 1;
    }
    return n;
}
