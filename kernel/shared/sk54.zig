//! SK-54 — arch-clean TCP helpers (`net/tcp_util.zig`) on non-x86.
//!
//! tcp.zig itself is a large stateful engine bound to idt/scheduler/locks and
//! can't yet compile on non-x86, but its pure math doesn't need any of that.
//! SK-54 extracts ring-buffer occupancy, RFC 793 modular sequence comparisons,
//! and the IPv4 pseudo-header TCP checksum into tcp_util.zig (tcp.zig now
//! delegates to it) and exercises them on riscv64/aarch64:
//!   - ring math with wrap-around,
//!   - sequence comparisons across the 32-bit wrap boundary,
//!   - TCP checksum self-check: a segment whose checksum field is filled in
//!     must re-verify to 0 (pseudo-header + segment fold).

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tu = @import("../net/tcp_util.zig");

const SRC_IP: [4]u8 = .{ 10, 0, 2, 15 };
const DST_IP: [4]u8 = .{ 10, 0, 2, 2 };

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-54] tcp_util helpers non-x86: OK\n");
        return;
    }

    // Ring occupancy, including wrap-around (tail behind head).
    if (tu.ringDataLen(0, 5, 16) != 5 or tu.ringDataLen(14, 2, 16) != 4) {
        arch.serial.writeString("[SK-54] FAILED: ringDataLen\n");
        return;
    }
    if (tu.ringAvailable(0, 5, 16) != 10 or tu.ringAvailable(0, 0, 16) != 15) {
        arch.serial.writeString("[SK-54] FAILED: ringAvailable\n");
        return;
    }

    // Sequence comparisons, including the 32-bit wrap boundary.
    if (!tu.seqLt(1, 2) or tu.seqLt(2, 1)) {
        arch.serial.writeString("[SK-54] FAILED: seqLt\n");
        return;
    }
    if (!tu.seqLt(0xFFFF_FFFF, 0) or !tu.seqGt(0, 0xFFFF_FFFF)) {
        arch.serial.writeString("[SK-54] FAILED: seq wrap\n");
        return;
    }
    if (!tu.seqLeq(5, 5) or tu.seqLeq(6, 5)) {
        arch.serial.writeString("[SK-54] FAILED: seqLeq\n");
        return;
    }
    if (!tu.seqInWindow(5, 3, 10) or tu.seqInWindow(10, 3, 10) or
        !tu.seqInWindow(0, 0xFFFF_FFFE, 2))
    {
        arch.serial.writeString("[SK-54] FAILED: seqInWindow\n");
        return;
    }

    // TCP checksum self-check: fill a 20-byte header, compute checksum into
    // the checksum field, then a re-compute over the whole thing must be 0.
    var hdr: [20]u8 = .{
        0x1F, 0x90, // src port 8080
        0x00, 0x50, // dst port 80
        0x00, 0x00, 0x00, 0x01, // seq
        0x00, 0x00, 0x00, 0x00, // ack
        0x50, 0x02, // data offset 5, flags SYN
        0x20, 0x00, // window
        0x00, 0x00, // checksum (zero for computation)
        0x00, 0x00, // urgent ptr
    };
    const csum = tu.checksum(SRC_IP, DST_IP, &hdr, hdr.len);
    hdr[16] = @truncate(csum >> 8);
    hdr[17] = @truncate(csum);
    if (tu.checksum(SRC_IP, DST_IP, &hdr, hdr.len) != 0) {
        arch.serial.writeString("[SK-54] FAILED: tcp checksum self-check\n");
        return;
    }

    arch.serial.writeString("[SK-54] tcp_util helpers non-x86: OK\n");
}
