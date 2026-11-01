//! getsockopt(SOL_TCP) values that need encoding rules: TCP_INFO (the stable
//! prefix of Linux `struct tcp_info`), TCP_MAXSEG and TCP_CONGESTION.

const std = @import("std");

pub const TCP_MAXSEG: u64 = 2;
pub const TCP_INFO: u64 = 11;
pub const TCP_CONGESTION: u64 = 13;
pub const TCP_USER_TIMEOUT: u64 = 18;
pub const TCP_DEFER_ACCEPT: u64 = 9;
pub const TCP_SYNCNT: u64 = 7;
pub const TCP_LINGER2: u64 = 8;
pub const TCP_NOTSENT_LOWAT: u64 = 25;

/// Smallest MSS a TCP_MAXSEG set accepts and the largest (Linux: 88..=MAX_TCP_WINDOW-ish; we cap at the ring MSS).
pub const MAXSEG_MIN: u32 = 88;
pub const MAXSEG_MAX: u32 = 1460;

/// setsockopt(TCP_MAXSEG): a value outside the accepted range is EINVAL.
pub fn maxsegValid(v: u32) bool {
    return v >= MAXSEG_MIN and v <= MAXSEG_MAX;
}

/// The MSS getsockopt(TCP_MAXSEG) reports: the user's ceiling clamps the path MSS.
pub fn effectiveMss(path_mss: u32, user_cap: u32) u32 {
    return if (user_cap != 0 and user_cap < path_mss) user_cap else path_mss;
}

pub const CONGESTION_NAME = "cubic";

/// Linux numbers for `tcpi_state`.
pub const LinuxState = enum(u8) {
    established = 1,
    syn_sent = 2,
    syn_recv = 3,
    fin_wait1 = 4,
    fin_wait2 = 5,
    time_wait = 6,
    close = 7,
    close_wait = 8,
    last_ack = 9,
    listen = 10,
    closing = 11,
};

pub const Snapshot = struct {
    state: LinuxState = .close,
    retransmits: u8 = 0,
    ts: bool = false,
    sack: bool = false,
    wscale: bool = false,
    ecn: bool = false,
    snd_wscale: u4 = 0,
    rcv_wscale: u4 = 0,
    rto_us: u32 = 0,
    snd_mss: u32 = 0,
    rcv_mss: u32 = 0,
    unacked: u32 = 0,
    pmtu: u32 = 0,
    rtt_us: u32 = 0,
    rttvar_us: u32 = 0,
    snd_ssthresh: u32 = 0,
    snd_cwnd_segs: u32 = 0,
    rcv_space: u32 = 0,
};

/// Bytes of `struct tcp_info` written (everything through tcpi_rcv_space).
/// Linux callers pass a larger buffer and read the fields they know; a shorter
/// buffer gets a truncated copy.
pub const TCP_INFO_LEN: usize = 104;

/// Encode the snapshot as the head of struct tcp_info (little-endian, zeroed
/// elsewhere): u8 state, ca_state, retransmits, probes, backoff, options,
/// wscale byte, delivery byte; then u32 fields at the offsets Linux uses.
pub fn encode(s: Snapshot, out: *[TCP_INFO_LEN]u8) void {
    @memset(out, 0);
    out[0] = @intFromEnum(s.state);
    out[2] = s.retransmits;
    var opts: u8 = 0;
    if (s.ts) opts |= 1;
    if (s.sack) opts |= 2;
    if (s.wscale) opts |= 4;
    if (s.ecn) opts |= 8;
    out[5] = opts;
    // `snd_wscale : 4, rcv_wscale : 4` — the first declared bitfield is the low nibble.
    out[6] = (@as(u8, s.rcv_wscale) << 4) | @as(u8, s.snd_wscale);
    std.mem.writeInt(u32, out[8..12], s.rto_us, .little); // tcpi_rto
    std.mem.writeInt(u32, out[16..20], s.snd_mss, .little); // tcpi_snd_mss
    std.mem.writeInt(u32, out[20..24], s.rcv_mss, .little); // tcpi_rcv_mss
    std.mem.writeInt(u32, out[24..28], s.unacked, .little); // tcpi_unacked
    std.mem.writeInt(u32, out[60..64], s.pmtu, .little); // tcpi_pmtu
    std.mem.writeInt(u32, out[68..72], s.rtt_us, .little); // tcpi_rtt
    std.mem.writeInt(u32, out[72..76], s.rttvar_us, .little); // tcpi_rttvar
    std.mem.writeInt(u32, out[76..80], s.snd_ssthresh, .little); // tcpi_snd_ssthresh
    std.mem.writeInt(u32, out[80..84], s.snd_cwnd_segs, .little); // tcpi_snd_cwnd
    std.mem.writeInt(u32, out[84..88], s.snd_mss, .little); // tcpi_advmss
    std.mem.writeInt(u32, out[88..92], 0, .little); // tcpi_reordering
    std.mem.writeInt(u32, out[96..100], s.rcv_space, .little); // tcpi_rcv_space
}

const TcpState = @import("tcp_recv_policy.zig").TcpState;

/// Our connection state as Linux numbers it (`TCP_ESTABLISHED` = 1 ... `TCP_CLOSING` = 11).
pub fn linuxState(s: TcpState) LinuxState {
    return switch (s) {
        .closed => .close,
        .syn_sent => .syn_sent,
        .syn_received => .syn_recv,
        .established => .established,
        .fin_wait_1 => .fin_wait1,
        .fin_wait_2 => .fin_wait2,
        .closing => .closing,
        .time_wait => .time_wait,
        .close_wait => .close_wait,
        .last_ack => .last_ack,
        .listen => .listen,
    };
}

pub fn msToUs(ms: u32) u32 {
    return ms *| 1000;
}

pub fn cwndSegments(cwnd_bytes: u32, mss: u32) u32 {
    return cwnd_bytes / @max(mss, 1);
}
