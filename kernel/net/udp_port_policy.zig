//! Pure UDP port-sharing policy: when two sockets may hold the same local port, and which of them receives a datagram that arrives for it.
//! Host-testable (no arch deps); callers in udp.zig hold udp_lock and pass snapshots of the per-slot options.

const std = @import("std");
const tcp_port_policy = @import("tcp_port_policy.zig");

pub const REUSEADDR_FLAG: u16 = 1;
pub const REUSEPORT_FLAG: u16 = tcp_port_policy.REUSEPORT_FLAG;

/// A socket may join a port another socket already holds when both set SO_REUSEADDR, or both set SO_REUSEPORT and share an effective uid.
pub fn mayShare(new_flags: u16, holder_flags: u16, new_uid: u32, holder_uid: u32) bool {
    if ((new_flags & REUSEADDR_FLAG) != 0 and (holder_flags & REUSEADDR_FLAG) != 0) return true;
    return tcp_port_policy.reusePortMayShare(new_flags, holder_flags, new_uid, holder_uid);
}

fn hashPeer(src_ip: [16]u8, src_port: u16) u32 {
    var h: u32 = 2166136261;
    for (src_ip) |b| h = (h ^ b) *% 16777619;
    h = (h ^ (src_port & 0xff)) *% 16777619;
    h = (h ^ (src_port >> 8)) *% 16777619;
    h ^= h >> 15;
    h *%= 2246822519;
    h ^= h >> 13;
    return h;
}

/// Index (into the candidate arrays) of the `rank`-th candidate in ascending bind order.
fn nthByBindOrder(seqs: []const u32, rank: usize) usize {
    var seen: usize = 0;
    var best: usize = 0;
    var last: ?u32 = null;
    while (seen <= rank) : (seen += 1) {
        var pick: ?usize = null;
        for (seqs, 0..) |s, i| {
            if (last) |l| if (s <= l) continue;
            if (pick == null or s < seqs[pick.?]) pick = i;
        }
        best = pick orelse return best;
        last = seqs[best];
    }
    return best;
}

/// Which socket of `flags.len` same-port candidates takes a datagram from this peer. When every candidate set SO_REUSEPORT the choice is a
/// stable hash of the peer address and port (the same peer always reaches the same socket); otherwise the most recently bound socket wins,
/// as with SO_REUSEADDR on Linux. `seqs` is the bind order of each candidate (larger = bound later).
pub fn pickReceiver(flags: []const u16, seqs: []const u32, src_ip: [16]u8, src_port: u16) usize {
    const n = flags.len;
    if (n <= 1) return 0;
    var all_reuseport = true;
    for (flags) |f| {
        if ((f & REUSEPORT_FLAG) == 0) all_reuseport = false;
    }
    if (all_reuseport) {
        return nthByBindOrder(seqs, hashPeer(src_ip, src_port) % n);
    }
    return nthByBindOrder(seqs, n - 1);
}

/// One socket on the shared port, as the receiver choice sees it.
pub const Candidate = struct {
    flags: u16,
    seq: u32,
    /// Peer fixed by connect(): port 0 when the socket is unconnected.
    peer_port: u16 = 0,
    peer_ip: [16]u8 = @splat(0),
};

/// Which candidate takes a datagram from (src_ip, src_port), or null when none may. A socket connect()ed to exactly that sender wins outright
/// (Linux scores the full match highest); a connected socket never takes a datagram from anyone else; among the unconnected ones the
/// SO_REUSEPORT hash / newest-bound rule of pickReceiver applies.
pub fn pickReceiverConnected(cands: []const Candidate, src_ip: [16]u8, src_port: u16) ?usize {
    for (cands, 0..) |c, i| {
        if (c.peer_port != 0 and c.peer_port == src_port and std.mem.eql(u8, &c.peer_ip, &src_ip)) return i;
    }
    var flags: [64]u16 = undefined;
    var seqs: [64]u32 = undefined;
    var map: [64]usize = undefined;
    var n: usize = 0;
    for (cands, 0..) |c, i| {
        if (c.peer_port != 0) continue;
        if (n == flags.len) break;
        flags[n] = c.flags;
        seqs[n] = c.seq;
        map[n] = i;
        n += 1;
    }
    if (n == 0) return null;
    return map[pickReceiver(flags[0..n], seqs[0..n], src_ip, src_port)];
}


// ── autobind (inet_autobind, __udp_disconnect) ──

/// Largest discriminator a socket key carries (bits 16..30; bit 31 marks a ping socket, see udp.PING_KEY).
pub const MAX_DISC: u16 = 0x7fff;

/// The smallest discriminator not in `used` (the ones the sockets already on a port hold), so every key stays unique however many
/// sockets share the port. Null when all MAX_DISC + 1 are taken.
pub fn firstFreeDisc(used: []const u16) ?u16 {
    var d: u32 = 0;
    while (d <= MAX_DISC) : (d += 1) {
        if (std.mem.indexOfScalar(u16, used, @intCast(d)) == null) return @intCast(d);
    }
    return null;
}

pub const EPHEMERAL_LOW: u16 = 49152;
pub const EPHEMERAL_HIGH: u16 = 65535;

/// The port an unnamed socket takes when bind with port 0, connect or a send names it (inet_autobind → udp_lib_get_port(sk, 0)):
/// the one socket() reserved for it, `current`, unless a named socket now holds that number (someone bound it while this socket had
/// no name), else the first ephemeral port no named socket holds. `named` lists the port numbers of the named sockets. Null when
/// every ephemeral port is held (EAGAIN).
pub fn pickAutobindPort(current: u16, named: []const u16) ?u16 {
    return pickAutobindPortInRange(current, named, 0, tcp_port_policy.EPHEMERAL_RANGE);
}

pub fn pickAutobindPortInRange(current: u16, named: []const u16, raw_range: u32, system_range: u32) ?u16 {
    const range = tcp_port_policy.localPortRange(raw_range, system_range);
    if (current >= range.first and current <= range.last and std.mem.indexOfScalar(u16, named, current) == null) return current;
    var p: u32 = range.first;
    while (p <= range.last) : (p += 1) {
        if (std.mem.indexOfScalar(u16, named, @intCast(p)) == null) return @intCast(p);
    }
    return null;
}

/// Whether connect(AF_UNSPEC) keeps the socket's port: only a port the user chose with bind (SOCK_BINDPORT_LOCK); one picked by
/// bind with port 0, connect or a send is given up and getsockname names port 0 again. The bound address is kept either way.
pub fn disconnectKeepsPort(user_chose_port: bool) bool {
    return user_chose_port;
}
