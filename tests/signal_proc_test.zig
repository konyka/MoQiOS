//! Host tests for the process/signal hardening round: id range checks,
//! signal-send permission, SIGKILL/SIGSTOP rules, exec disposition reset
//! and red-zone-safe signal frame placement.

const std = @import("std");
const kt = @import("kernel_shared");

const proc_id_policy = kt.proc_id_policy;
const signal_perm_policy = kt.signal_perm_policy;
const signal_action_policy = kt.signal_action_policy;
const signal_exec_policy = kt.signal_exec_policy;
const signal_frame_policy = kt.signal_frame_policy;

// ── exit code / id ranges ───────────────────────────────────────────────

test "exit status keeps only the low 8 bits" {
    try std.testing.expectEqual(@as(i32, 0), proc_id_policy.exitCode(0));
    try std.testing.expectEqual(@as(i32, 42), proc_id_policy.exitCode(42));
    try std.testing.expectEqual(@as(i32, 127), proc_id_policy.exitCode(127));
    try std.testing.expectEqual(@as(i32, 255), proc_id_policy.exitCode(@bitCast(@as(i64, -1))));
    try std.testing.expectEqual(@as(i32, 0), proc_id_policy.exitCode(256));
    try std.testing.expectEqual(@as(i32, 1), proc_id_policy.exitCode(0xFFFF_FFFF_0000_0101));
}

test "kill target tid rejects values outside u32" {
    try std.testing.expectEqual(@as(?u32, 7), proc_id_policy.killTargetTid(7));
    try std.testing.expectEqual(@as(?u32, 0xFFFF_FFFF), proc_id_policy.killTargetTid(0xFFFF_FFFF));
    try std.testing.expectEqual(@as(?u32, null), proc_id_policy.killTargetTid((@as(i64, 1) << 32) | 7));
    try std.testing.expectEqual(@as(?u32, null), proc_id_policy.killTargetTid(0));
    try std.testing.expectEqual(@as(?u32, null), proc_id_policy.killTargetTid(-5));
    try std.testing.expectEqual(@as(?u32, null), proc_id_policy.killTargetTid(std.math.maxInt(i64)));
}

test "kill target pgid rejects -pid beyond u16" {
    try std.testing.expectEqual(@as(?u16, 2), proc_id_policy.killTargetPgid(-2));
    try std.testing.expectEqual(@as(?u16, 0xFFFF), proc_id_policy.killTargetPgid(-0xFFFF));
    try std.testing.expectEqual(@as(?u16, null), proc_id_policy.killTargetPgid(-0x10000));
    try std.testing.expectEqual(@as(?u16, null), proc_id_policy.killTargetPgid(std.math.minInt(i64)));
    try std.testing.expectEqual(@as(?u16, null), proc_id_policy.killTargetPgid(-1));
    try std.testing.expectEqual(@as(?u16, null), proc_id_policy.killTargetPgid(3));
}

test "group ids from user args and tids are range checked" {
    try std.testing.expectEqual(@as(?u16, 0), proc_id_policy.groupIdFromArg(0));
    try std.testing.expectEqual(@as(?u16, 0xFFFF), proc_id_policy.groupIdFromArg(0xFFFF));
    try std.testing.expectEqual(@as(?u16, null), proc_id_policy.groupIdFromArg(70000));
    try std.testing.expectEqual(@as(?u16, null), proc_id_policy.groupIdFromArg(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(?u16, 100), proc_id_policy.groupIdForTid(100));
    try std.testing.expectEqual(@as(?u16, null), proc_id_policy.groupIdForTid(65536));
}

test "a tid above 0xFFFF never equals a u16 group id" {
    try std.testing.expect(proc_id_policy.groupIdIsTid(5, 5));
    try std.testing.expect(!proc_id_policy.groupIdIsTid(5, 6));
    try std.testing.expect(!proc_id_policy.groupIdIsTid(0, 65536));
    try std.testing.expect(!proc_id_policy.groupIdIsTid(5, 65536 + 5));
    try std.testing.expect(proc_id_policy.groupIdIsTid(0xFFFF, 0xFFFF));
}

// ── signal-send permission ──────────────────────────────────────────────

test "signalling another task needs cap_kill, self is always allowed" {
    try std.testing.expect(signal_perm_policy.maySignalTask(5, 5, false));
    try std.testing.expect(!signal_perm_policy.maySignalTask(5, 1, false));
    try std.testing.expect(signal_perm_policy.maySignalTask(5, 1, true));
}

test "kill permission compares pid at full width and gates groups" {
    try std.testing.expect(signal_perm_policy.mayKill(7, 7, false));
    try std.testing.expect(!signal_perm_policy.mayKill(7, 1, false));
    try std.testing.expect(!signal_perm_policy.mayKill(7, (@as(i64, 1) << 32) | 7, false));
    try std.testing.expect(!signal_perm_policy.mayKill(7, -7, false));
    try std.testing.expect(!signal_perm_policy.mayKill(7, -1, false));
    try std.testing.expect(signal_perm_policy.mayKill(7, -7, true));
    try std.testing.expect(signal_perm_policy.mayKill(7, 1, true));
}

// ── SIGKILL / SIGSTOP ───────────────────────────────────────────────────

test "sigaction cannot install an action for SIGKILL or SIGSTOP" {
    try std.testing.expect(!signal_action_policy.actionChangeAllowed(9, true));
    try std.testing.expect(!signal_action_policy.actionChangeAllowed(19, true));
    try std.testing.expect(signal_action_policy.actionChangeAllowed(9, false));
    try std.testing.expect(signal_action_policy.actionChangeAllowed(19, false));
    try std.testing.expect(signal_action_policy.actionChangeAllowed(10, true));
    try std.testing.expect(signal_action_policy.actionChangeAllowed(18, true));
}

test "masks never block SIGKILL or SIGSTOP" {
    const all: u64 = std.math.maxInt(u64);
    const m = signal_action_policy.sanitizeMask(all);
    try std.testing.expectEqual(@as(u64, 0), m & (@as(u64, 1) << 8));
    try std.testing.expectEqual(@as(u64, 0), m & (@as(u64, 1) << 18));
    try std.testing.expectEqual(all & ~((@as(u64, 1) << 8) | (@as(u64, 1) << 18)), m);
    try std.testing.expectEqual(@as(u64, 1 << 1), signal_action_policy.sanitizeMask(1 << 1));
}

// ── exec disposition reset ──────────────────────────────────────────────

test "exec resets caught signals to SIG_DFL and keeps SIG_IGN" {
    try std.testing.expectEqual(@as(u64, 0), signal_exec_policy.execHandlerAfter(0));
    try std.testing.expectEqual(@as(u64, 1), signal_exec_policy.execHandlerAfter(1));
    try std.testing.expectEqual(@as(u64, 0), signal_exec_policy.execHandlerAfter(0x401000));
    try std.testing.expectEqual(@as(u64, 0), signal_exec_policy.execHandlerAfter(2));
    try std.testing.expectEqual(@as(u64, 0), signal_exec_policy.execHandlerAfter(std.math.maxInt(u64)));
}

// ── signal frame placement ──────────────────────────────────────────────

const SIGNAL_FRAME_SIZE: u64 = 19 * 8;

fn checkPlacement(user_rsp: u64, size: u64) !void {
    const h = signal_frame_policy.handlerRsp(user_rsp, size) orelse return error.NoRoom;
    // ABI: RSP + 8 is 16-byte aligned at handler entry.
    try std.testing.expectEqual(@as(u64, 0), (h + 8) % 16);
    // Return address + frame lie entirely below the red zone.
    try std.testing.expect(h + 8 + size <= user_rsp - signal_frame_policy.RED_ZONE);
    // And not wastefully far below it (at most one alignment slot of slack).
    try std.testing.expect(h + 8 + size + 8 + 16 > user_rsp - signal_frame_policy.RED_ZONE);
}

test "signal frame stays below the 128-byte red zone and is ABI aligned" {
    var rsp: u64 = 0x7F_F000;
    while (rsp > 0x7F_F000 - 64) : (rsp -= 1) {
        try checkPlacement(rsp, SIGNAL_FRAME_SIZE);
        try checkPlacement(rsp, 8);
        try checkPlacement(rsp, 512 + SIGNAL_FRAME_SIZE);
    }
}

test "signal frame never overlaps the interrupted red zone" {
    const rsp: u64 = 0x80_0000 - 0x38;
    const h = signal_frame_policy.handlerRsp(rsp, SIGNAL_FRAME_SIZE).?;
    const red_lo = rsp - 128;
    try std.testing.expect(h < red_lo);
    try std.testing.expect(h + 8 + SIGNAL_FRAME_SIZE <= red_lo);
}

test "signal frame placement fails instead of wrapping on a tiny rsp" {
    try std.testing.expectEqual(@as(?u64, null), signal_frame_policy.handlerRsp(0, SIGNAL_FRAME_SIZE));
    try std.testing.expectEqual(@as(?u64, null), signal_frame_policy.handlerRsp(100, SIGNAL_FRAME_SIZE));
    try std.testing.expect(signal_frame_policy.handlerRsp(4096, SIGNAL_FRAME_SIZE) != null);
}
