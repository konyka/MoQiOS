/// Shared byte order read/write utilities (no std dependency).
// ─── Little-Endian ────────────────────────────────────────────────────────
/// Read a little-endian u16 from byte slice (must be at least 2 bytes).
pub fn readU16Le(src: []const u8) u16 {
    return @as(u16, src[0]) | (@as(u16, src[1]) << 8);
}

/// Write a little-endian u16 to byte slice (must be at least 2 bytes).
pub fn writeU16Le(dst: []u8, val: u16) void {
    dst[0] = @truncate(val);
    dst[1] = @truncate(val >> 8);
}

/// Read a little-endian u32 from byte slice (must be at least 4 bytes).
pub fn readU32Le(src: []const u8) u32 {
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) |
        (@as(u32, src[3]) << 24);
}

/// Write a little-endian u32 to byte slice (must be at least 4 bytes).
pub fn writeU32Le(dst: []u8, val: u32) void {
    dst[0] = @truncate(val);
    dst[1] = @truncate(val >> 8);
    dst[2] = @truncate(val >> 16);
    dst[3] = @truncate(val >> 24);
}

/// Read a little-endian u64 from byte slice (must be at least 8 bytes).
pub fn readU64Le(src: []const u8) u64 {
    var val: u64 = 0;
    inline for (0..8) |i| {
        val |= @as(u64, src[i]) << @intCast(i * 8);
    }
    return val;
}

/// Write a little-endian u64 to byte slice (must be at least 8 bytes).
pub fn writeU64Le(dst: []u8, val: u64) void {
    inline for (0..8) |i| {
        dst[i] = @truncate(val >> @intCast(i * 8));
    }
}

/// Read a little-endian i64 from byte slice (must be at least 8 bytes).
pub fn readI64Le(src: []const u8) i64 {
    return @bitCast(readU64Le(src));
}

/// Write a little-endian i32 to byte slice (must be at least 4 bytes).
pub fn writeI32Le(dst: []u8, val: i32) void {
    writeU32Le(dst, @bitCast(val));
}

/// Write a little-endian i64 to byte slice (must be at least 8 bytes).
pub fn writeI64Le(dst: []u8, val: i64) void {
    writeU64Le(dst, @bitCast(val));
}

/// Read a little-endian u64 from many-item pointer at given offset.
pub fn readU64At(ptr: [*]const u8, off: usize) u64 {
    return @as(u64, ptr[off]) |
        (@as(u64, ptr[off + 1]) << 8) |
        (@as(u64, ptr[off + 2]) << 16) |
        (@as(u64, ptr[off + 3]) << 24) |
        (@as(u64, ptr[off + 4]) << 32) |
        (@as(u64, ptr[off + 5]) << 40) |
        (@as(u64, ptr[off + 6]) << 48) |
        (@as(u64, ptr[off + 7]) << 56);
}

/// Read a little-endian u64 starting at many-item pointer (offset 0).
pub inline fn readU64Ptr(ptr: [*]const u8) u64 {
    return readU64At(ptr, 0);
}

/// Write a little-endian u64 to many-item pointer at given offset.
pub inline fn writeU64At(dst: [*]u8, off: usize, val: u64) void {
    writeU64Le(dst[off .. off + 8], val);
}

// ─── Big-Endian (network byte order) ───────────────────────────────────────

/// Write a big-endian u16 at offset in a many-item pointer.
pub inline fn writeU16BeAt(dst: [*]u8, off: usize, val: u16) void {
    dst[off] = @intCast((val >> 8) & 0xFF);
    dst[off + 1] = @intCast(val & 0xFF);
}

/// Write a big-endian u32 at offset in a many-item pointer.
pub inline fn writeU32BeAt(dst: [*]u8, off: usize, val: u32) void {
    dst[off] = @intCast((val >> 24) & 0xFF);
    dst[off + 1] = @intCast((val >> 16) & 0xFF);
    dst[off + 2] = @intCast((val >> 8) & 0xFF);
    dst[off + 3] = @intCast(val & 0xFF);
}

/// Read a big-endian u16 from many-item pointer at given offset.
pub inline fn readU16BeAt(src: [*]const u8, off: usize) u16 {
    return (@as(u16, src[off]) << 8) | @as(u16, src[off + 1]);
}

/// Read a big-endian u32 from many-item pointer at given offset.
pub inline fn readU32BeAt(src: [*]const u8, off: usize) u32 {
    return (@as(u32, src[off]) << 24) | (@as(u32, src[off + 1]) << 16) |
        (@as(u32, src[off + 2]) << 8) | @as(u32, src[off + 3]);
}

// ─── Byte Swap (host ↔ network) ─────────────────────────────────────────────

/// Swap byte order of a u16 (host to network or network to host).
pub inline fn bswapU16(val: u16) u16 {
    return (val >> 8) | (val << 8);
}

/// Swap byte order of a u32 (host to network or network to host).
pub inline fn bswapU32(val: u32) u32 {
    return (val >> 24) | ((val >> 8) & 0xFF00) | ((val << 8) & 0xFF0000) | (val << 24);
}
