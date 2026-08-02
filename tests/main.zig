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
