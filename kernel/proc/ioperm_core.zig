/// Pure per-task I/O permission bitmap logic (TSS IOPB), used by the ioperm
/// syscall glue in ioperm.zig.
///
/// Hardware semantics: one bit per I/O port, 65536 ports → 8192 bytes.
/// Bit SET (1) = access DENIED, bit CLEAR (0) = allowed (when CPL > IOPL;
/// user tasks run with IOPL=0, so the bitmap is the only grant mechanism).
///
/// No kernel imports — host-tested via tests/main.zig (wired through
/// kernel/host_test.zig).

const errno = @import("../lib/errno.zig");

pub const PORT_COUNT: u32 = 65536;
pub const BITMAP_BYTES: usize = PORT_COUNT / 8; // 8192

pub const Bitmap = [BITMAP_BYTES]u8;

/// Validate an ioperm_set(port, count) range: count >= 1 and the whole
/// range [port, port+count) must fit in the 16-bit port space.
pub fn validateRange(port: u64, count: u64) i64 {
    if (count == 0) return errno.EINVAL;
    if (port >= PORT_COUNT) return errno.EINVAL;
    if (count > PORT_COUNT - port) return errno.EINVAL;
    return 0;
}

/// The default/shared bitmap: every port denied.
pub fn denyAll() Bitmap {
    return @splat(0xFF);
}

/// Grant (enable=true) or revoke (enable=false) ports [port, port+count).
/// Caller must have validated the range with validateRange.
pub fn setRange(bitmap: *Bitmap, port: u32, count: u32, enable: bool) void {
    var p = port;
    const end = port + count;
    while (p < end) : (p += 1) {
        const byte_idx = p >> 3;
        const bit: u3 = @intCast(p & 7);
        if (enable) {
            bitmap[byte_idx] &= ~(@as(u8, 1) << bit);
        } else {
            bitmap[byte_idx] |= @as(u8, 1) << bit;
        }
    }
}

/// True when the port may be accessed (bit clear).
pub fn isAllowed(bitmap: *const Bitmap, port: u32) bool {
    return bitmap[port >> 3] & (@as(u8, 1) << @intCast(port & 7)) == 0;
}

/// fork semantics: the child receives an independent copy of the bitmap.
pub fn inherit(dst: *Bitmap, src: *const Bitmap) void {
    @memcpy(dst, src);
}
