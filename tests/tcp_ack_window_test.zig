const std = @import("std");
const tu = @import("kernel_shared").tcp_util;

// hello174 C: after an RTO the send cursor (snd_nxt) is rewound to the first hole, but the peer can still acknowledge everything that was
// sent before the rewind (up to snd_max). Linux tcp_ack accepts any ACK up to tp->snd_nxt, which never moves below what was sent; here
// that bound is snd_max. An ACK above the rewound snd_nxt but within snd_max must count, or the connection stalls with data queued.
test "a cumulative ACK beyond the rewound snd_nxt but within snd_max is accepted (hello174)" {
    const una: u32 = 1000;
    const nxt: u32 = 1000 + 1448; // rewound: one segment resent
    const max: u32 = 1000 + 40000; // everything sent before the RTO
    try std.testing.expectEqual(@as(u32, 20000), tu.ackAdvance(una + 20000, una, nxt, max).?);
    try std.testing.expectEqual(@as(u32, 40000), tu.ackAdvance(max, una, nxt, max).?);
    try std.testing.expectEqual(@as(u32, 1448), tu.ackAdvance(nxt, una, nxt, max).?);
    // Beyond anything sent, a duplicate, or an old ACK: no advance.
    try std.testing.expectEqual(@as(?u32, null), tu.ackAdvance(max + 1, una, nxt, max));
    try std.testing.expectEqual(@as(?u32, null), tu.ackAdvance(una, una, nxt, max));
    try std.testing.expectEqual(@as(?u32, null), tu.ackAdvance(una -% 1, una, nxt, max));
    // Without a rewind snd_max == snd_nxt and the bound is the same as before.
    try std.testing.expectEqual(@as(?u32, null), tu.ackAdvance(nxt + 1, una, nxt, nxt));
    // Sequence wrap.
    const w: u32 = 0xffff_f000;
    try std.testing.expectEqual(@as(u32, 0x2000), tu.ackAdvance(w +% 0x2000, w, w +% 0x100, w +% 0x3000).?);
}

// TCP_NOTSENT_LOWAT / SIOCOUTQNSD count write_seq - snd_nxt, and Linux's snd_nxt never moves back on a retransmission: bytes already
// sent once are not "unsent" while they wait to be resent (hello416 limitation 1). Here that is the ring past snd_max.
test "unsent bytes are those past snd_max, not past the rewound send cursor (hello416)" {
    // 10000 bytes queued from snd_una, 6000 sent before an RTO rewound snd_nxt to snd_una: 4000 unsent, not 10000.
    try std.testing.expectEqual(@as(u32, 4000), tu.unsentBytes(10000, 1000, 1000, 7000));
    // No rewind: snd_max == snd_nxt.
    try std.testing.expectEqual(@as(u32, 4000), tu.unsentBytes(10000, 1000, 7000, 7000));
    // Everything sent; and a FIN counted in snd_max past the ring never makes it negative.
    try std.testing.expectEqual(@as(u32, 0), tu.unsentBytes(6000, 1000, 1000, 7000));
    try std.testing.expectEqual(@as(u32, 0), tu.unsentBytes(6000, 1000, 7001, 7001));
    // Wrap.
    try std.testing.expectEqual(@as(u32, 0x100), tu.unsentBytes(0x300, 0xffff_ff00, 0xffff_ff00, 0x100));
}
