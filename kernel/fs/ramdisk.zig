/// Ramdisk filesystem — parses Limine-loaded modules into a simple file index.
///
/// The ramdisk is a flat archive format:
///   Header: magic[4] "MRD\x00", file_count: u32, reserved: [3]u32
///   Entries: RamdiskEntry[file_count] — { name[64], offset: u64, size: u64 }
///   Data: raw file data starting at data_offset
///
/// This is generated at build time by tools/mkramdisk.sh and loaded as a
/// Limine module. The kernel parses it once at boot and provides lookup by name.

const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog.zig");

/// Max files in the ramdisk index.
pub const MAX_FILES: u32 = 32;

/// Max filename length (including null terminator).
pub const MAX_NAME_LEN: u32 = 64;

/// Ramdisk magic: "MRD\0"
const RAMDISK_MAGIC = [4]u8{ 'M', 'R', 'D', 0 };

/// Ramdisk header — at the start of the ramdisk blob.
pub const RamdiskHeader = extern struct {
    magic: [4]u8,
    file_count: u32,
    reserved: [3]u32,
};

/// Ramdisk entry — describes one file in the archive.
pub const RamdiskEntry = extern struct {
    name: [MAX_NAME_LEN]u8,
    offset: u64,
    size: u64,
};

/// Parsed ramdisk state.
const RamdiskState = struct {
    base: [*]const u8 = undefined,
    file_count: u32 = 0,
    entries_off: u64 = 0,
    data_offset: u64 = 0,
    initialized: bool = false,
};

var state: RamdiskState = .{};

/// Initialize the ramdisk from a raw memory region.
/// `base` points to the start of the ramdisk blob, `size` is its total size in bytes.
pub fn init(base: [*]const u8, size: u64) bool {
    if (size < 32) {
        klog.log(.info, "Ramdisk too small for header");
        return false;
    }

    if (base[0] != 'M' or base[1] != 'R' or base[2] != 'D' or base[3] != 0) {
        klog.log(.info, "Ramdisk bad magic");
        return false;
    }

    const file_count: u32 = @as(*const u32, @ptrCast(@alignCast(base + 4))).*;
    if (file_count > MAX_FILES) {
        klog.log(.info, "Ramdisk too many files");
        return false;
    }

    const header_size: u64 = 32;
    const entry_size: u64 = 80;
    const entries_off = header_size;
    const data_off = header_size + @as(u64, file_count) * entry_size;

    if (size < data_off) {
        klog.log(.info, "Ramdisk truncated (entries exceed size)");
        return false;
    }

    state = .{
        .base = base,
        .file_count = file_count,
        .entries_off = entries_off,
        .data_offset = data_off,
        .initialized = true,
    };

    var buf: [16]u8 = undefined;
    klog.log(.info, "Ramdisk initialized");
    serial.writeString("  ");
    serial.writeString(formatInt(&buf, file_count));
    serial.writeString(" files, data offset ");
    serial.writeString(formatInt(&buf, data_off));
    serial.writeString("\n");

    for (0..file_count) |i| {
        const entry_base = base + entries_off + @as(u64, i) * entry_size;
        const name_ptr: [*]const u8 = entry_base;
        const name_len = stdStrnLen(name_ptr, MAX_NAME_LEN);
        const entry_size_field: u64 = readU64(entry_base + 72);
        serial.writeString("  [");
        serial.writeString(formatInt(&buf, i));
        serial.writeString("] ");
        serial.writeString(name_ptr[0..name_len]);
        serial.writeString(" (");
        serial.writeString(formatInt(&buf, entry_size_field));
        serial.writeString(" bytes)\n");
    }

    return true;
}

/// Look up a file by name. Returns null if not found.
pub fn findFile(name: []const u8) ?RamdiskFile {
    if (!state.initialized) return null;

    const count = state.file_count;
    const entry_size: u64 = 80;
    for (0..count) |i| {
        const entry_base = state.base + state.entries_off + i * entry_size;
        const entry_name: [*]const u8 = entry_base;
        const entry_name_len = stdStrnLen(entry_name, MAX_NAME_LEN);
        if (entry_name_len == name.len and stdMemEqual(entry_name[0..entry_name_len], name)) {
            const offset = readU64(entry_base + 64);
            const size = readU64(entry_base + 72);
            return .{
                .data = state.base + state.data_offset + offset,
                .size = size,
                .name = entry_name[0..entry_name_len],
            };
        }
    }
    return null;
}

/// A reference to a file in the ramdisk.
pub const RamdiskFile = struct {
    data: [*]const u8,
    size: u64,
    name: []const u8,
};

/// Get the number of files in the ramdisk.
pub fn getFileCount() u32 {
    if (!state.initialized) return 0;
    return state.file_count;
}

// --- Helpers (no stdlib) ---

fn stdMemEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn readU64(ptr: [*]const u8) u64 {
    var result: u64 = 0;
    inline for (0..8) |i| {
        result |= @as(u64, ptr[i]) << @intCast(i * 8);
    }
    return result;
}

fn stdStrnLen(s: [*]const u8, max: usize) usize {
    var i: usize = 0;
    while (i < max and s[i] != 0) : (i += 1) {}
    return i;
}

fn formatInt(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}
