const e1000 = @import("../drivers/e1000.zig");
const serial = @import("../arch/x86_64/serial.zig");

var our_mac: [6]u8 = @splat(0);
var mac_initialized: bool = false;

pub fn ensureInit() void {
    if (!mac_initialized) {
        our_mac = e1000.getMAC();
        mac_initialized = true;
    }
}

pub fn getOurIp() [4]u8 {
    return .{ 10, 0, 2, 15 };
}

pub fn getGateway() [4]u8 {
    return .{ 10, 0, 2, 2 };
}

pub fn getNetmask() [4]u8 {
    return .{ 255, 255, 255, 0 };
}

pub fn getMac() [6]u8 {
    ensureInit();
    return our_mac;
}

fn writeHex8(v: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[(v >> 4) & 0xF];
    buf[1] = hex[v & 0xF];
    serial.writeString(&buf);
}
