/// Shared integer formatting utilities plus serial output wrappers.
const core = @import("fmt_core.zig");

pub const fmtDec = core.fmtDec;
pub const formatInt = core.formatInt;
pub const formatIntBuf = core.formatIntBuf;
pub const fmtHex16 = core.fmtHex16;
pub const formatHex = core.formatHex;
pub const fmtHex = core.fmtHex;
pub const fmtHex8 = core.fmtHex8;
pub const fmtSignedDec = core.fmtSignedDec;

// ─── Serial output convenience wrappers ────────────────────────────────
// These write formatted values directly to the serial port.

fn serialWriteString(s: []const u8) void {
    const serial = @import("../arch/x86_64/serial.zig");
    serial.writeString(s);
}

/// Write u64 as 16-char zero-padded hex to serial.
pub fn writeHex(value: u64) void {
    var buf: [16]u8 = undefined;
    serialWriteString(fmtHex16(&buf, value));
}

/// Alias for writeHex.
pub const writeHex64 = writeHex;

/// Write u32 as 8-char zero-padded hex to serial.
pub fn writeHex32(value: u32) void {
    var buf: [8]u8 = undefined;
    serialWriteString(fmtHex8(&buf, value));
}

/// Write u16 as 4-char zero-padded hex to serial.
pub fn writeHex16(value: u16) void {
    const hex = "0123456789abcdef";
    var buf: [4]u8 = undefined;
    var i: usize = 4;
    var v: u16 = value;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    serialWriteString(&buf);
}

/// Write u8 as 2-char zero-padded hex to serial.
pub fn writeHex8(value: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[(value >> 4) & 0xF];
    buf[1] = hex[value & 0xF];
    serialWriteString(&buf);
}

/// Alias for writeHex8.
pub const writeHexByte = writeHex8;

/// Write u32 as decimal to serial.
pub fn writeDecimal(value: u32) void {
    var buf: [10]u8 = undefined;
    serialWriteString(fmtDec(&buf, value));
}

/// Write u64 as decimal to serial.
pub fn writeDecimal64(value: u64) void {
    var buf: [20]u8 = undefined;
    serialWriteString(fmtDec(&buf, value));
}

/// Write any unsigned integer as decimal to serial.
/// Convenience wrapper that auto-widens to u64.
pub fn writeDec(comptime T: type, value: T) void {
    writeDecimal64(@as(u64, @intCast(value)));
}
