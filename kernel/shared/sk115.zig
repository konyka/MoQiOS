//! SK-115 — DSACK detection and spurious-recovery undo (non-x86).
//!
//! Fast retransmit can fire on reordering; without DSACK the halved cwnd sticks.
//! RFC 2883 DSACK identifies duplicate delivery so we can restore prior cwnd.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-115] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-115] tcp dsack undo non-x86: OK\n");
        return;
    }

    const ack: u32 = 5000;

    // DSACK below cumulative ACK.
    const below = [_]tcp.SackBlock{.{ .left = 3000, .right = 4000 }};
    if (!tcp.probeIsDsack(ack, &below)) {
        fail("below");
        return;
    }

    // First block is a duplicate subset of a later SACK block.
    const nested = [_]tcp.SackBlock{
        .{ .left = 6000, .right = 6500 },
        .{ .left = 6000, .right = 8000 },
    };
    if (!tcp.probeIsDsack(ack, &nested)) {
        fail("nested");
        return;
    }

    // Ordinary SACK above ACK — not a DSACK.
    const normal = [_]tcp.SackBlock{
        .{ .left = 6000, .right = 7000 },
        .{ .left = 8000, .right = 9000 },
    };
    if (tcp.probeIsDsack(ack, &normal)) {
        fail("normal");
        return;
    }

    // Empty / invalid.
    if (tcp.probeIsDsack(ack, &.{})) {
        fail("empty");
        return;
    }

    arch.serial.writeString("[SK-115] tcp dsack undo non-x86: OK\n");
}
