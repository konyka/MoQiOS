const std = @import("std");

const kt = @import("kernel_shared");

const byte_order = kt.byte_order;
const cow_pte = kt.cow_pte;
const errno = kt.errno;
const eth = kt.eth;
const fmt = kt.fmt_core;
const fmt_serial = kt.fmt;
const ipv4 = kt.ipv4;
const ipv6 = kt.ipv6;
const str = kt.str;
const tcp_util = kt.tcp_util;
const udp_util = kt.udp_util;
const pci_msix = kt.pci_msix;

test {
    std.testing.refAllDecls(@This());
}

test "little-endian helpers round-trip integer values" {
    var buf: [8]u8 = undefined;

    byte_order.writeU16Le(buf[0..2], 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), byte_order.readU16Le(buf[0..2]));
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, buf[0..2]);

    byte_order.writeU32Le(buf[0..4], 0x89abcdef);
    try std.testing.expectEqual(@as(u32, 0x89abcdef), byte_order.readU32Le(buf[0..4]));
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0x89 }, buf[0..4]);

    byte_order.writeU64Le(buf[0..8], 0x0123456789abcdef);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), byte_order.readU64Le(buf[0..8]));
}

test "big-endian network helpers read and write values" {
    var buf: [8]u8 = undefined;

    byte_order.writeU16BeAt(&buf, 1, 0x1234);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, buf[1..3]);
    try std.testing.expectEqual(@as(u16, 0x1234), byte_order.readU16BeAt(&buf, 1));

    byte_order.writeU32BeAt(&buf, 2, 0x89abcdef);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 0xab, 0xcd, 0xef }, buf[2..6]);
    try std.testing.expectEqual(@as(u32, 0x89abcdef), byte_order.readU32BeAt(&buf, 2));
}

test "format helpers cover decimal, hex, and signed extremes" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0", fmt.fmtDec(&buf, 0));
    try std.testing.expectEqualStrings("18446744073709551615", fmt.fmtDec(&buf, std.math.maxInt(u64)));
    try std.testing.expectEqualStrings("00000000000000af", fmt.fmtHex16(&buf, 0xaf));
    try std.testing.expectEqualStrings("deadbeef", fmt.fmtHex(&buf, 0xdeadbeef));
    try std.testing.expectEqualStrings("-9223372036854775808", fmt.fmtSignedDec(&buf, std.math.minInt(i64)));
}

test "COW clone keeps no-execute, which lives above the low flag bits" {
    // A writable, non-executable user data page — a stack or heap entry.
    const parent: u64 = cow_pte.NO_EXECUTE | 0x0000_0000_002e_4000 | 0x067;

    const shared = cow_pte.cowPte(parent);

    // The regression: deriving the child's entry from the frame plus the low 12
    // bits drops NX, because NX is bit 63.
    const low_flag_rebuild = (parent & 0x000F_FFFF_FFFF_F000) | (parent & 0xFFF);
    try std.testing.expect(low_flag_rebuild & cow_pte.NO_EXECUTE == 0);
    try std.testing.expect(shared & cow_pte.NO_EXECUTE != 0);
}

test "COW clone shares the frame read-only and marks both sides" {
    const frame: u64 = 0x0000_0000_002e_4000;
    const parent: u64 = cow_pte.NO_EXECUTE | frame | 0x067; // present|writable|user|accessed|dirty

    const shared = cow_pte.cowPte(parent);

    try std.testing.expectEqual(frame, shared & 0x000F_FFFF_FFFF_F000);
    try std.testing.expect(shared & cow_pte.WRITABLE == 0);
    try std.testing.expect(cow_pte.isCow(shared));
    try std.testing.expect(!cow_pte.isCow(parent));
    // Present and user survive, or the child could not reach its own memory.
    try std.testing.expect(shared & 0x005 == 0x005);
}

test "cloning an already-shared page is a no-op on its entry" {
    const parent: u64 = cow_pte.NO_EXECUTE | 0x0000_0000_002c_3000 | 0x067;

    const once = cow_pte.cowPte(parent);
    try std.testing.expectEqual(once, cow_pte.cowPte(once));
}

test "string helpers compare prefixes and bounded C strings" {
    try std.testing.expect(str.eql("moqi", "moqi"));
    try std.testing.expect(!str.eql("moqi", "moqios"));
    try std.testing.expect(str.startsWith("moqios", "moqi"));
    try std.testing.expect(!str.startsWith("moqi", "moqios"));

    const cstr = [_]u8{ 'o', 's', 0, 'x' };
    try std.testing.expectEqual(@as(usize, 2), str.strnlen(&cstr, cstr.len));
    try std.testing.expectEqual(@as(usize, 1), str.strnlen(&cstr, 1));
}

test "errno constants match the negative Linux convention" {
    try std.testing.expectEqual(@as(i64, -1), errno.EPERM);
    try std.testing.expectEqual(@as(i64, -2), errno.ENOENT);
    try std.testing.expectEqual(@as(i64, -12), errno.ENOMEM);
    try std.testing.expectEqual(@as(i64, -22), errno.EINVAL);
    try std.testing.expectEqual(@as(i64, -38), errno.ENOSYS);
    try std.testing.expectEqual(@as(i64, -111), errno.ECONNREFUSED);

    // Every exported constant is a distinct negative errno value.
    inline for (@typeInfo(errno).@"struct".decls) |d| {
        try std.testing.expect(@field(errno, d.name) < 0);
    }
    try std.testing.expect(errno.ENOENT != errno.EAGAIN);
    try std.testing.expect(errno.ENOTCONN != errno.ECONNRESET);
}

test "fmt.zig re-exports the fmt_core helpers unchanged" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("42", fmt_serial.formatInt(&buf, 42));
    try std.testing.expectEqualStrings("0000000000000042", fmt_serial.formatHex(&buf, 0x42));
    try std.testing.expectEqualStrings("000000af", fmt_serial.fmtHex8(&buf, 0xaf));
    try std.testing.expectEqualStrings("ff", fmt_serial.fmtHex(&buf, 0xff));
}

test "ipv4 checksum matches the RFC 1071 worked example" {
    // RFC 1071 §3: bytes 00 01 f2 03 f4 f5 f6 f7 sum to 0xddf2, so the
    // one's-complement checksum is 0x220d.
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try std.testing.expectEqual(@as(u16, 0x220d), ipv4.checksum(&data, data.len));

    // Odd length: the trailing byte pairs with a zero low byte (0x0001+0xf200).
    const odd = [_]u8{ 0x00, 0x01, 0xf2 };
    try std.testing.expectEqual(@as(u16, 0x0dfe), ipv4.checksum(&odd, odd.len));
}

test "ipv4 header build/parse round-trips with a valid checksum" {
    var buf: [20]u8 = undefined;
    const src = [4]u8{ 192, 168, 0, 1 };
    const dst = [4]u8{ 192, 168, 0, 2 };

    ipv4.buildHeader(&buf, src, dst, ipv4.PROTO_UDP, 8);

    // Independently computed header checksum for these exact fields.
    try std.testing.expectEqual(@as(u16, 0xb97d), byte_order.readU16BeAt(&buf, 10));
    // A checksum computed over the final header (field included) is zero.
    try std.testing.expectEqual(@as(u16, 0), ipv4.checksum(&buf, 20));

    const info = ipv4.parseHeader(&buf, 28).?;
    try std.testing.expectEqualSlices(u8, &src, &info.src_ip);
    try std.testing.expectEqualSlices(u8, &dst, &info.dst_ip);
    try std.testing.expectEqual(ipv4.PROTO_UDP, info.protocol);
    try std.testing.expectEqual(@as(u16, 20), info.payload_offset);
    try std.testing.expectEqual(@as(u16, 8), info.payload_len);
    try std.testing.expect(!info.ecn_ce);
}

test "ipv4 parse rejects malformed headers and oversized total_len" {
    var buf: [20]u8 = undefined;
    ipv4.buildHeader(&buf, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, ipv4.PROTO_TCP, 40);

    // Version != 4.
    var bad = buf;
    bad[0] = 0x65;
    try std.testing.expect(ipv4.parseHeader(&bad, null) == null);

    // IHL below the 20-byte minimum.
    bad = buf;
    bad[0] = 0x41;
    try std.testing.expect(ipv4.parseHeader(&bad, null) == null);

    // Corrupted header: checksum no longer validates.
    bad = buf;
    bad[8] ^= 0xff;
    try std.testing.expect(ipv4.parseHeader(&bad, null) == null);

    // frame_len shorter than the header.
    try std.testing.expect(ipv4.parseHeader(&buf, 10) == null);

    // total_len (60) beyond the received frame.
    try std.testing.expect(ipv4.parseHeader(&buf, 30) == null);
    try std.testing.expect(ipv4.parseHeader(&buf, 60) != null);
}

test "ipv4 ECN helpers mark the header and keep the checksum valid" {
    var buf: [20]u8 = undefined;
    ipv4.buildHeader(&buf, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, ipv4.PROTO_TCP, 0);

    ipv4.setEct0(&buf);
    try std.testing.expectEqual(@as(u8, 0x02), buf[1] & 0x03);
    const info = ipv4.parseHeader(&buf, 20).?;
    try std.testing.expect(!info.ecn_ce); // ECT(0) is not Congestion Experienced

    // Manually mark CE (0x03) and re-seal; parse must report ecn_ce.
    buf[1] = (buf[1] & 0xFC) | ipv4.ECN_CE;
    buf[10] = 0;
    buf[11] = 0;
    byte_order.writeU16BeAt(&buf, 10, ipv4.checksum(&buf, 20));
    try std.testing.expect(ipv4.parseHeader(&buf, 20).?.ecn_ce);
}

test "ipv6 header build/parse round-trips" {
    var buf: [40]u8 = undefined;
    var src: [16]u8 = @splat(0);
    var dst: [16]u8 = @splat(0);
    src[0] = 0x20;
    src[1] = 0x01;
    src[15] = 0x01;
    dst[0] = 0x20;
    dst[1] = 0x01;
    dst[15] = 0x02;

    ipv6.buildHeader(&buf, src, dst, ipv6.PROTO_TCP, 40);

    const info = ipv6.parseHeader(&buf).?;
    try std.testing.expectEqualSlices(u8, &src, &info.src_ip);
    try std.testing.expectEqualSlices(u8, &dst, &info.dst_ip);
    try std.testing.expectEqual(ipv6.PROTO_TCP, info.next_header);
    try std.testing.expectEqual(ipv6.DEFAULT_HOP_LIMIT, info.hop_limit);
    try std.testing.expectEqual(@as(u16, 40), info.payload_offset);
    try std.testing.expectEqual(@as(u16, 40), info.payload_len);
    try std.testing.expect(!info.ecn_ce);

    // Version != 6 is rejected.
    var bad = buf;
    bad[0] = 0x45;
    try std.testing.expect(ipv6.parseHeader(&bad) == null);
}

test "ipv6 address classifiers and solicited-node multicast" {
    const unspecified: [16]u8 = @splat(0);
    try std.testing.expect(ipv6.isUnspecified(unspecified));

    var link_local: [16]u8 = @splat(0);
    link_local[0] = 0xfe;
    link_local[1] = 0x80;
    link_local[15] = 0x34;
    try std.testing.expect(ipv6.isLinkLocal(link_local));
    try std.testing.expect(!ipv6.isMulticast(link_local));

    // fe80::/10 on-link prefix match, including a partial-byte boundary.
    var fe80_prefix: [16]u8 = @splat(0);
    fe80_prefix[0] = 0xfe;
    fe80_prefix[1] = 0x80;
    try std.testing.expect(ipv6.prefixMatch(link_local, fe80_prefix, 10));
    try std.testing.expect(ipv6.prefixMatch(link_local, fe80_prefix, 64));
    try std.testing.expect(!ipv6.prefixMatch(link_local, fe80_prefix, 129));
    var other: [16]u8 = @splat(0);
    other[0] = 0x20;
    other[1] = 0x01;
    try std.testing.expect(!ipv6.prefixMatch(other, fe80_prefix, 10));

    // Solicited-node multicast: ff02::1:ffXX:XXXX from the low 24 bits.
    var target: [16]u8 = @splat(0);
    target[13] = 0xab;
    target[14] = 0xcd;
    target[15] = 0xef;
    const snm = ipv6.solicitedNodeMulticast(target);
    try std.testing.expect(ipv6.isMulticast(snm));
    try std.testing.expect(ipv6.isSolicitedNodeMulticast(snm, target));
    try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x33, 0xff, 0xab, 0xcd, 0xef }, &ipv6.multicastMac(snm));
}

test "eth frame build writes header fields and reports total length" {
    var buf: [14]u8 = undefined;
    const dst = [6]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const src = [6]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };

    const total = eth.buildFrame(&buf, dst, src, eth.ETHERTYPE_IPV4, 46);

    try std.testing.expectEqual(@as(u16, 60), total);
    try std.testing.expectEqualSlices(u8, &dst, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &src, buf[6..12]);
    try std.testing.expectEqual(eth.ETHERTYPE_IPV4, eth.parseEthertype(&buf));

    // ARP and IPv6 ethertypes round-trip through the same offset.
    _ = eth.buildFrame(&buf, dst, src, eth.ETHERTYPE_IPV6, 0);
    try std.testing.expectEqual(eth.ETHERTYPE_IPV6, eth.parseEthertype(&buf));
}

test "tcp sequence comparisons wrap around the u32 boundary" {
    // 0xffffffff is "before" 0 in RFC 793 modular sequence space.
    try std.testing.expect(tcp_util.seqLt(0xffff_ffff, 0));
    try std.testing.expect(tcp_util.seqGt(0, 0xffff_ffff));
    try std.testing.expect(tcp_util.seqLeq(0xffff_ffff, 0xffff_ffff));
    try std.testing.expect(!tcp_util.seqLt(0, 0xffff_ffff));

    // Window [0xfffffff0, 0x10) wraps past the end of sequence space.
    try std.testing.expect(tcp_util.seqInWindow(0xffff_ffff, 0xffff_fff0, 0x10));
    try std.testing.expect(tcp_util.seqInWindow(0, 0xffff_fff0, 0x10));
    try std.testing.expect(tcp_util.seqInWindow(0x0f, 0xffff_fff0, 0x10));
    // Half-open: the right edge is excluded, just-left-of-left is outside.
    try std.testing.expect(!tcp_util.seqInWindow(0x10, 0xffff_fff0, 0x10));
    try std.testing.expect(!tcp_util.seqInWindow(0xffff_ffef, 0xffff_fff0, 0x10));
}

test "tcp ring-buffer helpers stay correct across index wrap" {
    // head/tail live in [0, size); (tail -% head) wraps through 2^32 and the
    // modulo brings it back into ring space.
    try std.testing.expectEqual(@as(u32, 246), tcp_util.ringDataLen(100, 90, 256));
    try std.testing.expectEqual(@as(u32, 20), tcp_util.ringDataLen(100, 120, 256));
    try std.testing.expectEqual(@as(u32, 0), tcp_util.ringDataLen(64, 64, 256));
    // One slot is reserved so a full ring is distinguishable from empty.
    try std.testing.expectEqual(@as(u32, 255), tcp_util.ringAvailable(64, 64, 256));
    try std.testing.expectEqual(@as(u32, 235), tcp_util.ringAvailable(100, 120, 256));
}

test "tcp checksum matches an independently computed RFC 793 vector" {
    // Pseudo-header (10.0.0.1 -> 10.0.0.2, proto TCP, len 20) + a 20-byte
    // header with the checksum field zeroed; expected value computed with an
    // independent RFC 1071 implementation.
    const tcp_hdr = [_]u8{
        0x11, 0x11, 0x22, 0x22, // src/dst ports
        0x01, 0x02, 0x03, 0x04, // seq
        0x00, 0x00, 0x00, 0x00, // ack
        0x50, 0x18, 0x10, 0x00, // offset|flags, window
        0x00, 0x00, 0x00, 0x00, // checksum (0), urgent
    };
    const csum = tcp_util.checksum(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, &tcp_hdr, tcp_hdr.len);
    try std.testing.expectEqual(@as(u16, 0x5491), csum);
}

test "udp header parse bounds-checks and reports payload length" {
    const hdr = [_]u8{ 0x04, 0xd2, 0x16, 0x2e, 0x00, 0x0c, 0x00, 0x00 };
    const info = udp_util.parseHeader(&hdr, hdr.len).?;
    try std.testing.expectEqual(@as(u16, 0x04d2), info.src_port);
    try std.testing.expectEqual(@as(u16, 0x162e), info.dst_port);
    try std.testing.expectEqual(@as(u16, 12), info.udp_len);
    try std.testing.expectEqual(@as(u16, 4), info.payload_len);

    // Shorter than the 8-byte header is rejected.
    try std.testing.expect(udp_util.parseHeader(&hdr, 7) == null);

    // A length field at/below the header size yields zero payload bytes.
    const short = [_]u8{ 0x00, 0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u16, 0), udp_util.parseHeader(&short, short.len).?.payload_len);
}

test "udp checksums match independently computed vectors" {
    const seg = [_]u8{
        0x04, 0xd2, 0x16, 0x2e, // src/dst ports
        0x00, 0x0c, 0x00, 0x00, // len 12, checksum 0
        0xde, 0xad, 0xbe, 0xef, // payload
    };
    const src4 = [4]u8{ 192, 168, 0, 1 };
    const dst4 = [4]u8{ 192, 168, 0, 2 };
    try std.testing.expectEqual(@as(u16, 0xc5e4), udp_util.checksumV4(src4, dst4, &seg, seg.len));

    var src6: [16]u8 = @splat(0);
    var dst6: [16]u8 = @splat(0);
    src6[0] = 0x20;
    src6[1] = 0x01;
    src6[2] = 0x0d;
    src6[3] = 0xb8;
    src6[15] = 0x01;
    dst6[0] = 0x20;
    dst6[1] = 0x01;
    dst6[2] = 0x0d;
    dst6[3] = 0xb8;
    dst6[15] = 0x02;
    try std.testing.expectEqual(@as(u16, 0xebc3), udp_util.checksumV6(src6, dst6, &seg, seg.len));
}

/// Build a minimal fake PCI config-space image with a capabilities list.
/// caps: list of .{ offset, cap_id, next_offset } entries; status bit 4 set.
fn fakeConfigWithCaps(caps: []const struct { off: u8, id: u8, next: u8 }) [256]u8 {
    var cfg: [256]u8 = @splat(0);
    // Status register (offset 0x06), bit 4: capabilities list present.
    cfg[0x06] = 0x10;
    cfg[0x34] = if (caps.len > 0) caps[0].off else 0;
    for (caps) |c| {
        cfg[c.off] = c.id;
        cfg[c.off + 1] = c.next;
    }
    return cfg;
}

test "pci capability walk finds MSI-X by ID 0x11" {
    const cfg = fakeConfigWithCaps(&.{
        .{ .off = 0x40, .id = 0x01, .next = 0x50 }, // Power Management
        .{ .off = 0x50, .id = 0x05, .next = 0x60 }, // MSI
        .{ .off = 0x60, .id = 0x11, .next = 0x00 }, // MSI-X (last)
    });

    try std.testing.expectEqual(@as(?u8, 0x60), pci_msix.findCapability(&cfg, 0x11));
    try std.testing.expectEqual(@as(?u8, 0x50), pci_msix.findCapability(&cfg, 0x05));
    // Capability not in the list terminates the walk with null.
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(&cfg, 0x10));

    // No capabilities list (status bit 4 clear) -> null even if bytes match.
    var no_caps = cfg;
    no_caps[0x06] = 0;
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(&no_caps, 0x11));

    // Empty list pointer -> null.
    var empty = cfg;
    empty[0x34] = 0;
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(&empty, 0x11));

    // Truncated image cannot host a walk.
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(cfg[0..0x20], 0x11));
}

test "MSI-X capability parse decodes table size, BIR and offsets" {
    var cfg = fakeConfigWithCaps(&.{
        .{ .off = 0x40, .id = 0x11, .next = 0x00 },
    });
    // Message Control (cap+2): table size N-1 = 3 -> 4 entries.
    cfg[0x42] = 0x03;
    cfg[0x43] = 0x00;
    // Table BIR/offset (cap+4): BIR=4, offset 0x0000_2000 (8-byte aligned).
    byte_order.writeU32Le(cfg[0x44..0x48], 0x0000_2004);
    // PBA BIR/offset (cap+8): BIR=4, offset 0x0000_3000.
    byte_order.writeU32Le(cfg[0x48..0x4C], 0x0000_3004);

    const info = pci_msix.parseMsixCapability(&cfg, 0x40).?;
    try std.testing.expectEqual(@as(u16, 4), info.table_size);
    try std.testing.expectEqual(@as(u8, 4), info.table_bir);
    try std.testing.expectEqual(@as(u32, 0x2000), info.table_offset);
    try std.testing.expectEqual(@as(u8, 4), info.pba_bir);
    try std.testing.expectEqual(@as(u32, 0x3000), info.pba_offset);

    // Wrong capability ID at the offset is rejected.
    try std.testing.expectEqual(@as(?pci_msix.MsixInfo, null), pci_msix.parseMsixCapability(&cfg, 0x44));
}

test "MSI-X table size decode is N-1 based" {
    try std.testing.expectEqual(@as(u16, 1), pci_msix.msixTableSize(0x0000));
    try std.testing.expectEqual(@as(u16, 4), pci_msix.msixTableSize(0x0003));
    try std.testing.expectEqual(@as(u16, 2048), pci_msix.msixTableSize(0x07FF));
    // Enable/function-mask bits (14/15) do not leak into the size.
    try std.testing.expectEqual(@as(u16, 5), pci_msix.msixTableSize(0xC004));
}

test "MSI-X message address/data compose fixed LAPIC delivery" {
    // BSP (APIC ID 0): plain LAPIC base, vector in the low data byte.
    try std.testing.expectEqual(@as(u64, 0xFEE0_0000), pci_msix.composeMessageAddress(0xFEE0_0000, 0));
    try std.testing.expectEqual(@as(u32, 242), pci_msix.composeMessageData(242));

    // Non-zero destination APIC ID lands in address bits 19:12.
    try std.testing.expectEqual(@as(u64, 0xFEE0_3000), pci_msix.composeMessageAddress(0xFEE0_0000, 3));

    // Data word: fixed delivery mode (000) keeps everything above the vector clear.
    try std.testing.expectEqual(@as(u32, 0), pci_msix.composeMessageData(0));
    try std.testing.expectEqual(@as(u32, 0xFF), pci_msix.composeMessageData(0xFF));
}

// ─── loopback (F2) ───
const lo = kt.lo;

test "lo queue enqueue/dequeue preserves FIFO order" {
    var q = lo.LoopbackQueue.init();
    try std.testing.expectEqual(@as(u32, 0), q.pending());

    const a = [_]u8{ 0xaa, 0xbb, 0xcc };
    const b = [_]u8{ 0x11, 0x22 };
    try std.testing.expect(q.enqueue(&a));
    try std.testing.expect(q.enqueue(&b));
    try std.testing.expectEqual(@as(u32, 2), q.pending());

    var out: [lo.MAX_FRAME]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 3), q.dequeue(&out));
    try std.testing.expectEqualSlices(u8, &a, out[0..3]);
    try std.testing.expectEqual(@as(u32, 2), q.dequeue(&out));
    try std.testing.expectEqualSlices(u8, &b, out[0..2]);
    try std.testing.expectEqual(@as(u32, 0), q.dequeue(&out));
    try std.testing.expectEqual(@as(u32, 0), q.pending());
}

test "lo queue head/tail wrap around the ring" {
    var q = lo.LoopbackQueue.init();
    var out: [lo.MAX_FRAME]u8 = undefined;

    // Cycle more frames than QUEUE_DEPTH so head/tail wrap past slot 0.
    var i: u32 = 0;
    while (i < lo.QUEUE_DEPTH * 3) : (i += 1) {
        const frame = [_]u8{ @truncate(i), 0x5a };
        try std.testing.expect(q.enqueue(&frame));
        try std.testing.expectEqual(@as(u32, 2), q.dequeue(&out));
        try std.testing.expectEqual(@as(u8, @truncate(i)), out[0]);
        try std.testing.expectEqual(@as(u8, 0x5a), out[1]);
    }
    try std.testing.expectEqual(@as(u32, 0), q.pending());
    try std.testing.expectEqual(@as(u64, 0), q.dropped);
}

test "lo queue full drops new frames and counts them" {
    var q = lo.LoopbackQueue.init();
    const frame = [_]u8{0x42} ** 64;

    var i: u32 = 0;
    while (i < lo.QUEUE_DEPTH) : (i += 1) try std.testing.expect(q.enqueue(&frame));
    try std.testing.expectEqual(lo.QUEUE_DEPTH, q.pending());

    try std.testing.expect(!q.enqueue(&frame));
    try std.testing.expect(!q.enqueue(&frame));
    try std.testing.expectEqual(@as(u64, 2), q.dropped);

    // One dequeue frees a slot, then exactly one more frame fits.
    var out: [lo.MAX_FRAME]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 64), q.dequeue(&out));
    try std.testing.expect(q.enqueue(&frame));
    try std.testing.expectEqual(lo.QUEUE_DEPTH, q.pending());
}

test "lo queue rejects empty and oversized frames" {
    var q = lo.LoopbackQueue.init();
    try std.testing.expect(!q.enqueue(&[_]u8{}));
    const big = [_]u8{0xff} ** (lo.MAX_FRAME + 1);
    try std.testing.expect(!q.enqueue(&big));
    try std.testing.expectEqual(@as(u32, 0), q.pending());

    // Exactly MAX_FRAME bytes still fits.
    const max_frame = [_]u8{0x7e} ** lo.MAX_FRAME;
    try std.testing.expect(q.enqueue(&max_frame));
    var out: [lo.MAX_FRAME]u8 = undefined;
    try std.testing.expectEqual(lo.MAX_FRAME, q.dequeue(&out));
    try std.testing.expectEqualSlices(u8, &max_frame, &out);
}

test "lo isLoopback classifies the whole 127.0.0.0/8 block" {
    try std.testing.expect(lo.isLoopback(.{ 127, 0, 0, 1 }));
    try std.testing.expect(lo.isLoopback(.{ 127, 0, 0, 0 }));
    try std.testing.expect(lo.isLoopback(.{ 127, 255, 255, 254 }));
    try std.testing.expect(!lo.isLoopback(.{ 126, 255, 255, 255 }));
    try std.testing.expect(!lo.isLoopback(.{ 128, 0, 0, 1 }));
    try std.testing.expect(!lo.isLoopback(.{ 10, 0, 2, 15 }));
    try std.testing.expect(!lo.isLoopback(.{ 0, 0, 0, 0 }));
}


// ─── RT scheduling (F3) ───
// Pure policy-logic tests for kernel/proc/sched_policy.zig (SCHED_FIFO/RR).

test "F3: RT classes beat every OTHER task regardless of priority band" {
    const sp = kt.sched_policy;

    // Lowest-prio RT task (rt 1 → kernel 98) still beats the highest-prio
    // OTHER task (nice -20 → kernel 0).
    try std.testing.expect(sp.beats(sp.SCHED_FIFO, 98, sp.SCHED_OTHER, 0));
    try std.testing.expect(sp.beats(sp.SCHED_RR, 98, sp.SCHED_OTHER, 0));
    // ... and beats the default OTHER task (kernel 20) and idle (255).
    try std.testing.expect(sp.beats(sp.SCHED_FIFO, 98, sp.SCHED_OTHER, 20));
    try std.testing.expect(sp.beats(sp.SCHED_RR, 0, sp.SCHED_OTHER, 255));
    // OTHER never beats RT.
    try std.testing.expect(!sp.beats(sp.SCHED_OTHER, 0, sp.SCHED_FIFO, 98));
    try std.testing.expect(!sp.beats(sp.SCHED_OTHER, 0, sp.SCHED_RR, 98));
}

test "F3: within-class ordering preserves kernel priority order" {
    const sp = kt.sched_policy;

    // RT: higher sched_priority (lower kernel prio) wins; FIFO vs RR at the
    // same RT priority rank equally (neither strictly beats the other).
    try std.testing.expect(sp.beats(sp.SCHED_FIFO, sp.rtToKernelPriority(99), sp.SCHED_RR, sp.rtToKernelPriority(1)));
    try std.testing.expect(!sp.beats(sp.SCHED_FIFO, 10, sp.SCHED_RR, 10));
    try std.testing.expect(!sp.beats(sp.SCHED_RR, 10, sp.SCHED_FIFO, 10));
    // OTHER: identical to the pre-F3 raw comparison (lower number wins).
    try std.testing.expect(sp.beats(sp.SCHED_OTHER, 0, sp.SCHED_OTHER, 20));
    try std.testing.expect(sp.beats(sp.SCHED_OTHER, 20, sp.SCHED_OTHER, 39));
    try std.testing.expect(!sp.beats(sp.SCHED_OTHER, 20, sp.SCHED_OTHER, 20));
}

test "F3: quantum expiry per class" {
    const sp = kt.sched_policy;

    // FIFO runs until it blocks/yields — no quantum expiry.
    try std.testing.expect(!sp.hasQuantumExpiry(sp.SCHED_FIFO));
    // RR and OTHER expire (RR rotates among equal-priority peers).
    try std.testing.expect(sp.hasQuantumExpiry(sp.SCHED_RR));
    try std.testing.expect(sp.hasQuantumExpiry(sp.SCHED_OTHER));
    try std.testing.expectEqual(@as(u64, 10), sp.RR_QUANTUM_TICKS);
}

test "F3: RT priority clamping and kernel-band mapping" {
    const sp = kt.sched_policy;

    try std.testing.expectEqual(@as(u8, 1), sp.clampRtPriority(-5));
    try std.testing.expectEqual(@as(u8, 1), sp.clampRtPriority(0));
    try std.testing.expectEqual(@as(u8, 50), sp.clampRtPriority(50));
    try std.testing.expectEqual(@as(u8, 99), sp.clampRtPriority(100));
    try std.testing.expectEqual(@as(u8, 99), sp.clampRtPriority(1000));

    // Band mapping: rt 99 → kernel 0 (best), rt 1 → kernel 98, round-trips.
    try std.testing.expectEqual(@as(u8, 0), sp.rtToKernelPriority(99));
    try std.testing.expectEqual(@as(u8, 98), sp.rtToKernelPriority(1));
    try std.testing.expectEqual(@as(u8, 99), sp.kernelToRtPriority(0));
    try std.testing.expectEqual(@as(u8, 1), sp.kernelToRtPriority(98));
    var rt: u8 = 1;
    while (rt <= 99) : (rt += 1) {
        try std.testing.expectEqual(rt, sp.kernelToRtPriority(sp.rtToKernelPriority(rt)));
    }
}

test "F3: priority validation per policy (sched_setscheduler rules)" {
    const sp = kt.sched_policy;

    // OTHER requires priority 0.
    try std.testing.expect(sp.validatePriority(sp.SCHED_OTHER, 0));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_OTHER, 1));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_OTHER, -1));
    // FIFO/RR require 1..99.
    try std.testing.expect(!sp.validatePriority(sp.SCHED_FIFO, 0));
    try std.testing.expect(sp.validatePriority(sp.SCHED_FIFO, 1));
    try std.testing.expect(sp.validatePriority(sp.SCHED_FIFO, 99));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_FIFO, 100));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_RR, 0));
    try std.testing.expect(sp.validatePriority(sp.SCHED_RR, 50));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_RR, 100));
    // Unknown policies rejected outright.
    try std.testing.expect(!sp.validatePriority(3, 0)); // BATCH — not implemented
    try std.testing.expect(!sp.validatePriority(6, 0)); // DEADLINE — not implemented
    try std.testing.expect(!sp.isValidClass(3));
    try std.testing.expect(sp.isValidClass(sp.SCHED_OTHER));
    try std.testing.expect(sp.isValidClass(sp.SCHED_FIFO));
    try std.testing.expect(sp.isValidClass(sp.SCHED_RR));
}

test "F3: rankKey bands — RT below OTHER below idle, OTHER order intact" {
    const sp = kt.sched_policy;

    // Every RT key < every OTHER key.
    try std.testing.expect(sp.rankKey(sp.SCHED_FIFO, 98) < sp.rankKey(sp.SCHED_OTHER, 0));
    try std.testing.expect(sp.rankKey(sp.SCHED_RR, 0) < sp.rankKey(sp.SCHED_OTHER, 255));
    // OTHER keys are monotonic in kernel priority (pre-F3 ordering preserved).
    try std.testing.expect(sp.rankKey(sp.SCHED_OTHER, 0) < sp.rankKey(sp.SCHED_OTHER, 20));
    try std.testing.expect(sp.rankKey(sp.SCHED_OTHER, 20) < sp.rankKey(sp.SCHED_OTHER, 255));
    // Idle (OTHER, 255) stays unpickable by the bitmap fallback, matching the
    // old `best_prio = 255` initialiser: its key is not below MAX_PICK_KEY.
    try std.testing.expect(!(sp.rankKey(sp.SCHED_OTHER, 255) < sp.MAX_PICK_KEY));
    try std.testing.expect(sp.rankKey(sp.SCHED_OTHER, 254) < sp.MAX_PICK_KEY);
    try std.testing.expect(sp.rankKey(sp.SCHED_FIFO, 98) < sp.MAX_PICK_KEY);
}
// ─── end RT scheduling (F3) ───

// ─── kmsg ring (G4) ───
const kmsg_ring = kt.kmsg_ring;

/// Drain the ring from `cursor` into `out`, following short reads at the
/// physical wrap. Returns bytes copied and the final cursor.
fn kmsgDrain(ring: anytype, cursor: u64, out: []u8) struct { n: usize, pos: u64 } {
    var pos = cursor;
    var copied: usize = 0;
    while (copied < out.len) {
        const r = ring.read(pos, out[copied..]);
        pos = r.new_pos;
        copied += r.n;
        if (r.n == 0) break;
    }
    return .{ .n = copied, .pos = pos };
}

test "G4: empty ring reads as EOF" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    var buf: [16]u8 = undefined;
    const r = ring.read(0, &buf);
    try std.testing.expectEqual(@as(usize, 0), r.n);
    try std.testing.expectEqual(@as(u64, 0), r.new_pos);
}

test "G4: append lines and read them back from cursor 0" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    ring.appendLine("[INF] one\n");
    ring.appendLine("[DBG] two\n");

    var buf: [64]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings("[INF] one\n[DBG] two\n", buf[0..d.n]);
    try std.testing.expectEqual(@as(u64, 20), d.pos);

    // Reading at the newest cursor is EOF.
    const r = ring.read(d.pos, &buf);
    try std.testing.expectEqual(@as(usize, 0), r.n);
}

test "G4: piecewise append (prefix + body + newline) reads as one line" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    ring.appendLine("[INF] ");
    ring.appendLine("0x");
    ring.appendLine("deadbeef");
    ring.appendLine("\n");

    var buf: [64]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings("[INF] 0xdeadbeef\n", buf[0..d.n]);
}

test "G4: wrap drops oldest whole lines, keeps newest intact" {
    var ring: kmsg_ring.KmsgRing(16) = .{};
    ring.appendLine("AAAA\n"); // 5
    ring.appendLine("BBBB\n"); // 10
    ring.appendLine("CCCC\n"); // 15 — 1 byte free
    ring.appendLine("DDDD\n"); // needs 5: drops AAAA only (BBBB..DDDD = 15 <= 16)

    var buf: [32]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings("BBBB\nCCCC\nDDDD\n", buf[0..d.n]);

    // Absolute cursors survive the wrap: 20 bytes appended total.
    try std.testing.expectEqual(@as(u64, 20), d.pos);
    try std.testing.expectEqual(@as(u64, 5), ring.oldestPos());
}

test "G4: stale cursor clamps forward to the oldest available byte" {
    var ring: kmsg_ring.KmsgRing(16) = .{};
    ring.appendLine("AAAA\n");
    ring.appendLine("BBBB\n");
    ring.appendLine("CCCC\n");
    ring.appendLine("DDDD\n"); // oldest is now absolute 5 ("BBBB\n...")

    var buf: [16]u8 = undefined;
    // Cursor 3 points into long-gone "AAAA\n" — clamp to 5.
    const r = ring.read(3, &buf);
    try std.testing.expect(r.n > 0);
    try std.testing.expectEqual(@as(u8, 'B'), buf[0]);
    try std.testing.expectEqual(@as(u64, 5 + r.n), r.new_pos);
}

test "G4: short read at the physical wrap, continuation gets the rest" {
    var ring: kmsg_ring.KmsgRing(8) = .{};
    ring.appendLine("ab\n"); // bytes 0..3
    ring.appendLine("cd\n"); // bytes 3..6 — write head now near the end
    ring.appendLine("ef\n"); // drops "ab\n", wraps mid-line: bytes 6..9

    // First read must stop at the physical end of the buffer...
    var buf: [8]u8 = undefined;
    const r1 = ring.read(ring.oldestPos(), &buf);
    try std.testing.expect(r1.n > 0);
    // ...and draining must still reconstruct "cd\nef\n" (6 bytes).
    const d = kmsgDrain(&ring, ring.oldestPos(), &buf);
    try std.testing.expectEqualStrings("cd\nef\n", buf[0..d.n]);
    try std.testing.expectEqual(@as(u64, 9), d.pos);
}

test "G4: line longer than the whole ring keeps only its tail" {
    var ring: kmsg_ring.KmsgRing(8) = .{};
    const long = "0123456789\n"; // 11 bytes > 8
    ring.appendLine(long);

    var buf: [16]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings(long[long.len - 8 ..], buf[0..d.n]);
}

test "G4: ring survives many small lines (overwrite-oldest stress)" {
    var ring: kmsg_ring.KmsgRing(32) = .{};
    // 20 lines of "Lnn\n" (4 bytes each) = 80 bytes through a 32-byte ring.
    var linebuf: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        linebuf[0] = 'L';
        linebuf[1] = '0' + @as(u8, @intCast(i / 10));
        linebuf[2] = '0' + @as(u8, @intCast(i % 10));
        linebuf[3] = '\n';
        ring.appendLine(&linebuf);
    }
    // Only the last 8 lines fit.
    var buf: [64]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqual(@as(usize, 32), d.n);
    try std.testing.expectEqualStrings("L12\nL13\nL14\nL15\nL16\nL17\nL18\nL19\n", buf[0..d.n]);
    try std.testing.expectEqual(@as(u64, 80), d.pos);
}
// ─── end kmsg ring (G4) ───

// ─── DHCP boot (G3) ───
// The lease-state globals are pure (no arch deps): only the packet TX/RX
// paths reach serial/udp/nic, and Zig's lazy decl analysis leaves those
// unanalyzed here. Pinning the defaults matters because netif.getOurIp()
// falls back to static 10.0.2.15 exactly when isConfigured() is false.
test "G3: DHCP lease state defaults to unconfigured (static fallback active)" {
    const dhcp = kt.dhcp;

    try std.testing.expect(!dhcp.isConfigured());
    try std.testing.expectEqual(@as([4]u8, .{ 0, 0, 0, 0 }), dhcp.getIp());
    try std.testing.expectEqual(@as([4]u8, .{ 0, 0, 0, 0 }), dhcp.getGateway());
    try std.testing.expectEqual(@as([4]u8, .{ 255, 255, 255, 0 }), dhcp.getNetmask());
    try std.testing.expectEqual(@as([4]u8, .{ 0, 0, 0, 0 }), dhcp.getDnsServer());
}
// ─── end DHCP boot (G3) ───

// ─── TRIM (G5) ───
const trim_ranges = kt.trim_ranges;
const TrimExtent = trim_ranges.Extent;

test "G5: empty extent list coalesces to zero ranges" {
    var out: [4]TrimExtent = undefined;
    try std.testing.expectEqual(@as(usize, 0), trim_ranges.coalesce(&.{}, &out));
}

test "G5: single extent passes through unchanged" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{.{ .start = 100, .count = 8 }};
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 8), out[0].count);
}

test "G5: adjacent extents merge into one contiguous range" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 8 },
        .{ .start = 108, .count = 8 },
        .{ .start = 116, .count = 4 },
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 20), out[0].count);
}

test "G5: overlapping extents merge without double counting" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 16 },
        .{ .start = 108, .count = 16 }, // overlaps 108..115
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 24), out[0].count);
}

test "G5: disjoint extents stay separate and come out sorted" {
    var out: [4]TrimExtent = undefined;
    // Deliberately unsorted input (ext2 indirect-tree frees arrive out of order).
    const in = [_]TrimExtent{
        .{ .start = 500, .count = 4 },
        .{ .start = 100, .count = 8 },
        .{ .start = 108, .count = 2 },
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 10), out[0].count);
    try std.testing.expectEqual(@as(u64, 500), out[1].start);
    try std.testing.expectEqual(@as(u32, 4), out[1].count);
}

test "G5: zero-count extents are dropped" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 0 },
        .{ .start = 200, .count = 4 },
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 200), out[0].start);
}

test "G5: contained extent does not grow the range" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 64 },
        .{ .start = 120, .count = 8 }, // fully inside the first
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 64), out[0].count);
}
// ─── end TRIM (G5) ───

// ─── file mmap (G2) ───
const filemap = kt.filemap;

const G2Region = struct {
    base: u64 = 0,
    num_pages: u64 = 0,
    active: bool = false,
    file_kind: u8 = 0,
    prot: u8 = 0,
    file_offset: u64 = 0,
    file_size: u64 = 0,
    shared: bool = false,
};

test "G2: mmap offset must be page-aligned" {
    try std.testing.expect(filemap.offsetValid(0));
    try std.testing.expect(filemap.offsetValid(4096));
    try std.testing.expect(filemap.offsetValid(8192));
    try std.testing.expect(!filemap.offsetValid(1));
    try std.testing.expect(!filemap.offsetValid(4095));
    try std.testing.expect(!filemap.offsetValid(4097));
}

test "G2: findFileRegion matches only active file-backed regions" {
    const regions = [_]G2Region{
        .{ .base = 0x1000, .num_pages = 2, .active = true, .file_kind = 2 },
        .{ .base = 0x4000, .num_pages = 1, .active = true, .file_kind = 0 }, // anonymous
        .{ .base = 0x8000, .num_pages = 4, .active = false, .file_kind = 3 }, // inactive
        .{ .base = 0x10000, .num_pages = 2, .active = true, .file_kind = 3 },
    };
    try std.testing.expectEqual(@as(?usize, 0), filemap.findFileRegion(G2Region, &regions, 0x1000));
    try std.testing.expectEqual(@as(?usize, 0), filemap.findFileRegion(G2Region, &regions, 0x2fff));
    // Just past the end of region 0.
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x3000));
    // Anonymous and inactive regions are invisible to the file fault path.
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x4000));
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x8000));
    try std.testing.expectEqual(@as(?usize, 3), filemap.findFileRegion(G2Region, &regions, 0x11000));
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x0));
}

test "G2: planFault computes file offset, EOF clamp and COW permissions" {
    const PAGE = filemap.PAGE_SIZE;
    const r = G2Region{
        .base = 0x400000,
        .num_pages = 4,
        .active = true,
        .file_kind = 2,
        .prot = filemap.PROT_READ | filemap.PROT_WRITE,
        .file_offset = 0,
        .file_size = 10000,
    };
    // Page 0: full page from the file, COW-shared (PROT_WRITE, MAP_PRIVATE).
    var p = filemap.planFault(G2Region, &r, 0x400000);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expectEqual(@as(u64, 0), p.file_off);
    try std.testing.expectEqual(@as(u32, 4096), p.valid_bytes);
    try std.testing.expect(p.cow);
    try std.testing.expect(!p.executable);
    // Page 2: partial last page — 10000 - 8192 = 1808 valid bytes, tail zeroed.
    p = filemap.planFault(G2Region, &r, 0x400000 + 2 * PAGE);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expectEqual(@as(u64, 8192), p.file_off);
    try std.testing.expectEqual(@as(u32, 1808), p.valid_bytes);
    // Page 3: wholly past EOF → SIGSEGV (Linux SIGBUS semantics).
    p = filemap.planFault(G2Region, &r, 0x400000 + 3 * PAGE);
    try std.testing.expect(p.action == .segv);

    // PROT_READ mapping: shared read-only, no COW marker.
    const r_ro = G2Region{ .base = 0x400000, .num_pages = 1, .active = true, .file_kind = 2, .prot = filemap.PROT_READ, .file_offset = 0, .file_size = 4096 };
    p = filemap.planFault(G2Region, &r_ro, 0x400000);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expect(!p.cow);

    // Non-zero mmap offset shifts the mapped window into the file.
    const r_off = G2Region{ .base = 0x400000, .num_pages = 2, .active = true, .file_kind = 3, .prot = filemap.PROT_READ, .file_offset = 8192, .file_size = 16384 };
    p = filemap.planFault(G2Region, &r_off, 0x400000 + PAGE);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expectEqual(@as(u64, 12288), p.file_off);
    try std.testing.expectEqual(@as(u32, 4096), p.valid_bytes);

    // PROT_EXEC keeps NX clear; read+exec is not COW.
    const r_x = G2Region{ .base = 0x400000, .num_pages = 1, .active = true, .file_kind = 3, .prot = filemap.PROT_READ | filemap.PROT_EXEC, .file_offset = 0, .file_size = 4096 };
    p = filemap.planFault(G2Region, &r_x, 0x400000);
    try std.testing.expect(p.executable);
    try std.testing.expect(!p.cow);
}

test "G2: munmap head-trim advances the file offset" {
    try std.testing.expectEqual(@as(u64, 8192), filemap.advanceFileOffset(0, 2));
    try std.testing.expectEqual(@as(u64, 12288), filemap.advanceFileOffset(4096, 2));
    try std.testing.expectEqual(@as(u64, 0), filemap.advanceFileOffset(0, 0));
}

test "G2: region merging is only valid between anonymous regions" {
    try std.testing.expect(filemap.canMergeAnon(0, 0));
    try std.testing.expect(!filemap.canMergeAnon(0, 2));
    try std.testing.expect(!filemap.canMergeAnon(3, 0));
    try std.testing.expect(!filemap.canMergeAnon(3, 3));
}

test "G2: PTE synthesis for shared file frames and private copies" {
    const phys: u64 = 0x12345000;

    // Writable MAP_PRIVATE: present+user, read-only, COW marker, NX.
    var pte = filemap.filePte(phys, true, false);
    try std.testing.expectEqual(phys, pte & filemap.PTE_ADDR_MASK);
    try std.testing.expect(pte & filemap.PTE_PRESENT != 0);
    try std.testing.expect(pte & filemap.PTE_USER != 0);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);
    try std.testing.expect(pte & filemap.PTE_COW != 0);
    try std.testing.expect(pte & filemap.PTE_NX != 0);

    // Read-only shared frame: no COW, no writable.
    pte = filemap.filePte(phys, false, false);
    try std.testing.expect(pte & filemap.PTE_COW == 0);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);

    // Executable mapping keeps NX clear.
    pte = filemap.filePte(phys, false, true);
    try std.testing.expect(pte & filemap.PTE_NX == 0);

    // Private copy honours prot, never carries the COW marker.
    pte = filemap.privatePte(phys, filemap.PROT_READ | filemap.PROT_WRITE);
    try std.testing.expectEqual(phys, pte & filemap.PTE_ADDR_MASK);
    try std.testing.expect(pte & filemap.PTE_WRITABLE != 0);
    try std.testing.expect(pte & filemap.PTE_COW == 0);
    try std.testing.expect(pte & filemap.PTE_NX != 0);
    pte = filemap.privatePte(phys, filemap.PROT_READ);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);
}
// ─── end file mmap (G2) ───

// ─── MAP_SHARED (H1) ───

test "H1: sharedPte maps the backing frame writable per prot, never COW" {
    const phys: u64 = 0x45670000;

    // Writable shared mapping: present+user+writable, no COW, NX.
    var pte = filemap.sharedPte(phys, filemap.PROT_READ | filemap.PROT_WRITE);
    try std.testing.expectEqual(phys, pte & filemap.PTE_ADDR_MASK);
    try std.testing.expect(pte & filemap.PTE_PRESENT != 0);
    try std.testing.expect(pte & filemap.PTE_USER != 0);
    try std.testing.expect(pte & filemap.PTE_WRITABLE != 0);
    try std.testing.expect(pte & filemap.PTE_COW == 0);
    try std.testing.expect(pte & filemap.PTE_NX != 0);

    // Read-only shared mapping: not writable, still no COW.
    pte = filemap.sharedPte(phys, filemap.PROT_READ);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);
    try std.testing.expect(pte & filemap.PTE_COW == 0);

    // Executable shared mapping keeps NX clear.
    pte = filemap.sharedPte(phys, filemap.PROT_READ | filemap.PROT_EXEC);
    try std.testing.expect(pte & filemap.PTE_NX == 0);
}

test "H1: planFault suppresses COW and requests writable shared frames" {
    const PAGE = filemap.PAGE_SIZE;
    const r = G2Region{
        .base = 0x400000,
        .num_pages = 2,
        .active = true,
        .file_kind = 2,
        .prot = filemap.PROT_READ | filemap.PROT_WRITE,
        .file_offset = 0,
        .file_size = 8192,
        .shared = true,
    };
    // Writable MAP_SHARED: no COW marker, direct writable shared frame.
    var p = filemap.planFault(G2Region, &r, 0x400000);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expect(!p.cow);
    try std.testing.expect(p.shared_write);

    // Read-only MAP_SHARED: shared frame, but not writable.
    const r_ro = G2Region{ .base = 0x400000, .num_pages = 1, .active = true, .file_kind = 2, .prot = filemap.PROT_READ, .file_offset = 0, .file_size = 4096, .shared = true };
    p = filemap.planFault(G2Region, &r_ro, 0x400000);
    try std.testing.expect(!p.cow);
    try std.testing.expect(!p.shared_write);

    // EOF rule is unchanged for shared mappings.
    const r_eof = G2Region{ .base = 0x400000, .num_pages = 3, .active = true, .file_kind = 3, .prot = filemap.PROT_READ | filemap.PROT_WRITE, .file_offset = 0, .file_size = 2 * PAGE, .shared = true };
    p = filemap.planFault(G2Region, &r_eof, 0x400000 + 2 * PAGE);
    try std.testing.expect(p.action == .segv);
}

test "H1: mmap page-cache keys live in a flagged 4K namespace" {
    // The FS read paths key the page cache per FS block (e.g. 1KiB ext2
    // blocks); mmap pages must not collide with those entries.
    const key = filemap.mmapCacheKey(7);
    try std.testing.expect(key & filemap.MMAP_CACHE_FLAG != 0);
    try std.testing.expectEqual(@as(u64, 7), filemap.mmapCachePage(key));
    try std.testing.expectEqual(@as(u64, 0), filemap.mmapCachePage(filemap.mmapCacheKey(0)));
    // Stripping is idempotent for unflagged keys (flush callback contract).
    try std.testing.expectEqual(@as(u64, 42), filemap.mmapCachePage(42));
}

test "H1: planProtUpdate classifies mprotect overlap shapes" {
    const PAGE = filemap.PAGE_SIZE;
    const R = 0x800000; // region base, 4 pages

    // No overlap.
    var plan = filemap.planProtUpdate(R, 4, 0x900000, 2);
    try std.testing.expect(plan.overlap == .none);
    try std.testing.expectEqual(@as(u8, 0), plan.slots_needed);

    // Full cover: no split, one extra slot never needed.
    plan = filemap.planProtUpdate(R, 4, R, 4);
    try std.testing.expect(plan.overlap == .cover);
    try std.testing.expectEqual(@as(u64, 4), plan.mid_pages);
    try std.testing.expectEqual(@as(u8, 0), plan.slots_needed);
    plan = filemap.planProtUpdate(R, 4, R - PAGE, 6); // range larger than region
    try std.testing.expect(plan.overlap == .cover);

    // Head overlap: [R, R+2P) protected, tail keeps old prot.
    plan = filemap.planProtUpdate(R, 4, R, 2);
    try std.testing.expect(plan.overlap == .head);
    try std.testing.expectEqual(@as(u64, 2), plan.mid_pages);
    try std.testing.expectEqual(@as(u64, 2), plan.tail_pages);
    try std.testing.expectEqual(@as(u8, 1), plan.slots_needed);

    // Tail overlap: head keeps old prot, [R+2P, R+4P) protected.
    plan = filemap.planProtUpdate(R, 4, R + 2 * PAGE, 2);
    try std.testing.expect(plan.overlap == .tail);
    try std.testing.expectEqual(@as(u64, 2), plan.head_pages);
    try std.testing.expectEqual(@as(u64, 2), plan.mid_pages);
    try std.testing.expectEqual(@as(u8, 1), plan.slots_needed);

    // Middle: three pieces, two extra slots.
    plan = filemap.planProtUpdate(R, 4, R + PAGE, 2);
    try std.testing.expect(plan.overlap == .middle);
    try std.testing.expectEqual(@as(u64, 1), plan.head_pages);
    try std.testing.expectEqual(@as(u64, 2), plan.mid_pages);
    try std.testing.expectEqual(@as(u64, 1), plan.tail_pages);
    try std.testing.expectEqual(@as(u8, 2), plan.slots_needed);
}

test "H1: inSharedFileRegion matches only shared file regions" {
    const regions = [_]G2Region{
        .{ .base = 0x1000, .num_pages = 2, .active = true, .file_kind = 2, .shared = true },
        .{ .base = 0x4000, .num_pages = 2, .active = true, .file_kind = 2, .shared = false }, // private
        .{ .base = 0x8000, .num_pages = 2, .active = true, .file_kind = 0, .shared = true }, // anonymous
        .{ .base = 0xc000, .num_pages = 2, .active = false, .file_kind = 3, .shared = true }, // inactive
    };
    try std.testing.expect(filemap.inSharedFileRegion(G2Region, &regions, 0x1000));
    try std.testing.expect(filemap.inSharedFileRegion(G2Region, &regions, 0x2fff));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0x3000));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0x4000));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0x8000));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0xc000));
}

test "H1: mremap file grow extends the demand-fault window" {
    const PAGE = filemap.PAGE_SIZE;
    const g = filemap.fileGrowRange(0x400000, 2, 5);
    try std.testing.expectEqual(@as(u64, 0x400000 + 2 * PAGE), g.start);
    try std.testing.expectEqual(@as(u64, 3), g.pages);

    // A grown region keeps faulting through planFault: new pages inside the
    // recorded file size are served from the file, pages wholly past EOF
    // SIGSEGV (growth past EOF is allowed but faults on access, like Linux).
    const grown = G2Region{
        .base = 0x400000,
        .num_pages = 5, // after fileGrowRange
        .active = true,
        .file_kind = 3,
        .prot = filemap.PROT_READ,
        .file_offset = 0,
        .file_size = 3 * PAGE, // file only covers 3 pages
        .shared = true,
    };
    var p = filemap.planFault(G2Region, &grown, 0x400000 + 2 * PAGE);
    try std.testing.expect(p.action == .file_page); // newly covered, in file
    p = filemap.planFault(G2Region, &grown, 0x400000 + 3 * PAGE);
    try std.testing.expect(p.action == .segv); // growth past EOF
}
// ─── end MAP_SHARED (H1) ───

// ─── PCID (P1) ───
// Pure PCID bookkeeping: 12-bit allocator, pml4→PCID registry with
// invalidation generations, CR3 composition and the context-switch decision.
const pcid_alloc = kt.pcid_alloc;
const SwitchAction = pcid_alloc.SwitchAction;

test "P1: composeCr3 packs phys, pcid and the no-flush bit" {
    const phys: u64 = 0x0000_0000_1234_5000;
    // Legacy flush write: PCID in the low 12 bits, no bit 63.
    try std.testing.expectEqual(phys | 7, pcid_alloc.composeCr3(phys, 7, false));
    // No-flush write sets CR3 bit 63.
    try std.testing.expectEqual(phys | 7 | (@as(u64, 1) << 63), pcid_alloc.composeCr3(phys, 7, true));
    // PCID is masked to 12 bits; phys is masked to the address bits.
    try std.testing.expectEqual(phys | 0x0FFF, pcid_alloc.composeCr3(phys, 0x1FFF, false));
    try std.testing.expectEqual(@as(u64, 0x000F_FFFF_FFFF_FFFF), pcid_alloc.composeCr3(0xFFFF_FFFF_FFFF_FFFF, 0x0FFF, false));
    // Kernel PCID 0 with flush is the plain legacy value.
    try std.testing.expectEqual(phys, pcid_alloc.composeCr3(phys, 0, false));
}

test "P1: allocator hands out 1..4095, never 0, and recycles freed IDs" {
    var a: pcid_alloc.PcidAllocator = .{};
    const first = a.alloc().?;
    try std.testing.expect(first >= 1);
    const second = a.alloc().?;
    try std.testing.expect(first != second);

    a.free(first);
    // The freed ID is reusable; it must surface again within a full cycle.
    var seen_reuse = false;
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        const p = a.alloc() orelse break;
        if (p == first) seen_reuse = true;
    }
    try std.testing.expect(seen_reuse);
}

test "P1: allocator exhausts at 4095 live IDs and frees reopen exactly one slot" {
    var a: pcid_alloc.PcidAllocator = .{};
    var count: u32 = 0;
    while (a.alloc()) |_| count += 1;
    try std.testing.expectEqual(@as(u32, 4095), count);
    try std.testing.expect(a.alloc() == null);

    a.free(1234);
    try std.testing.expectEqual(@as(?u16, 1234), a.alloc());
    try std.testing.expect(a.alloc() == null);
}

test "P1: registry maps pml4 to pcid; unregister frees the ID and bumps its generation" {
    var c: pcid_alloc.PcidCore = .{};
    const p1 = c.registerSpace(0x100000).?;
    try std.testing.expect(p1 >= 1);
    try std.testing.expectEqual(p1, c.pcidFor(0x100000).?);
    try std.testing.expect(c.pcidFor(0x200000) == null);

    const g_before = c.generation(p1);
    const freed = c.unregisterSpace(0x100000).?;
    try std.testing.expectEqual(p1, freed);
    // Reuse-invalidation: the freed PCID's generation moved on, so any CPU
    // still holding stale entries observes the change and flushes.
    try std.testing.expect(c.generation(p1) > g_before);
    try std.testing.expect(c.pcidFor(0x100000) == null);
    try std.testing.expect(c.unregisterSpace(0x100000) == null);

    // The recycled PCID is handed out again, with the bumped generation kept.
    const p2 = c.registerSpace(0x200000).?;
    try std.testing.expectEqual(p1, p2);
    try std.testing.expect(c.generation(p2) > g_before);
}

test "P1: noteShootdown bumps only the owning PCID's generation" {
    var c: pcid_alloc.PcidCore = .{};
    const p = c.registerSpace(0x400000).?;
    const q = c.registerSpace(0x500000).?;
    const g0 = c.generation(p);
    c.noteShootdown(0x400000);
    try std.testing.expectEqual(g0 + 1, c.generation(p));
    try std.testing.expectEqual(@as(u64, 0), c.generation(q));
    // Unknown space: no-op, no crash.
    c.noteShootdown(0x999000);
    try std.testing.expectEqual(g0 + 1, c.generation(p));
}

test "P1: decideSwitch — skip / no-flush / flush matrix" {
    const d = pcid_alloc.decideSwitch;
    const A: u64 = 0xAAAA000;
    const B: u64 = 0xBBBB000;
    // Same space already loaded on this CPU: no CR3 write at all.
    try std.testing.expectEqual(SwitchAction.skip, d(5, A, 0, 0, A, 5, 9));
    // Kernel/unregistered target (PCID 0): legacy flush write.
    try std.testing.expectEqual(SwitchAction.flush, d(5, A, 0, 0, 0x100000, 0, 0));
    // A→B→A with unchanged generation: no-flush fast path.
    try std.testing.expectEqual(SwitchAction.no_flush, d(7, B, 5, 9, A, 5, 9));
    // Generation moved (shootdown or PCID reuse): must flush.
    try std.testing.expectEqual(SwitchAction.flush, d(7, B, 5, 9, A, 5, 10));
    // Different space, no previous record: flush.
    try std.testing.expectEqual(SwitchAction.flush, d(7, B, 0, 0, A, 5, 9));
    // PCID matches but CR3 does not (stale record): must not skip.
    try std.testing.expect(d(5, B, 0, 0, A, 5, 9) != SwitchAction.skip);
}

test "P1: registry refuses more than MAX_SPACES live spaces" {
    var c: pcid_alloc.PcidCore = .{};
    var i: usize = 0;
    while (i < pcid_alloc.MAX_SPACES) : (i += 1) {
        try std.testing.expect(c.registerSpace(0x1000 * @as(u64, i + 1)) != null);
    }
    try std.testing.expect(c.registerSpace(0xDEAD000) == null);
}
// ─── end PCID (P1) ───

// ─── NVMe per-CPU (I3) ───
const nvme_queue = kt.nvme_queue;

test "I3: pickQueue prefers the submitting CPU's own queue" {
    const pick = nvme_queue.pickQueue;
    // Preferred channel free → cpu_id % num_queues, rr_hint irrelevant.
    try std.testing.expectEqual(@as(u32, 2), pick(2, 4, 0b1001, 9));
    try std.testing.expectEqual(@as(u32, 0), pick(0, 4, 0b1110, 3));
    // cpu_id wraps modulo the queue count.
    try std.testing.expectEqual(@as(u32, 2), pick(6, 4, 0, 0));
    try std.testing.expectEqual(@as(u32, 3), pick(7, 4, 0, 12));
}

test "I3: pickQueue falls back to round-robin when the preferred channel is busy" {
    const pick = nvme_queue.pickQueue;
    // Bit 2 set (queue 2 busy) → rr_hint % num_queues.
    try std.testing.expectEqual(@as(u32, 1), pick(2, 4, 0b0100, 9));
    // Writeback/boot submitter (cpu 0) with queue 0 busy → fallback too.
    try std.testing.expectEqual(@as(u32, 3), pick(0, 4, 0b0001, 3));
    // Every channel busy → still the round-robin answer (submitter parks
    // there instead of serializing behind its preferred queue).
    try std.testing.expectEqual(@as(u32, 2), pick(3, 4, 0b1111, 6));
    // Busy bits above num_queues are ignored.
    try std.testing.expectEqual(@as(u32, 1), pick(1, 2, 0b1000, 5));
}

test "I3: pickQueue degenerate queue counts" {
    const pick = nvme_queue.pickQueue;
    // Single queue: always 0, whatever the CPU and busy state.
    try std.testing.expectEqual(@as(u32, 0), pick(5, 1, 0b1, 7));
    try std.testing.expectEqual(@as(u32, 0), pick(5, 1, 0, 7));
    // No queues yet (pre-init): 0, no division by zero.
    try std.testing.expectEqual(@as(u32, 0), pick(5, 0, 0, 7));
}
// ─── end NVMe per-CPU (I3) ───

// ─── user huge pages (I1) ───
// Pure 2MiB huge-page helpers: eligibility and the demote decomposition
// (2MiB PDE → 512 4K PTEs mirroring phys+flags). Runtime wiring (map on
// mmap, demote-first on partial mutations) is verified by user/hello49.
const huge_user = kt.huge_user;

test "I1: eligibility requires 2MiB-aligned base and at least 512 pages" {
    try std.testing.expect(!huge_user.eligible(0x400000, 511)); // too small
    try std.testing.expect(huge_user.eligible(0x400000, 512)); // exactly one block
    try std.testing.expect(huge_user.eligible(0x400000, 1024));
    try std.testing.expect(!huge_user.eligible(0x401000, 1024)); // 4K-aligned only
    try std.testing.expect(!huge_user.eligible(0x500000, 4096)); // 1MiB-misaligned
    try std.testing.expect(huge_user.eligible(0x600000, 4096)); // 2MiB-aligned
}

test "I1: hugeBlocksFor counts only full 2MiB blocks" {
    try std.testing.expectEqual(@as(u64, 0), huge_user.hugeBlocksFor(0));
    try std.testing.expectEqual(@as(u64, 0), huge_user.hugeBlocksFor(511));
    try std.testing.expectEqual(@as(u64, 1), huge_user.hugeBlocksFor(512));
    try std.testing.expectEqual(@as(u64, 1), huge_user.hugeBlocksFor(1023));
    try std.testing.expectEqual(@as(u64, 2), huge_user.hugeBlocksFor(1024));
}

test "I1: demotePtes mirrors phys+flags over 512 PTEs, drops the huge bit" {
    const NX: u64 = 1 << 63;
    // Huge PDE: present|writable|user|huge|NX, phys 0x200000 (2MiB-aligned).
    const pde: u64 = 0x200000 | huge_user.PRESENT | huge_user.WRITABLE |
        huge_user.USER | huge_user.HUGE_BIT | NX;
    var out: [512]u64 = undefined;
    _ = huge_user.demotePtes(pde, &out, 0x100000);

    for (0..512) |i| {
        const expect_phys = 0x200000 + @as(u64, @intCast(i)) * huge_user.PAGE_SIZE;
        try std.testing.expectEqual(expect_phys, out[i] & huge_user.ADDR_MASK);
        try std.testing.expect(out[i] & huge_user.PRESENT != 0);
        try std.testing.expect(out[i] & huge_user.WRITABLE != 0);
        try std.testing.expect(out[i] & huge_user.USER != 0);
        try std.testing.expect(out[i] & NX != 0); // NX preserved
        try std.testing.expect(out[i] & huge_user.HUGE_BIT == 0); // huge bit gone
    }
}

test "I1: demotePtes replacement PDE is a PT pointer inheriting p/w/u" {
    const pde_ro: u64 = 0x400000 | huge_user.PRESENT | huge_user.USER | huge_user.HUGE_BIT;
    var out: [512]u64 = undefined;
    const new_pde = huge_user.demotePtes(pde_ro, &out, 0x300000);

    try std.testing.expectEqual(@as(u64, 0x300000), new_pde & huge_user.ADDR_MASK);
    try std.testing.expect(new_pde & huge_user.PRESENT != 0);
    try std.testing.expect(new_pde & huge_user.USER != 0);
    try std.testing.expect(new_pde & huge_user.WRITABLE == 0); // was read-only
    try std.testing.expect(new_pde & huge_user.HUGE_BIT == 0); // a table, not data

    // Read-only huge page demotes to read-only 4K PTEs.
    try std.testing.expect(out[0] & huge_user.WRITABLE == 0);
    try std.testing.expect(out[511] & huge_user.PRESENT != 0);
}
// ─── end user huge pages (I1) ───

// ─── kmsg blocking (J3) ───
// Pure availability helper behind blocking /dev/kmsg reads and the
// cursor-accurate epoll EPOLLIN: bytesAvailable(total, cursor) tells a
// reader at absolute `cursor` how many bytes a stream ending at `total`
// still has for it. Stale cursors (older than the oldest surviving byte)
// report the full absolute backlog — the read path clamps them forward,
// and for block/epoll decisions only "zero vs non-zero" matters.

test "J3: bytesAvailable is zero when caught up or ahead" {
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(0, 0)); // empty stream
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(20, 20)); // at newest byte
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(20, 25)); // cursor in the future
}

test "J3: bytesAvailable counts the unread backlog" {
    try std.testing.expectEqual(@as(u64, 15), kmsg_ring.bytesAvailable(20, 5));
    try std.testing.expectEqual(@as(u64, 20), kmsg_ring.bytesAvailable(20, 0));
    // Stale cursor (bytes already overwritten): reports the full absolute
    // backlog — read() clamps forward, availability is what epoll needs.
    try std.testing.expectEqual(@as(u64, 90), kmsg_ring.bytesAvailable(100, 10));
}

test "J3: bytesAvailable tracks a live ring's newest position" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    ring.appendLine("[INF] one\n");
    ring.appendLine("[DBG] two\n");
    const total = ring.newestPos();
    try std.testing.expectEqual(@as(u64, 20), total);
    // Fresh reader at cursor 0 sees everything; a caught-up reader sees 0.
    try std.testing.expectEqual(@as(u64, 20), kmsg_ring.bytesAvailable(total, 0));
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(total, total));
    // Mid-stream cursor: exactly the second line remains.
    try std.testing.expectEqual(@as(u64, 10), kmsg_ring.bytesAvailable(total, 10));
    // After another append the same cursor has the new line too.
    ring.appendLine("[ERR] x\n");
    try std.testing.expectEqual(@as(u64, 18), kmsg_ring.bytesAvailable(ring.newestPos(), 10));
}
// ─── end kmsg blocking (J3) ───

// ─── sched claim (J2) ───
// Atomic task-claim protocol behind the fine-grained scheduler: a CPU may run
// a task only after winning the .ready → .running cmpxchg on its state word.
// These tests pin the contention matrix: exactly-one-winner, claim against
// blocked/zombie/running states, and release refusal when the task blocked or
// exited underneath an in-flight switch.
const sched_claim = kt.sched_claim;
const ClaimState = sched_claim.TaskState;

test "J2: tryClaim wins exactly once from ready" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.running, sched_claim.load(&s));
    // A second CPU claiming the same task must lose, leaving state untouched.
    try std.testing.expect(!sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.running, sched_claim.load(&s));
}

test "J2: tryClaim refuses blocked and zombie tasks without disturbing them" {
    var s: ClaimState = .blocked;
    try std.testing.expect(!sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.blocked, sched_claim.load(&s));

    sched_claim.store(&s, .zombie);
    try std.testing.expect(!sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.zombie, sched_claim.load(&s));
}

test "J2: releaseToReady round-trips a claim" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    try std.testing.expect(sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.ready, sched_claim.load(&s));
    // The task is claimable again afterwards (re-pick after preemption).
    try std.testing.expect(sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.running, sched_claim.load(&s));
}

test "J2: releaseToReady refuses a task that blocked underneath the switch" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    // The running task blocks itself (futex/waitpid) while the switch is in
    // flight: the release must fail and must NOT resurrect it to .ready.
    sched_claim.store(&s, .blocked);
    try std.testing.expect(!sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.blocked, sched_claim.load(&s));
    // A blocked task stays unclaimable until a wake publishes it.
    try std.testing.expect(!sched_claim.tryClaim(&s));
    sched_claim.store(&s, .ready); // wake path: blocked → ready
    try std.testing.expect(sched_claim.tryClaim(&s));
}

test "J2: releaseToReady refuses a zombie (exited during the switch window)" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    sched_claim.store(&s, .zombie);
    try std.testing.expect(!sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.zombie, sched_claim.load(&s));
    try std.testing.expect(!sched_claim.tryClaim(&s));
}

test "J2: releaseToReady refuses an unclaimed (ready) task" {
    // Releasing a task nobody owns would be a protocol bug: ready stays ready.
    var s: ClaimState = .ready;
    try std.testing.expect(!sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.ready, sched_claim.load(&s));
}

test "J2: contended cmpxchg claims grant exclusive ownership" {
    // N hammering threads × M rounds: a won claim must imply sole ownership
    // (nobody else inside the claimed section), and every claim is released.
    const THREADS = 4;
    const ROUNDS = 5000;
    const Shared = struct {
        state: ClaimState = .ready,
        in_section: u32 = 0,
        overlap: u32 = 0,
        claimed: u32 = 0,
        released: u32 = 0,
    };
    var shared: Shared = .{};
    const Worker = struct {
        fn run(sh: *Shared) void {
            var i: u32 = 0;
            while (i < ROUNDS) : (i += 1) {
                if (!sched_claim.tryClaim(&sh.state)) continue;
                // Claim won: we must be the sole owner.
                if (@atomicRmw(u32, &sh.in_section, .Xchg, 1, .seq_cst) != 0) {
                    @atomicStore(u32, &sh.overlap, 1, .seq_cst);
                }
                _ = @atomicRmw(u32, &sh.claimed, .Add, 1, .seq_cst);
                // Leave the exclusive section BEFORE releasing: the state is
                // still .running (ours), so no new claim can sneak in.
                @atomicStore(u32, &sh.in_section, 0, .seq_cst);
                // The owner always releases successfully (nothing else can
                // move a claimed task out of .running).
                if (!sched_claim.releaseToReady(&sh.state)) {
                    @atomicStore(u32, &sh.overlap, 1, .seq_cst);
                }
                _ = @atomicRmw(u32, &sh.released, .Add, 1, .seq_cst);
            }
        }
    };
    var threads: [THREADS]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{&shared});
    for (&threads) |*th| th.join();

    try std.testing.expectEqual(@as(u32, 0), shared.overlap);
    try std.testing.expectEqual(shared.claimed, shared.released);
    try std.testing.expect(shared.claimed > 0);
    // All claims released: the task ends up .ready, never stuck .running.
    try std.testing.expectEqual(ClaimState.ready, sched_claim.load(&shared.state));
}
// ─── end sched claim (J2) ───
// ─── dcache (K1) ───
const dcache = kt.dcache;

// Find a parent id whose (fs, parent, name) key lands on the same direct-mapped
// slot as `ref_parent` for the same name — deterministic conflict generator.
fn dcacheConflictingParent(fs: dcache.FsKind, name: []const u8, ref_parent: u32) u32 {
    const h = dcache.hashName(name);
    const want = dcache.slotFor(fs, ref_parent, h);
    var p: u32 = ref_parent + 1;
    while (p != ref_parent) : (p +%= 1) {
        if (dcache.slotFor(fs, p, h) == want) return p;
    }
    unreachable; // 512 slots, u32 parents — a collision always exists
}

test "K1: lookup on empty cache misses" {
    dcache.resetPure();
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "hello") == null);
    try std.testing.expect(dcache.lookupPure(.fat32, 2, "hello") == null);
}

test "K1: fill then lookup hits and returns the child" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 2, "foo", 1234);
    try std.testing.expectEqual(@as(?u32, 1234), dcache.lookupPure(.ext2, 2, "foo"));
    // Wrong parent / wrong fs / wrong name all miss (full key compare).
    try std.testing.expect(dcache.lookupPure(.ext2, 3, "foo") == null);
    try std.testing.expect(dcache.lookupPure(.fat32, 2, "foo") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "fop") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "fo") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "fooo") == null);
}

test "K1: same name under different parents and filesystems stays distinct" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 10, "name", 100);
    dcache.fillPure(.ext2, 20, "name", 200);
    dcache.fillPure(.fat32, 10, "name", 7);
    try std.testing.expectEqual(@as(?u32, 100), dcache.lookupPure(.ext2, 10, "name"));
    try std.testing.expectEqual(@as(?u32, 200), dcache.lookupPure(.ext2, 20, "name"));
    try std.testing.expectEqual(@as(?u32, 7), dcache.lookupPure(.fat32, 10, "name"));
}

test "K1: conflict on the same slot replaces the old entry" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 1000, "conflict", 111);
    const p2 = dcacheConflictingParent(.ext2, "conflict", 1000);
    dcache.fillPure(.ext2, p2, "conflict", 222);
    // Direct-mapped replace-on-conflict: the older entry is gone.
    try std.testing.expect(dcache.lookupPure(.ext2, 1000, "conflict") == null);
    try std.testing.expectEqual(@as(?u32, 222), dcache.lookupPure(.ext2, p2, "conflict"));
}

test "K1: same-slot different-name lookup misses (full name compare)" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 500, "alpha", 42);
    const p2 = dcacheConflictingParent(.ext2, "beta", 500);
    // (p2, "beta") hashes to alpha's slot but neither parent nor name match.
    try std.testing.expect(dcache.lookupPure(.ext2, p2, "beta") == null);
    // And the original entry is untouched by the failed lookup.
    try std.testing.expectEqual(@as(?u32, 42), dcache.lookupPure(.ext2, 500, "alpha"));
}

test "K1: invalidateParent drops only entries under that parent" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 11, "a", 1);
    dcache.fillPure(.ext2, 11, "b", 2);
    dcache.fillPure(.ext2, 12, "a", 3);
    dcache.fillPure(.fat32, 11, "a", 4);
    const dropped = dcache.invalidateParentPure(.ext2, 11);
    try std.testing.expectEqual(@as(u32, 2), dropped);
    try std.testing.expect(dcache.lookupPure(.ext2, 11, "a") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 11, "b") == null);
    try std.testing.expectEqual(@as(?u32, 3), dcache.lookupPure(.ext2, 12, "a"));
    try std.testing.expectEqual(@as(?u32, 4), dcache.lookupPure(.fat32, 11, "a"));
}

test "K1: invalidateFs drops every entry of one filesystem only" {
    dcache.resetPure();
    dcache.fillPure(.fat32, 2, "x", 9);
    dcache.fillPure(.fat32, 7, "y", 8);
    dcache.fillPure(.ext2, 2, "x", 5);
    _ = dcache.invalidateFsPure(.fat32);
    try std.testing.expect(dcache.lookupPure(.fat32, 2, "x") == null);
    try std.testing.expect(dcache.lookupPure(.fat32, 7, "y") == null);
    try std.testing.expectEqual(@as(?u32, 5), dcache.lookupPure(.ext2, 2, "x"));
}

test "K1: capacity is bounded at 512 with replace-on-conflict" {
    dcache.resetPure();
    var i: u32 = 0;
    while (i < dcache.CAPACITY * 3) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}", .{i}) catch unreachable;
        dcache.fillPure(.ext2, 2, name, i);
    }
    try std.testing.expect(dcache.countValidPure() <= dcache.CAPACITY);
    const st = dcache.statsPure();
    try std.testing.expectEqual(@as(u64, dcache.CAPACITY * 3), st.fills);
}

test "K1: overlong names are never cached" {
    dcache.resetPure();
    const long_name = "x" ** 300;
    dcache.fillPure(.ext2, 2, long_name, 77);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, long_name) == null);
    try std.testing.expectEqual(@as(u32, 0), dcache.countValidPure());
    dcache.fillPure(.ext2, 2, "", 1);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "") == null);
}

test "K1: stats count hits and misses" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 2, "stat", 55);
    _ = dcache.lookupPure(.ext2, 2, "stat"); // hit
    _ = dcache.lookupPure(.ext2, 2, "nope"); // miss
    const st = dcache.statsPure();
    try std.testing.expectEqual(@as(u64, 1), st.hits);
    try std.testing.expectEqual(@as(u64, 1), st.misses);
    try std.testing.expectEqual(@as(u64, 1), st.fills);
}
// ─── end dcache (K1) ───

// ─── slab magazine (K2) ───
// Pure per-CPU magazine bookkeeping from kernel/mm/slab_mag.zig: push/pop
// LIFO, batch refill/flush against a mock backing store, boundary behaviour,
// and the no-duplication/no-loss ownership invariant under a simulated
// kmalloc/kfree protocol. The kernel wiring (IRQ-off windows, pool locking)
// lives in kernel/mm/slab.zig; here only the lock-free core is exercised.
const slab_mag = kt.slab_mag;

const K2_NUM_OBJS = 64;

const K2MockPool = struct {
    storage: [K2_NUM_OBJS]u64 = undefined,
    free: [K2_NUM_OBJS]?*anyopaque = undefined,
    count: usize = 0,
    pops: u32 = 0,
    pushes: u32 = 0,

    fn init() K2MockPool {
        var p = K2MockPool{};
        for (0..K2_NUM_OBJS) |i| {
            p.storage[i] = i;
            p.free[i] = &p.storage[i];
        }
        p.count = K2_NUM_OBJS;
        return p;
    }

    pub fn popFree(self: *K2MockPool) ?*anyopaque {
        if (self.count == 0) return null;
        self.count -= 1;
        const obj = self.free[self.count];
        self.free[self.count] = null;
        self.pops += 1;
        return obj;
    }

    pub fn pushFree(self: *K2MockPool, obj: *anyopaque) void {
        self.free[self.count] = obj;
        self.count += 1;
        self.pushes += 1;
    }
};

/// Assert every mock object exists exactly once across pool, magazine and
/// `hands` (user-held) — the no-duplication / no-loss invariant.
fn k2ExpectConservation(pool: *K2MockPool, m: *slab_mag.Magazine, hands: []?*anyopaque) !void {
    var seen = [_]bool{false} ** K2_NUM_OBJS;
    for (pool.free[0..pool.count]) |o| {
        const idx = @as(*u64, @ptrCast(@alignCast(o.?))).*;
        try std.testing.expect(!seen[@intCast(idx)]);
        seen[@intCast(idx)] = true;
    }
    for (m.slots[0..m.count]) |o| {
        const idx = @as(*u64, @ptrCast(@alignCast(o.?))).*;
        try std.testing.expect(!seen[@intCast(idx)]);
        seen[@intCast(idx)] = true;
    }
    for (hands) |o| {
        if (o) |obj| {
            const idx = @as(*u64, @ptrCast(@alignCast(obj))).*;
            try std.testing.expect(!seen[@intCast(idx)]);
            seen[@intCast(idx)] = true;
        }
    }
    for (seen) |s| try std.testing.expect(s);
}

test "K2: magazine push/pop is LIFO and tracks count" {
    var m: slab_mag.Magazine = .{};
    try std.testing.expect(m.isEmpty());
    try std.testing.expectEqual(@as(?*anyopaque, null), m.pop());

    var a: u64 = 1;
    var b: u64 = 2;
    try std.testing.expect(m.push(&a));
    try std.testing.expect(m.push(&b));
    try std.testing.expectEqual(@as(u8, 2), m.len());
    try std.testing.expectEqual(@as(?*anyopaque, &b), m.pop());
    try std.testing.expectEqual(@as(?*anyopaque, &a), m.pop());
    try std.testing.expect(m.isEmpty());
}

test "K2: magazine boundary — full push fails, empty pop returns null" {
    var m: slab_mag.Magazine = .{};
    var objs: [slab_mag.MAG_SIZE]u64 = undefined;
    for (0..slab_mag.MAG_SIZE) |i| try std.testing.expect(m.push(&objs[i]));
    try std.testing.expect(m.isFull());
    try std.testing.expectEqual(@as(u8, slab_mag.MAG_SIZE), m.len());

    var extra: u64 = 0;
    try std.testing.expect(!m.push(&extra)); // full: refused, not overwritten
    try std.testing.expectEqual(@as(u8, slab_mag.MAG_SIZE), m.len());

    for (0..slab_mag.MAG_SIZE) |_| try std.testing.expect(m.pop() != null);
    try std.testing.expectEqual(@as(?*anyopaque, null), m.pop());
}

test "K2: refill moves a full batch from the pool" {
    var pool = K2MockPool.init();
    var m: slab_mag.Magazine = .{};
    const n = m.refill(&pool);
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH), n);
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH), m.len());
    try std.testing.expectEqual(K2_NUM_OBJS - slab_mag.REFILL_BATCH, pool.count);
    try std.testing.expectEqual(@as(u32, slab_mag.REFILL_BATCH), pool.pops);

    var hands = [_]?*anyopaque{null} ** K2_NUM_OBJS;
    try k2ExpectConservation(&pool, &m, &hands);
}

test "K2: refill is partial when the pool has fewer than a batch" {
    var pool = K2MockPool.init();
    // Drain the pool to REFILL_BATCH - 1 objects.
    for (0..K2_NUM_OBJS - (slab_mag.REFILL_BATCH - 1)) |_| _ = pool.popFree();
    var m: slab_mag.Magazine = .{};
    const n = m.refill(&pool);
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH - 1), n);
    try std.testing.expectEqual(@as(usize, 0), pool.count);
    // A second refill on an empty pool is a no-op.
    try std.testing.expectEqual(@as(u8, 0), m.refill(&pool));
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH - 1), m.len());
}

test "K2: flush moves half the magazine back to the pool" {
    var pool = K2MockPool.init();
    var m: slab_mag.Magazine = .{};
    _ = m.refill(&pool); // 4 in mag
    _ = m.refill(&pool); // 8 in mag (full)
    try std.testing.expect(m.isFull());

    const n = m.flush(&pool);
    try std.testing.expectEqual(@as(u8, slab_mag.FLUSH_BATCH), n);
    try std.testing.expectEqual(@as(u8, slab_mag.MAG_SIZE - slab_mag.FLUSH_BATCH), m.len());
    try std.testing.expectEqual(@as(u32, slab_mag.FLUSH_BATCH), pool.pushes);

    var hands = [_]?*anyopaque{null} ** K2_NUM_OBJS;
    try k2ExpectConservation(&pool, &m, &hands);
}

test "K2: flush on a non-full magazine flushes at most a batch" {
    var pool = K2MockPool.init();
    // Make room: the mock's backing array is exactly K2_NUM_OBJS deep.
    _ = pool.popFree();
    _ = pool.popFree();
    var m: slab_mag.Magazine = .{};
    var a: u64 = 0;
    var b: u64 = 0;
    _ = m.push(&a);
    _ = m.push(&b);
    const n = m.flush(&pool); // count < FLUSH_BATCH: flushes count
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expect(m.isEmpty());
    try std.testing.expectEqual(@as(usize, K2_NUM_OBJS), pool.count); // 62 + 2 flushed
}

test "K2: simulated kmalloc/kfree protocol conserves objects under stress" {
    // Mirror the slab.zig fast path: alloc = pop, refill-on-empty then pop;
    // free = push, flush-half-on-full then push.
    var pool = K2MockPool.init();
    var m: slab_mag.Magazine = .{};
    var hands = [_]?*anyopaque{null} ** K2_NUM_OBJS;

    var seed: u64 = 0x12345678;
    var live: usize = 0;
    var step: u32 = 0;
    while (step < 20000) : (step += 1) {
        // xorshift PRNG for a deterministic op mix.
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        const do_alloc = (seed & 1) == 0 or live == 0;

        if (do_alloc) {
            if (live == K2_NUM_OBJS) continue;
            var obj = m.pop();
            if (obj == null) {
                _ = m.refill(&pool);
                obj = m.pop();
            }
            if (obj) |o| { // pool OOM is possible: alloc returns null
                hands[live] = o;
                live += 1;
            }
        } else {
            live -= 1;
            const o = hands[live].?;
            hands[live] = null;
            if (!m.push(o)) {
                _ = m.flush(&pool);
                try std.testing.expect(m.push(o)); // post-flush push must fit
            }
        }
        if (step % 997 == 0) try k2ExpectConservation(&pool, &m, &hands);
    }
    try k2ExpectConservation(&pool, &m, &hands);
}

test "K2: batching parameters are consistent" {
    try std.testing.expectEqual(@as(usize, 8), slab_mag.MAG_SIZE);
    try std.testing.expectEqual(@as(usize, 4), slab_mag.REFILL_BATCH);
    try std.testing.expectEqual(@as(usize, 4), slab_mag.FLUSH_BATCH);
    try std.testing.expect(slab_mag.REFILL_BATCH <= slab_mag.MAG_SIZE);
    try std.testing.expect(slab_mag.FLUSH_BATCH < slab_mag.MAG_SIZE); // post-flush push always fits
}
// ─── end slab magazine (K2) ───


// ─── user driver framework (L1) ───
const userdrv_core = kt.userdrv_core;

test "L1: dev_map_mmio request validation" {
    // Well-formed MMIO request (e1000 BAR0-shaped): aligned, 128 KiB.
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateMmioRequest(0xFEBC0000, 0x20000));
    // Exactly the 16 MiB cap is accepted; one byte past it is not.
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateMmioRequest(0x100000, userdrv_core.MMIO_MAX_SIZE));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0x100000, userdrv_core.MMIO_MAX_SIZE + 1));
    // Zero size and non-page-aligned phys are rejected.
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFEBC0000, 0));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFEBC0123, 0x1000));
    // phys + size must not wrap the 64-bit address space.
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFFFFFFFFFFFFF000, 0x2000));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFFFFFFFFFFFFF000, 0x1000));
}

test "L1: MMIO-vs-RAM overlap detection" {
    // Fake machine: RAM is [0, 128 MiB), everything above is fair game.
    const ram = [_]userdrv_core.PhysRange{.{ .base = 0, .len = 0x8000000 }};
    // e1000 BAR0 / IOAPIC / LAPIC windows are not RAM.
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0xFEBC0000, 0x20000));
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0xFEC00000, 0x1000));
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0xFEE00000, 0x1000));
    // Plain RAM is rejected, including a range that only straddles the top.
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram, 0x100000, 0x1000));
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram, 0x7FFF000, 0x2000));
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram, 0, 0x1000));
    // Touching-but-not-overlapping (base == RAM top) is allowed.
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0x8000000, 0x1000));
    // Disjoint ranges in the list are each consulted.
    const ram2 = [_]userdrv_core.PhysRange{
        .{ .base = 0, .len = 0x9FC00 },
        .{ .base = 0x100000, .len = 0x7F00000 },
    };
    // The EBDA hole between the two RAM pieces is not RAM.
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram2, 0x9FC00, 0x1000));
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram2, 0x200000, 0x1000));
}

test "L1: IRQ table register/unregister/edge accounting" {
    var table: userdrv_core.IrqTable = .{};

    // PIC-only ceiling: GSI >= 16 cannot be routed without an IOAPIC.
    const PIC_MAX_GSI: u8 = 16;
    // A free GSI registers fine; the keyboard line is kernel-owned.
    const slot = try table.registerIrq(10, 7, false, PIC_MAX_GSI);
    try std.testing.expect(slot < userdrv_core.MAX_IRQ_SLOTS);
    try std.testing.expectError(error.KernelOwned, table.registerIrq(1, 7, true, PIC_MAX_GSI));
    try std.testing.expectError(error.Invalid, table.registerIrq(16, 7, false, PIC_MAX_GSI));
    // Same GSI twice (any owner) is busy.
    try std.testing.expectError(error.Busy, table.registerIrq(10, 8, false, PIC_MAX_GSI));

    // Edge counting is per-GSI and saturates instead of wrapping.
    try std.testing.expect(table.recordEdge(10));
    try std.testing.expect(table.recordEdge(10));
    try std.testing.expect(!table.recordEdge(9)); // not registered
    try std.testing.expectEqual(@as(u64, 2), table.find(10).?.edge_count);
    table.find(10).?.edge_count = std.math.maxInt(u64);
    try std.testing.expect(table.recordEdge(10));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), table.find(10).?.edge_count);

    // Only the owning task may unregister.
    try std.testing.expect(!table.unregisterIrq(10, 8));
    try std.testing.expect(table.unregisterIrq(10, 7));
    try std.testing.expect(!table.unregisterIrq(10, 7)); // already gone
    try std.testing.expect(table.find(10) == null);

    // The table holds exactly MAX_IRQ_SLOTS registrations.
    for (0..userdrv_core.MAX_IRQ_SLOTS) |i| {
        _ = try table.registerIrq(@intCast(3 + i), 7, false, PIC_MAX_GSI);
    }
    try std.testing.expectError(error.Full, table.registerIrq(15, 7, false, PIC_MAX_GSI));

    // Bulk release on task exit frees exactly that task's slots.
    try std.testing.expect(table.unregisterIrq(3, 7)); // make room
    _ = try table.registerIrq(0, 9, false, PIC_MAX_GSI); // owner 9 keeps its slot
    var released: [userdrv_core.MAX_IRQ_SLOTS]u8 = @splat(0xFF);
    const n = table.releaseAllForTask(7, &released);
    try std.testing.expectEqual(@as(u32, userdrv_core.MAX_IRQ_SLOTS - 1), n);
    try std.testing.expect(table.find(4) == null);
    try std.testing.expect(table.find(0) != null); // other owner untouched
    for (released[0..n]) |gsi| try std.testing.expect(gsi != 0xFF and gsi != 0);
}

test "M1: IRQ table routes GSI >= 16 once the IOAPIC ceiling is raised" {
    var table: userdrv_core.IrqTable = .{};
    // With an IOAPIC present the kernel passes the routable ceiling (e.g. 44
    // for the 100-127 user vector window); GSIs 16..43 then register fine and
    // the ceiling itself is still exclusive.
    const IOAPIC_MAX_GSI: u8 = 44;
    _ = try table.registerIrq(16, 7, false, IOAPIC_MAX_GSI);
    _ = try table.registerIrq(43, 7, false, IOAPIC_MAX_GSI);
    try std.testing.expectError(error.Invalid, table.registerIrq(44, 7, false, IOAPIC_MAX_GSI));
    try std.testing.expectError(error.KernelOwned, table.registerIrq(1, 7, true, IOAPIC_MAX_GSI));
    try std.testing.expect(table.recordEdge(16));
    try std.testing.expectEqual(@as(u64, 1), table.find(16).?.edge_count);
}

test "L1: dev_dma_alloc size validation" {
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateDmaSize(4096));
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateDmaSize(1));
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateDmaSize(userdrv_core.DMA_MAX_SIZE));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateDmaSize(0));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateDmaSize(userdrv_core.DMA_MAX_SIZE + 1));
}

test "L1: /dev/pci listing format" {
    const devs = [_]userdrv_core.PciInfo{
        .{
            .bus = 0, .device = 0, .function = 0,
            .vendor_id = 0x8086, .device_id = 0x1237,
            .class_code = 0x06, .subclass = 0x00, .irq_line = 0,
            .bars = .{ 0, 0, 0, 0, 0, 0 }, .bar_sizes = .{ 0, 0, 0, 0, 0, 0 },
        },
        .{
            .bus = 0, .device = 3, .function = 0,
            .vendor_id = 0x8086, .device_id = 0x100e,
            .class_code = 0x02, .subclass = 0x00, .irq_line = 11,
            .bars = .{ 0xFEBC0000, 0xC040, 0, 0, 0, 0 },
            .bar_sizes = .{ 0x20000, 0x40, 0, 0, 0, 0 },
        },
    };
    var buf: [512]u8 = undefined;
    const n = userdrv_core.genPciListing(&devs, &buf);
    try std.testing.expectEqualStrings(
        "00:00.0 8086:1237 class=06:00 irq=0\n" ++
            "00:03.0 8086:100e class=02:00 irq=11 bar0=febc0000+00020000 bar1=0000c040+00000040\n",
        buf[0..n],
    );
    // A tiny output buffer truncates cleanly (never overruns).
    var tiny: [8]u8 = undefined;
    const tn = userdrv_core.genPciListing(&devs, &tiny);
    try std.testing.expect(tn <= tiny.len);
}
// ─── end user driver framework (L1) ───

// ─── M1: IOAPIC redirection-table encode/decode (ioapic_core) ───

const ioapic_core = kt.ioapic_core;

test "M1: REDTBL encode matches the hardware bit layout" {
    // vector 0x64, dest APIC 1, masked: dest at bits 56-63, mask at bit 16.
    const raw = ioapic_core.encodeRedEntry(.{ .vector = 0x64, .dest_apic_id = 1, .masked = true });
    try std.testing.expectEqual(@as(u64, (1 << 56) | (1 << 16) | 0x64), raw);

    // Defaults are fixed-delivery, physical dest, edge, active-high: all zero.
    const unmasked = ioapic_core.encodeRedEntry(.{ .vector = 32, .dest_apic_id = 0, .masked = false });
    try std.testing.expectEqual(@as(u64, 32), unmasked);
}

test "M1: REDTBL encode/decode round-trips routing fields" {
    const raw = ioapic_core.encodeRedEntry(.{
        .vector = 117,
        .dest_apic_id = 3,
        .masked = false,
        .trigger = .level,
        .polarity = .active_low,
    });
    const d = ioapic_core.decodeRedEntry(raw);
    try std.testing.expectEqual(@as(u8, 117), d.vector);
    try std.testing.expectEqual(@as(u8, 3), d.dest_apic_id);
    try std.testing.expect(!d.masked);
    try std.testing.expectEqual(ioapic_core.Trigger.level, d.trigger);
    try std.testing.expectEqual(ioapic_core.Polarity.active_low, d.polarity);
}

test "M1: REDTBL mask toggle preserves vector and destination" {
    const routed = ioapic_core.encodeRedEntry(.{ .vector = 104, .dest_apic_id = 2, .masked = false });
    const masked = ioapic_core.setRedEntryMask(routed, true);
    try std.testing.expectEqual(@as(u8, 104), ioapic_core.redEntryVector(masked));
    const d = ioapic_core.decodeRedEntry(masked);
    try std.testing.expect(d.masked);
    try std.testing.expectEqual(@as(u8, 2), d.dest_apic_id);
    // Unmasking returns to the exact original entry.
    try std.testing.expectEqual(routed, ioapic_core.setRedEntryMask(masked, false));
}

// ─── M2: ioperm bitmap logic (ioperm_core) ───

const ioperm_core = kt.ioperm_core;

test "M2: ioperm range validation" {
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(0, 1));
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(0x70, 2));
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(0, 65536));
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(65535, 1));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(0, 0));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(65536, 1));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(65535, 2));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(0, 65537));
}

test "M2: fresh bitmap denies every port; enable/disable toggles bits" {
    var bitmap: ioperm_core.Bitmap = ioperm_core.denyAll();
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x70));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 65535));

    ioperm_core.setRange(&bitmap, 0x70, 2, true);
    try std.testing.expect(ioperm_core.isAllowed(&bitmap, 0x70));
    try std.testing.expect(ioperm_core.isAllowed(&bitmap, 0x71));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x6F));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x72));

    ioperm_core.setRange(&bitmap, 0x70, 2, false);
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x70));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x71));
}

test "M2: range enable crosses byte boundaries" {
    var bitmap: ioperm_core.Bitmap = ioperm_core.denyAll();
    ioperm_core.setRange(&bitmap, 6, 5, true); // ports 6..10 — spans bytes 0 and 1
    for (0..16) |p| {
        const expect_allowed = p >= 6 and p <= 10;
        try std.testing.expectEqual(expect_allowed, ioperm_core.isAllowed(&bitmap, @intCast(p)));
    }
}

test "M2: inherit copies the bitmap into independent storage" {
    var parent: ioperm_core.Bitmap = ioperm_core.denyAll();
    ioperm_core.setRange(&parent, 0x70, 2, true);

    var child: ioperm_core.Bitmap = ioperm_core.denyAll();
    ioperm_core.inherit(&child, &parent);
    try std.testing.expect(ioperm_core.isAllowed(&child, 0x70));
    try std.testing.expect(ioperm_core.isAllowed(&child, 0x71));
    try std.testing.expect(!ioperm_core.isAllowed(&child, 0x72));

    // Later parent changes must not leak into the child's copy (and back).
    ioperm_core.setRange(&parent, 0x70, 2, false);
    ioperm_core.setRange(&child, 0x3F8, 1, true);
    try std.testing.expect(ioperm_core.isAllowed(&child, 0x70));
    try std.testing.expect(!ioperm_core.isAllowed(&parent, 0x3F8));
}
