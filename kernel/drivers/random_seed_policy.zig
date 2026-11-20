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

/// CRNG_RESEED_INTERVAL: the generator takes a fresh key from the interrupt-timing pool once a minute (Linux crng_reseed_interval).
pub const RESEED_INTERVAL_NS: u64 = 60 * std.time.ns_per_s;
/// During the first two minutes Linux reseeds sooner, proportionally to uptime; here: every 5 seconds until 2 minutes of uptime.
pub const EARLY_INTERVAL_NS: u64 = 5 * std.time.ns_per_s;
pub const EARLY_UNTIL_NS: u64 = 2 * RESEED_INTERVAL_NS;
/// Interrupt samples the pool must hold before a reseed uses it (fewer: the key is left as it is).
pub const MIN_SAMPLES: u32 = 64;

/// Whether to reseed now: enough samples gathered and the interval since the last reseed (`last_ns`) has passed.
pub fn reseedDue(now_ns: u64, last_ns: u64, samples: u32) bool {
    if (samples < MIN_SAMPLES) return false;
    const interval = if (now_ns < EARLY_UNTIL_NS) EARLY_INTERVAL_NS else RESEED_INTERVAL_NS;
    return now_ns -% last_ns >= interval;
}

/// fast_mix-style fold of one interrupt sample (a cycle counter and what took the interrupt) into a 4-word pool: cheap, lock-free on
/// the interrupt's own CPU word, and every input bit reaches every pool word within a few samples.
pub fn foldSample(pool: *[4]u64, cycles: u64, source: u64) void {
    var a = pool[0] ^ cycles;
    var b = pool[1] ^ source;
    var c = pool[2];
    var d = pool[3];
    inline for (0..2) |_| {
        a +%= b;
        b = std.math.rotl(u64, b, 13) ^ a;
        a = std.math.rotl(u64, a, 32);
        c +%= d;
        d = std.math.rotl(u64, d, 16) ^ c;
        a +%= d;
        d = std.math.rotl(u64, d, 21) ^ a;
        c +%= b;
        b = std.math.rotl(u64, b, 17) ^ c;
        c = std.math.rotl(u64, c, 32);
    }
    pool.* = .{ a, b, c, d };
}

test "reseed timing: early every 5 s, later every 60 s, never without samples" {
    try std.testing.expect(!reseedDue(10 * std.time.ns_per_s, 0, MIN_SAMPLES - 1));
    try std.testing.expect(reseedDue(6 * std.time.ns_per_s, 0, MIN_SAMPLES));
    try std.testing.expect(!reseedDue(130 * std.time.ns_per_s, 100 * std.time.ns_per_s, MIN_SAMPLES));
    try std.testing.expect(reseedDue(161 * std.time.ns_per_s, 100 * std.time.ns_per_s, MIN_SAMPLES));
}

test "one changed sample bit changes every pool word" {
    var p: [4]u64 = .{ 1, 2, 3, 4 };
    var q = p;
    foldSample(&p, 1000, 7);
    foldSample(&q, 1001, 7);
    for (0..4) |i| try std.testing.expect(p[i] != q[i]);
}
