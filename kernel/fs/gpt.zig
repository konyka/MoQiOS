//! GUID Partition Table reader — pure, no I/O. The caller hands over the
//! sectors; this validates and returns partition extents.
//!
//! A table is trusted only if its header and its entry array both match their
//! CRC32 and the geometry is self-consistent. The backup copy is not used: a
//! volume whose primary table is damaged is refused rather than guessed at.

const std = @import("std");

pub const SECTOR: usize = 512;
pub const MAX_ENTRIES: u32 = 128;

pub const Partition = struct {
    first_lba: u64,
    last_lba: u64,
    /// Sector count of the partition.
    sectors: u64,
    type_guid: [16]u8,
};

pub const Error = error{ NotGpt, BadHeader, BadEntries, BadGeometry };

fn r32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn r64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

pub fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

/// Does sector 0 look like a protective MBR (one entry of type 0xEE)?
pub fn isProtectiveMbr(sector0: *const [512]u8) bool {
    if (sector0[510] != 0x55 or sector0[511] != 0xAA) return false;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (sector0[446 + i * 16 + 4] == 0xEE) return true;
    }
    return false;
}

pub const Header = struct {
    entries_lba: u64,
    entry_count: u32,
    entry_size: u32,
    first_usable: u64,
    last_usable: u64,
    entries_crc: u32,

    /// Bytes occupied by the entry array.
    pub fn arrayBytes(self: Header) u64 {
        return @as(u64, self.entry_count) * self.entry_size;
    }
};

/// Validate the header in LBA 1 against a disk of `disk_sectors` sectors.
pub fn parseHeader(sec1: *const [512]u8, disk_sectors: u64) Error!Header {
    if (!std.mem.eql(u8, sec1[0..8], "EFI PART")) return error.NotGpt;
    const hdr_size = r32(sec1, 12);
    if (hdr_size < 92 or hdr_size > SECTOR) return error.BadHeader;
    const want_crc = r32(sec1, 16);
    var tmp: [512]u8 = sec1.*;
    @memset(tmp[16..20], 0);
    if (crc32(tmp[0..hdr_size]) != want_crc) return error.BadHeader;
    if (r64(sec1, 24) != 1) return error.BadHeader; // MyLBA must be this sector

    const h: Header = .{
        .first_usable = r64(sec1, 40),
        .last_usable = r64(sec1, 48),
        .entries_lba = r64(sec1, 72),
        .entry_count = r32(sec1, 80),
        .entry_size = r32(sec1, 84),
        .entries_crc = r32(sec1, 88),
    };
    // Entries are 128 << n bytes; real tables use 128.
    if (h.entry_size < 128 or h.entry_size > SECTOR or !std.math.isPowerOfTwo(h.entry_size)) return error.BadGeometry;
    if (h.entry_count == 0 or h.entry_count > MAX_ENTRIES) return error.BadGeometry;
    if (h.first_usable > h.last_usable or h.last_usable >= disk_sectors) return error.BadGeometry;
    const array_sectors = (h.arrayBytes() + SECTOR - 1) / SECTOR;
    if (h.entries_lba < 2 or h.entries_lba + array_sectors > disk_sectors) return error.BadGeometry;
    return h;
}

/// Entry `idx` of the (already CRC-verified) array, or null for an unused slot
/// or one whose extent is impossible for this disk.
pub fn entryAt(h: Header, array: []const u8, idx: u32, disk_sectors: u64) ?Partition {
    if (idx >= h.entry_count) return null;
    const off = @as(usize, idx) * h.entry_size;
    if (off + 128 > array.len) return null;
    const e = array[off..][0..128];
    var all_zero = true;
    for (e[0..16]) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    if (all_zero) return null; // unused entry
    const first = r64(e, 32);
    const last = r64(e, 40);
    if (first > last or first < h.first_usable or last > h.last_usable or last >= disk_sectors) return null;
    var p: Partition = .{ .first_lba = first, .last_lba = last, .sectors = last - first + 1, .type_guid = undefined };
    @memcpy(&p.type_guid, e[0..16]);
    return p;
}

/// Verify the entry array bytes against the header's CRC.
pub fn arrayCrcOk(h: Header, array: []const u8) bool {
    const n: usize = @intCast(h.arrayBytes());
    if (array.len < n) return false;
    return crc32(array[0..n]) == h.entries_crc;
}
