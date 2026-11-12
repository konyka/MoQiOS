//! Pure waitid rules (Linux kernel/exit.c waitid, measured on the host with the raw syscall).
//!
//! idtype selects the children: P_ALL any, P_PID one pid, P_PGID one process group. Which is not an idtype, and a zero pid with P_PID or
//! P_PGID, are EINVAL. options must name at least one of WEXITED, WSTOPPED and WCONTINUED; every other bit but WNOHANG and WNOWAIT is
//! EINVAL.
//!
//! A report is a SIGCHLD siginfo: si_code is CLD_EXITED / CLD_KILLED / CLD_STOPPED / CLD_CONTINUED and si_status is the exit code, the
//! killing signal, the stop signal or SIGCONT. WNOWAIT reports an exit without reaping it, so the same zombie is reported again. A call
//! that finds nothing (WNOHANG, a live child) returns 0 and clears the caller's siginfo (si_signo 0), which is what the raw syscall does;
//! glibc's waitid does the same. A null infop is allowed and still reaps.

pub const P_ALL: u32 = 0;
pub const P_PID: u32 = 1;
pub const P_PGID: u32 = 2;

pub const WNOHANG: u32 = 0x1;
pub const WSTOPPED: u32 = 0x2;
pub const WEXITED: u32 = 0x4;
pub const WCONTINUED: u32 = 0x8;
pub const WNOWAIT: u32 = 0x0100_0000;

pub const CLD_EXITED: i32 = 1;
pub const CLD_KILLED: i32 = 2;
pub const CLD_STOPPED: i32 = 5;
pub const CLD_CONTINUED: i32 = 6;
pub const SIGCONT: u32 = 18;

pub const EINVAL: i64 = -22;

const KINDS: u32 = WEXITED | WSTOPPED | WCONTINUED;
const KNOWN: u32 = KINDS | WNOHANG | WNOWAIT;

pub const Request = struct {
    /// The pid argument the existing waitpid scan understands: -1 any, >0 one child, < -1 one group.
    pid: i32,
    options: u32,
};

/// The request, or EINVAL. `id` is the raw second argument.
pub fn request(idtype: u32, id: u64, options: u32) ?Request {
    if (options & ~KNOWN != 0 or options & KINDS == 0) return null;
    const pid: i32 = switch (idtype) {
        P_ALL => -1,
        P_PID => blk: {
            if (id == 0 or id > 0x7fffffff) return null;
            break :blk @intCast(id);
        },
        P_PGID => blk: {
            if (id == 0 or id > 0x7fffffff) return null;
            break :blk -@as(i32, @intCast(id));
        },
        else => return null,
    };
    return .{ .pid = pid, .options = options };
}

pub const Child = struct {
    zombie: bool,
    /// The exit() code, or the signal number when `signaled`.
    exit_value: u8 = 0,
    signaled: bool = false,
    stop_sig: u8 = 0,
    continued: bool = false,
};

pub const Report = struct {
    code: i32,
    /// si_status.
    status: u32,
    /// The child is a zombie and WNOWAIT was not set, so the caller reaps it.
    reap: bool,
};

/// What `c` reports under `options`, if anything. An exit wins over a pending stop or continue of the same child.
pub fn report(options: u32, c: Child) ?Report {
    if (c.zombie and options & WEXITED != 0) return .{
        .code = if (c.signaled) CLD_KILLED else CLD_EXITED,
        .status = c.exit_value,
        .reap = options & WNOWAIT == 0,
    };
    if (c.stop_sig != 0 and options & WSTOPPED != 0) return .{ .code = CLD_STOPPED, .status = c.stop_sig, .reap = false };
    if (c.continued and options & WCONTINUED != 0) return .{ .code = CLD_CONTINUED, .status = SIGCONT, .reap = false };
    return null;
}

const std = @import("std");

test "idtype and options" {
    try std.testing.expectEqual(@as(i32, -1), request(P_ALL, 0, WEXITED).?.pid);
    try std.testing.expectEqual(@as(i32, 9), request(P_PID, 9, WEXITED | WNOHANG).?.pid);
    try std.testing.expectEqual(@as(i32, -9), request(P_PGID, 9, WSTOPPED).?.pid);
    try std.testing.expect(request(P_PID, 0, WEXITED) == null);
    try std.testing.expect(request(P_PGID, 0, WEXITED) == null);
    try std.testing.expect(request(7, 1, WEXITED) == null);
    try std.testing.expect(request(P_ALL, 0, 0) == null);
    try std.testing.expect(request(P_ALL, 0, WNOHANG) == null);
    try std.testing.expect(request(P_ALL, 0, WEXITED | 0x100000) == null);
    try std.testing.expect(request(P_PID, 0x1_0000_0000, WEXITED) == null);
}

test "a zombie reports its exit or its signal, and WNOWAIT does not reap" {
    const exited: Child = .{ .zombie = true, .exit_value = 7 };
    const e = report(WEXITED, exited).?;
    try std.testing.expectEqual(CLD_EXITED, e.code);
    try std.testing.expectEqual(@as(u32, 7), e.status);
    try std.testing.expect(e.reap);
    const kept = report(WEXITED | WNOWAIT, exited).?;
    try std.testing.expect(!kept.reap);
    try std.testing.expect(report(WSTOPPED, exited) == null);
    const killed = report(WEXITED, .{ .zombie = true, .signaled = true, .exit_value = 9 }).?;
    try std.testing.expectEqual(CLD_KILLED, killed.code);
    try std.testing.expectEqual(@as(u32, 9), killed.status);
}

test "a stop and a continue are reported once each, and an exit wins" {
    const stopped: Child = .{ .zombie = false, .stop_sig = 19 };
    const s = report(WSTOPPED, stopped).?;
    try std.testing.expectEqual(CLD_STOPPED, s.code);
    try std.testing.expectEqual(@as(u32, 19), s.status);
    try std.testing.expect(!s.reap);
    try std.testing.expect(report(WEXITED | WNOHANG, stopped) == null);
    const cont = report(WCONTINUED, .{ .zombie = false, .continued = true }).?;
    try std.testing.expectEqual(CLD_CONTINUED, cont.code);
    try std.testing.expectEqual(@as(u32, SIGCONT), cont.status);
    const both = report(WEXITED | WSTOPPED, .{ .zombie = true, .exit_value = 3, .stop_sig = 19 }).?;
    try std.testing.expectEqual(CLD_EXITED, both.code);
}
