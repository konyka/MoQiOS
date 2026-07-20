//! SK-56 — IPv6 Neighbor Discovery cache + EUI-64 (`net/ndp.zig`) on non-x86.
//!
//! ndp.zig imports only ipv6 (arch-clean) + IrqSpinlock (arch-neutral: uses the
//! arch.irq / arch.cpu.pause facades), no timers, so the whole neighbor-cache
//! module compiles and runs on riscv64/aarch64. This is the IPv6 analogue of
//! SK-52's ARP probe. Exercises: fresh-cache miss, update→lookup hit, the
//! incomplete-state placeholder (must not be returned by lookup) then its
//! resolution, address keying, and modified-EUI-64 link-local generation
//! (fe80:: prefix, 0xFFFE inserted, U/L bit flipped).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ndp = @import("../net/ndp.zig");

const IP_A: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xA1 };
const IP_B: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xB2 };
const MAC_A: [6]u8 = .{ 0x02, 0x00, 0x00, 0x0A, 0x0A, 0x0A };

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, 0..) |x, i| if (x != b[i]) return false;
    return true;
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-56] ndp neighbor cache/eui64 non-x86: OK\n");
        return;
    }

    ndp.init();

    // Fresh cache: miss.
    if (ndp.lookup(IP_A) != null) {
        arch.serial.writeString("[SK-56] FAILED: stale after init\n");
        return;
    }

    // update → reachable → lookup hit.
    ndp.update(IP_A, MAC_A);
    const m = ndp.lookup(IP_A) orelse {
        arch.serial.writeString("[SK-56] FAILED: not cached\n");
        return;
    };
    if (!macEq(m, MAC_A)) {
        arch.serial.writeString("[SK-56] FAILED: mac mismatch\n");
        return;
    }

    // Address keying: a different IP must miss.
    if (ndp.lookup(IP_B) != null) {
        arch.serial.writeString("[SK-56] FAILED: phantom lookup\n");
        return;
    }

    // Incomplete placeholder must NOT be returned by lookup.
    ndp.markIncomplete(IP_B);
    if (ndp.lookup(IP_B) != null) {
        arch.serial.writeString("[SK-56] FAILED: incomplete returned\n");
        return;
    }
    // Resolving it makes it reachable.
    const MAC_B = [6]u8{ 0x02, 0, 0, 0x0B, 0x0B, 0x0B };
    ndp.update(IP_B, MAC_B);
    const mb = ndp.lookup(IP_B) orelse {
        arch.serial.writeString("[SK-56] FAILED: incomplete not resolved\n");
        return;
    };
    if (!macEq(mb, MAC_B)) {
        arch.serial.writeString("[SK-56] FAILED: resolved mac mismatch\n");
        return;
    }

    // Modified EUI-64 link-local generation (RFC 4291 §2.5.1).
    const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const ll = ndp.generateLinkLocal(mac);
    const want = [16]u8{
        0xFE, 0x80, 0, 0, 0, 0, 0, 0,
        0x52 ^ 0x02, 0x54, 0x00, 0xFF, 0xFE, 0x12, 0x34, 0x56,
    };
    for (want, 0..) |b, i| {
        if (ll[i] != b) {
            arch.serial.writeString("[SK-56] FAILED: eui64 link-local\n");
            return;
        }
    }

    arch.serial.writeString("[SK-56] ndp neighbor cache/eui64 non-x86: OK\n");
}
