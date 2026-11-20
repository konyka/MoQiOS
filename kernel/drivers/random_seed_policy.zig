//! Which hardware random instruction seeds the kernel generator, from CPUID (pure, host-tested): RDSEED (leaf 7 EBX bit 18) gives
//! conditioned entropy and is preferred; RDRAND (leaf 1 ECX bit 30) is a DRBG output, still unpredictable; neither leaves the seed to
//! timer jitter alone.

const std = @import("std");

pub const HwSource = enum { none, rdrand, rdseed };

pub const RDRAND_BIT: u32 = 1 << 30;
pub const RDSEED_BIT: u32 = 1 << 18;

pub fn hwSource(leaf1_ecx: u32, leaf7_ebx: u32) HwSource {
    if (leaf7_ebx & RDSEED_BIT != 0) return .rdseed;
    if (leaf1_ecx & RDRAND_BIT != 0) return .rdrand;
    return .none;
}

test "RDSEED is preferred, then RDRAND, else none" {
    try std.testing.expectEqual(HwSource.rdseed, hwSource(RDRAND_BIT, RDSEED_BIT));
    try std.testing.expectEqual(HwSource.rdrand, hwSource(RDRAND_BIT, 0));
    try std.testing.expectEqual(HwSource.none, hwSource(0, 0));
}
