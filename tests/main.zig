const std = @import("std");

const byte_order = @import("byte_order");
const cow_pte = @import("cow_pte");
const fmt = @import("fmt_core");
const str = @import("str");

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
