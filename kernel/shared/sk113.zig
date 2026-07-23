//! SK-113 — sender SACK scoreboard incremental merge (non-x86).
//!
//! Dup ACKs replaced the scoreboard with the latest option, and new ACKs wiped
//! it. UpdateScoreboard now clips by [una,nxt), merges overlap/adjacent ranges,
//! and retains prior holes still above snd_una.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-113] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-113] tcp sack scoreboard merge non-x86: OK\n");
        return;
    }

    const una: u32 = 1000;
    const nxt: u32 = 1000 + 5 * 1460;
    var out: [4]tcp.SackBlock = undefined;

    // Preserve prior hole when a new disjoint block arrives.
    const old1 = [_]tcp.SackBlock{.{ .left = 2000, .right = 3000 }};
    const neu1 = [_]tcp.SackBlock{.{ .left = 4000, .right = 5000 }};
    const n1 = tcp.probeMergeScoreboard(una, nxt, &old1, &neu1, &out);
    if (n1 != 2 or out[0].left != 2000 or out[0].right != 3000 or
        out[1].left != 4000 or out[1].right != 5000)
    {
        fail("keep");
        return;
    }

    // Overlap + adjacent merge into one range.
    const old2 = [_]tcp.SackBlock{.{ .left = 2000, .right = 3000 }};
    const neu2 = [_]tcp.SackBlock{
        .{ .left = 2500, .right = 3500 },
        .{ .left = 3500, .right = 4000 },
    };
    const n2 = tcp.probeMergeScoreboard(una, nxt, &old2, &neu2, &out);
    if (n2 != 1 or out[0].left != 2000 or out[0].right != 4000) {
        fail("merge");
        return;
    }

    // Cumulative ACK trims / drops covered blocks.
    const old3 = [_]tcp.SackBlock{
        .{ .left = 1000, .right = 2000 },
        .{ .left = 3000, .right = 4000 },
    };
    const n3 = tcp.probeMergeScoreboard(2000, nxt, &old3, &.{}, &out);
    if (n3 != 1 or out[0].left != 3000 or out[0].right != 4000) {
        fail("trim");
        return;
    }

    // Partial clip below una and above nxt.
    const old4 = [_]tcp.SackBlock{.{ .left = 1500, .right = nxt +% 500 }};
    const n4 = tcp.probeMergeScoreboard(2000, nxt, &old4, &.{}, &out);
    if (n4 != 1 or out[0].left != 2000 or out[0].right != nxt) {
        fail("clip");
        return;
    }

    arch.serial.writeString("[SK-113] tcp sack scoreboard merge non-x86: OK\n");
}
