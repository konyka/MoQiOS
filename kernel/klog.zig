/// Kernel log system — outputs to serial with level prefixes.

const serial = @import("arch/x86_64/serial.zig");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
};

var min_level: Level = .debug;

pub fn setLevel(level: Level) void {
    min_level = level;
}

pub fn log(comptime level: Level, comptime msg: []const u8) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    const prefix = switch (level) {
        .err => "[ERR] ",
        .warn => "[WRN] ",
        .info => "[INF] ",
        .debug => "[DBG] ",
    };
    serial.writeString(prefix);
    serial.writeString(msg);
    serial.writeString("\n");
}

pub fn logHex(comptime level: Level, comptime prefix: []const u8, value: u64) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    serial.writeString(switch (level) {
        .err => "[ERR] ",
        .warn => "[WRN] ",
        .info => "[INF] ",
        .debug => "[DBG] ",
    });
    serial.writeString(prefix);
    serial.writeString("0x");
    writeHex(value);
    serial.writeString("\n");
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}
