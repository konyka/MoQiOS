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
