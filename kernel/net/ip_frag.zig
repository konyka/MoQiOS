//! IPv4 fragment reassembly (Linux ip_defrag): the queues of ip_frag_policy behind one lock. A fragment whose header checks out is
//! queued by (source, destination, id, protocol); the completed datagram is handed back to the receive path as one frame, outside the
//! lock, its queue marked busy until then.

const policy = @import("ip_frag_policy.zig");
const bo = @import("../lib/byte_order.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

var lock: IrqSpinlock = .{};
var queues: [policy.QUEUES]policy.Queue = @splat(.{});

/// Whether `ip` (an IPv4 header and what follows, `len` bytes) is a fragment: MF set or a non-zero offset.
pub fn isFragment(ip: [*]const u8, len: u32) bool {
    if (len < 20) return false;
    return policy.fragInfo(bo.readU16BeAt(ip, 6)).is_fragment;
}

/// ip_defrag for the fragment in Ethernet frame `frame` (`len` bytes) that arrived on `ifindex`.
pub fn receive(frame: [*]const u8, len: u32, ifindex: u8) void {
    const ip = frame + 14;
    const ip_len = len - 14;
    // The same header checks parseHeader makes for a whole datagram (version, IHL, checksum, total length within the frame).
    if ((ip[0] >> 4) != 4) return;
    const ihl: u32 = @as(u32, ip[0] & 0x0F) * 4;
    if (ihl < 20 or ihl > ip_len) return;
    if (@import("ipv4.zig").checksum(ip, @intCast(ihl)) != 0) return;
    const total: u32 = bo.readU16BeAt(ip, 2);
    if (total < ihl or total > ip_len) return;
    const fi = policy.fragInfo(bo.readU16BeAt(ip, 6));
    const key: policy.Key = .{ .src = ip[12..16].*, .dst = ip[16..20].*, .id = bo.readU16BeAt(ip, 4), .protocol = ip[9] };
    const now = @import("../arch/arch.zig").tsc.nanos();
    const q = blk: {
        const saved = lock.acquire();
        defer lock.release(saved);
        const q = policy.find(&queues, key, now) orelse return;
        switch (policy.insert(q, fi.offset, fi.more, ip[ihl..total], ip[0..ihl])) {
            .complete => {
                q.busy = true;
                break :blk q;
            },
            else => return,
        }
    };
    const f = q.frame(frame[0..14]);
    @import("mod.zig").handleRxPacketOn(f.ptr, @intCast(f.len), ifindex);
    const saved = lock.acquire();
    defer lock.release(saved);
    q.busy = false;
    q.used = false;
}


/// ipv6_frag_rcv for the Ethernet frame `frame` (`len` bytes) whose IPv6 packet `pkt6` (header first) carries a Fragment header at
/// `frag_off` (an offset into the payload after the 40-byte header). An atomic fragment is delivered at once, the Fragment header
/// taken out; a bad fragment draws a parameter problem; the rest joins its queue, and the completed datagram goes back to the
/// receive path as a frame of the IPv6 header (next header the Fragment header's, the headers before it dropped) and the payload.
pub fn receive6(frame: [*]const u8, len: u32, pkt6: []const u8, frag_off: usize, ifindex: u8) void {
    _ = len;
    const p6 = 40 + frag_off;
    if (p6 + 8 > pkt6.len) return;
    const fh = policy.fragHeader6(pkt6[p6..][0..8]);
    const body = pkt6[p6 + 8 ..];
    const src6 = pkt6[8..24].*;
    const dst6 = pkt6[24..40].*;
    switch (policy.check6(fh.offset, fh.more, body.len, @intCast(p6 + 2))) {
        .param_problem => |ptr| {
            @import("icmpv6.zig").sendParamProblemAt(pkt6, 0, ptr, src6, dst6);
            return;
        },
        .atomic => {
            var buf: [14 + 40 + 1500]u8 = undefined;
            if (body.len > 1500) return;
            @memcpy(buf[0..14], frame[0..14]);
            @memcpy(buf[14..54], pkt6[0..40]);
            buf[14 + 6] = fh.nh;
            buf[14 + 4] = @intCast(body.len >> 8);
            buf[14 + 5] = @truncate(body.len);
            @memcpy(buf[54..][0..body.len], body);
            @import("mod.zig").handleRxPacketOn(&buf, @intCast(54 + body.len), ifindex);
            return;
        },
        .queue => {},
    }
    const key: policy.Key = .{ .v6 = true, .src6 = src6, .dst6 = dst6, .id = fh.id };
    const now = @import("../arch/arch.zig").tsc.nanos();
    const q = blk: {
        const saved = lock.acquire();
        defer lock.release(saved);
        const q = policy.find(&queues, key, now) orelse return;
        var hdr: [40]u8 = pkt6[0..40].*;
        hdr[6] = fh.nh;
        switch (policy.insert(q, fh.offset, fh.more, body, &hdr)) {
            .complete => {
                q.busy = true;
                break :blk q;
            },
            else => return,
        }
    };
    const f = q.frame6(frame[0..14]);
    @import("mod.zig").handleRxPacketOn(f.ptr, @intCast(f.len), ifindex);
    const saved = lock.acquire();
    defer lock.release(saved);
    q.busy = false;
    q.used = false;
}
