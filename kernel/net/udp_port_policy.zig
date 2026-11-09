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

