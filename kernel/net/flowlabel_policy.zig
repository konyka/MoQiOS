//! IPv6 automatic flow labels (Linux ip6_make_flowlabel with net.ipv6.auto_flowlabels = 1, IP6_AUTO_FLOW_LABEL_OPTOUT, the
//! default): a packet whose sender gave no label gets one hashed from the flow (addresses, ports, protocol) under a per-boot
//! secret, so every packet of one flow carries the same label and different flows usually differ. A socket opts out with
//! IPV6_AUTOFLOWLABEL 0. Pure, host-tested.

const std = @import("std");

pub const IPV6_AUTOFLOWLABEL: u64 = 70;

/// The 20-bit label of the flow `src` → `dst`, ports `sport` / `dport`, protocol `proto`, under `secret` (never 0 — a 0 label
/// means "none").
pub fn autoLabel(src: [16]u8, dst: [16]u8, sport: u16, dport: u16, proto: u8, secret: [16]u8) u32 {
    var h = std.crypto.auth.siphash.SipHash64(2, 4).init(&secret);
    h.update(&src);
    h.update(&dst);
    var tail: [5]u8 = undefined;
    std.mem.writeInt(u16, tail[0..2], sport, .big);
    std.mem.writeInt(u16, tail[2..4], dport, .big);
    tail[4] = proto;
    h.update(&tail);
    const v = h.finalInt();
    // ip6_make_flowlabel: rol32(hash, 16) & IPV6_FLOWLABEL_MASK.
    const folded: u32 = @truncate(v ^ (v >> 32));
    const l = std.math.rotl(u32, folded, 16) & 0xFFFFF;
    return if (l == 0) 1 else l;
}

test "a flow keeps its label; another flow gets another; never 0" {
    var a: [16]u8 = @splat(0);
    a[15] = 1;
    const k: [16]u8 = @splat(7);
    const l1 = autoLabel(a, a, 1000, 2000, 17, k);
    try std.testing.expectEqual(l1, autoLabel(a, a, 1000, 2000, 17, k));
    try std.testing.expect(l1 != autoLabel(a, a, 1001, 2000, 17, k));
    try std.testing.expect(l1 != 0 and l1 <= 0xFFFFF);
}
