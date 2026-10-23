const std = @import("std");
const gpt = @import("kernel_shared").gpt;

const path = "tests/fixtures/fs/datadisk_gpt.img";

fn load(buf: []u8) !void {
    const io = std.testing.io;
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const n = try f.readPositional(io, &.{buf}, 0);
    try std.testing.expectEqual(buf.len, n);
}

const DISK_SECTORS: u64 = 10 * 1024 * 1024 / 512;

test "protective MBR and header of a real sfdisk GPT" {
    var head: [34 * 512]u8 = undefined;
    try load(&head);
    try std.testing.expect(gpt.isProtectiveMbr(head[0..512]));
    const h = try gpt.parseHeader(head[512..1024], DISK_SECTORS);
    try std.testing.expectEqual(@as(u32, 128), h.entry_size);
    try std.testing.expect(h.entry_count >= 2 and h.entry_count <= gpt.MAX_ENTRIES);
    try std.testing.expectEqual(@as(u64, 2), h.entries_lba);
    const array = head[1024 .. 1024 + h.arrayBytes()];
    try std.testing.expect(gpt.arrayCrcOk(h, array));
}

test "partition extents match the table sfdisk wrote" {
    var head: [34 * 512]u8 = undefined;
    try load(&head);
    const h = try gpt.parseHeader(head[512..1024], DISK_SECTORS);
    const array = head[1024 .. 1024 + h.arrayBytes()];
    const p0 = gpt.entryAt(h, array, 0, DISK_SECTORS).?;
    try std.testing.expectEqual(@as(u64, 2048), p0.first_lba);
    try std.testing.expectEqual(@as(u64, 8192), p0.sectors);
    const p1 = gpt.entryAt(h, array, 1, DISK_SECTORS).?;
    try std.testing.expectEqual(@as(u64, 10240), p1.first_lba);
    try std.testing.expectEqual(@as(u64, 8192), p1.sectors);
    try std.testing.expect(gpt.entryAt(h, array, 2, DISK_SECTORS) == null); // unused
    try std.testing.expect(gpt.entryAt(h, array, 200, DISK_SECTORS) == null); // out of range
}

test "a damaged header or entry array is refused" {
    var head: [34 * 512]u8 = undefined;
    try load(&head);
    // flip a byte inside the header's checksummed region
    var bad = head;
    bad[512 + 40] ^= 1;
    try std.testing.expectError(error.BadHeader, gpt.parseHeader(bad[512..1024], DISK_SECTORS));
    // not a GPT at all
    var zero = [_]u8{0} ** 512;
    try std.testing.expectError(error.NotGpt, gpt.parseHeader(&zero, DISK_SECTORS));
    // entry array corruption is caught by the array CRC, not the header's
    const h = try gpt.parseHeader(head[512..1024], DISK_SECTORS);
    var arr: [128 * 128]u8 = undefined;
    @memcpy(&arr, head[1024..][0..arr.len]);
    arr[33] ^= 0x80;
    try std.testing.expect(!gpt.arrayCrcOk(h, &arr));
}

test "a header describing impossible geometry is rejected even with a valid CRC" {
    var head: [34 * 512]u8 = undefined;
    try load(&head);
    // disk smaller than the table claims
    try std.testing.expectError(error.BadGeometry, gpt.parseHeader(head[512..1024], 100));
    // re-sign a header whose entry size is nonsense
    var hdr: [512]u8 = head[512..1024].*;
    std.mem.writeInt(u32, hdr[84..88], 100, .little); // not a power of two
    std.mem.writeInt(u32, hdr[16..20], 0, .little);
    std.mem.writeInt(u32, hdr[16..20], gpt.crc32(hdr[0..92]), .little);
    try std.testing.expectError(error.BadGeometry, gpt.parseHeader(&hdr, DISK_SECTORS));
}

test "a classic MBR is not mistaken for a protective one" {
    var mbr = [_]u8{0} ** 512;
    mbr[510] = 0x55;
    mbr[511] = 0xAA;
    mbr[446 + 4] = 0x83;
    try std.testing.expect(!gpt.isProtectiveMbr(&mbr));
    mbr[446 + 16 + 4] = 0xEE;
    try std.testing.expect(gpt.isProtectiveMbr(&mbr));
}
