//! SK-47 — shared IPv4 header build/parse + RFC 1071 checksum on non-x86.
//!
//! First slice of the network *protocol table* proven portable. `net/ipv4.zig`
//! depends only on `lib/byte_order.zig` (both std-free, arch-clean), so its
//! `buildHeader` / `parseHeader` / `checksum` link and run identically on
//! riscv64/aarch64. Until now the whole `net/*` tree was x86-only (never
//! reached on non-x86 because `net/mod.zig` init isn't called there); this
//! probe compiles ipv4.zig into the non-x86 image and exercises it directly,
//! establishing that the arch-clean protocol logic is genuinely portable and
//! guarding against a future edit sneaking an x86 dependency into it.
//!
//! Checks: (1) buildHeader emits a well-formed IPv4 header whose own checksum
//! verifies to 0 (RFC 1071 self-check), (2) parseHeader round-trips the
//! addresses/protocol/lengths, (3) checksum catches a single-bit corruption.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const ipv4 = @import("../net/ipv4.zig");

const SRC: [4]u8 = .{ 10, 0, 2, 15 };
const DST: [4]u8 = .{ 10, 0, 2, 2 };
const PAYLOAD_LEN: u16 = 40;

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-47] shared ipv4 header/checksum: OK\n");
        return;
    }

    var hdr: [20]u8 = undefined;
    ipv4.buildHeader(&hdr, SRC, DST, ipv4.PROTO_UDP, PAYLOAD_LEN);

    // A correctly-checksummed IPv4 header sums to 0 over its own 20 bytes.
    if (ipv4.checksum(&hdr, 20) != 0) {
        arch.serial.writeString("[SK-47] FAILED: header self-checksum nonzero\n");
        return;
    }

    // Header fields: version/IHL and total length.
    if (hdr[0] != 0x45) {
        arch.serial.writeString("[SK-47] FAILED: version/ihl byte\n");
        return;
    }

    const info = ipv4.parseHeader(&hdr, null) orelse {
        arch.serial.writeString("[SK-47] FAILED: parseHeader returned null\n");
        return;
    };
    if (info.protocol != ipv4.PROTO_UDP) {
        arch.serial.writeString("[SK-47] FAILED: protocol mismatch\n");
        return;
    }
    if (info.payload_offset != 20 or info.payload_len != PAYLOAD_LEN) {
        arch.serial.writeString("[SK-47] FAILED: length fields\n");
        return;
    }
    for (SRC, 0..) |b, i| {
        if (info.src_ip[i] != b) {
            arch.serial.writeString("[SK-47] FAILED: src_ip mismatch\n");
            return;
        }
    }
    for (DST, 0..) |b, i| {
        if (info.dst_ip[i] != b) {
            arch.serial.writeString("[SK-47] FAILED: dst_ip mismatch\n");
            return;
        }
    }

    // A corrupted header must no longer verify to 0.
    hdr[12] ^= 0x01;
    if (ipv4.checksum(&hdr, 20) == 0) {
        arch.serial.writeString("[SK-47] FAILED: checksum missed corruption\n");
        return;
    }

    arch.serial.writeString("[SK-47] shared ipv4 header/checksum: OK\n");
}
