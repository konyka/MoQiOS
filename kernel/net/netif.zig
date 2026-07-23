const nic = @import("nic.zig");
const serial = @import("../arch/arch.zig").serial;

var our_mac: [6]u8 = @splat(0);
var mac_initialized: bool = false;

/// Default Ethernet link MTU (SK-102).
pub const DEFAULT_MTU: u16 = 1500;
/// Hard ceiling for the current NIC path (standard frames).
pub const MAX_MTU: u16 = 1500;
/// Absolute floor (IPv4 minimum reassembly).
pub const MIN_MTU: u16 = 576;

var link_mtu: u16 = DEFAULT_MTU;

pub fn ensureInit() void {
    if (!mac_initialized) {
        our_mac = nic.getMAC();
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

/// Current interface MTU used as the Path MTU / SYN MSS ceiling (SK-102).
pub fn getMtu() u16 {
    return link_mtu;
}

/// Set interface MTU, clamped to `[MIN_MTU, MAX_MTU]` (SK-102).
pub fn setMtu(mtu: u32) void {
    if (mtu < MIN_MTU) {
        link_mtu = MIN_MTU;
    } else if (mtu > MAX_MTU) {
        link_mtu = MAX_MTU;
    } else {
        link_mtu = @intCast(mtu);
    }
}

/// Restore the default Ethernet MTU (probe helper) (SK-102).
pub fn resetMtu() void {
    link_mtu = DEFAULT_MTU;
}
