const e1000 = @import("../drivers/e1000.zig");
const serial = @import("../arch/arch.zig").serial;

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
