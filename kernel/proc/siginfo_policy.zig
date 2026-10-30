//! Pure siginfo_t / ucontext_t layout and fill rules (Linux x86-64 ABI).
//!
//! The kernel records one `Info` per pending signal number at send time and
//! turns it into the 128-byte siginfo_t handed to SA_SIGINFO handlers:
//!   si_signo@0 si_errno@4 si_code@8, then a union at @16:
//!     kill/queue/timer: si_pid@16 si_uid@20 si_value@24
//!     SIGCHLD:          si_pid@16 si_uid@20 si_status@24
//!     SIGSEGV/SIGBUS:   si_addr@16
//! `a` is the 8 bytes at @16 and `b` the 8 bytes at @24.

const wait_status = @import("wait_status_policy.zig");

pub const SI_USER: i32 = 0;
pub const SI_KERNEL: i32 = 0x80;
pub const SI_QUEUE: i32 = -1;
pub const SI_TKILL: i32 = -6;
pub const CLD_EXITED: i32 = 1;
pub const CLD_KILLED: i32 = 2;
pub const SEGV_MAPERR: i32 = 1;
pub const SEGV_ACCERR: i32 = 2;
pub const BUS_ADRERR: i32 = 2;

pub const SIGINFO_SIZE: usize = 128;

pub const Info = struct {
    code: i32 = SI_USER,
    a: u64 = 0,
    b: u64 = 0,
};

pub fn pidUid(pid: u32, uid: u32) u64 {
    return @as(u64, pid) | (@as(u64, uid) << 32);
}

/// The siginfo_t bytes for `signo` carrying `info`.
pub fn encode(signo: u32, info: Info) [SIGINFO_SIZE]u8 {
    var out: [SIGINFO_SIZE]u8 = @splat(0);
    writeLe(out[0..4], signo);
    writeLe(out[8..12], @bitCast(info.code));
    writeLe64(out[16..24], info.a);
    writeLe64(out[24..32], info.b);
    return out;
}

/// An Info rebuilt from the user-supplied siginfo_t of rt_sigqueueinfo.
pub fn decode(raw: *const [SIGINFO_SIZE]u8) Info {
    return .{
        .code = @bitCast(readLe(raw[8..12])),
        .a = readLe64(raw[16..24]),
        .b = readLe64(raw[24..32]),
    };
}

/// rt_sigqueueinfo/rt_tgsigqueueinfo: a user may forge only SI_QUEUE-style
/// (negative) codes, and never SI_TKILL, towards another process; only a
/// process signalling itself may use any code.
pub fn queueinfoAllowed(code: i32, to_self: bool) bool {
    if (to_self) return true;
    return code < 0 and code != SI_TKILL;
}

/// SIGCHLD siginfo for a child that ended with `internal_code`.
pub fn childInfo(pid: u32, uid: u32, internal_code: i32, via_exit_syscall: bool) Info {
    const e = wait_status.fromInternal(internal_code, via_exit_syscall);
    return .{
        .code = if (e.signaled) CLD_KILLED else CLD_EXITED,
        .a = pidUid(pid, uid),
        .b = e.value,
    };
}

/// SEGV_ACCERR for a protection fault on a present page, SEGV_MAPERR for an
/// unmapped one; BUS_ADRERR for an access wholly past the end of a mapped file.
pub fn faultInfo(bus: bool, present: bool, addr: u64) Info {
    return .{
        .code = if (bus) BUS_ADRERR else if (present) SEGV_ACCERR else SEGV_MAPERR,
        .a = addr,
    };
}

/// ucontext_t as the kernel lays it out on the signal frame (x86-64).
pub const UContext = extern struct {
    flags: u64,
    link: u64,
    ss_sp: u64,
    ss_flags: i32,
    ss_pad: i32,
    ss_size: u64,
    gregs: [23]u64,
    fpregs: u64,
    reserved: [8]u64,
    sigmask: u64,
    sigmask_ext: [15]u64,
    _pad: u64,
};

pub const REG_R8 = 0;
pub const REG_R9 = 1;
pub const REG_R10 = 2;
pub const REG_R11 = 3;
pub const REG_R12 = 4;
pub const REG_R13 = 5;
pub const REG_R14 = 6;
pub const REG_R15 = 7;
pub const REG_RDI = 8;
pub const REG_RSI = 9;
pub const REG_RBP = 10;
pub const REG_RBX = 11;
pub const REG_RDX = 12;
pub const REG_RAX = 13;
pub const REG_RCX = 14;
pub const REG_RSP = 15;
pub const REG_RIP = 16;
pub const REG_EFL = 17;
pub const REG_ERR = 19;
pub const REG_TRAPNO = 20;
pub const REG_CR2 = 22;

comptime {
    if (@offsetOf(UContext, "gregs") != 40) @compileError("ucontext gregs offset");
    if (@offsetOf(UContext, "sigmask") != 296) @compileError("ucontext sigmask offset");
    if (@sizeOf(UContext) % 16 != 0) @compileError("ucontext must keep the FPU image 16-aligned");
}

fn writeLe(dst: *[4]u8, v: u32) void {
    dst.* = .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) };
}
fn readLe(src: *const [4]u8) u32 {
    return @as(u32, src[0]) | (@as(u32, src[1]) << 8) | (@as(u32, src[2]) << 16) | (@as(u32, src[3]) << 24);
}
fn writeLe64(dst: *[8]u8, v: u64) void {
    for (0..8) |i| dst[i] = @truncate(v >> @intCast(i * 8));
}
fn readLe64(src: *const [8]u8) u64 {
    var v: u64 = 0;
    for (0..8) |i| v |= @as(u64, src[i]) << @intCast(i * 8);
    return v;
}

test "siginfo layout matches the Linux x86-64 siginfo_t" {
    const std = @import("std");
    const b = encode(10, .{ .code = SI_QUEUE, .a = pidUid(77, 5), .b = 0xdeadbeef });
    try std.testing.expectEqual(@as(u32, 10), readLe(b[0..4]));
    try std.testing.expectEqual(@as(i32, -1), @as(i32, @bitCast(readLe(b[8..12]))));
    try std.testing.expectEqual(@as(u32, 77), readLe(b[16..20]));
    try std.testing.expectEqual(@as(u32, 5), readLe(b[20..24]));
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), readLe64(b[24..32]));
    try std.testing.expectEqual(@as(u8, 0), b[100]);
    const round = decode(&b);
    try std.testing.expectEqual(SI_QUEUE, round.code);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), round.b);
}

test "rt_sigqueueinfo may only forge negative codes towards others" {
    const std = @import("std");
    try std.testing.expect(queueinfoAllowed(SI_QUEUE, false));
    try std.testing.expect(!queueinfoAllowed(SI_USER, false));
    try std.testing.expect(!queueinfoAllowed(SI_KERNEL, false));
    try std.testing.expect(!queueinfoAllowed(SI_TKILL, false));
    try std.testing.expect(queueinfoAllowed(SI_USER, true));
    try std.testing.expect(queueinfoAllowed(SI_TKILL, true));
}

test "child and fault siginfo" {
    const std = @import("std");
    const exited = childInfo(9, 0, 7, true);
    try std.testing.expectEqual(CLD_EXITED, exited.code);
    try std.testing.expectEqual(@as(u64, 7), exited.b);
    try std.testing.expectEqual(pidUid(9, 0), exited.a);
    const killed = childInfo(9, 0, 128 + 11, false);
    try std.testing.expectEqual(CLD_KILLED, killed.code);
    try std.testing.expectEqual(@as(u64, 11), killed.b);
    try std.testing.expectEqual(SEGV_MAPERR, faultInfo(false, false, 0x10).code);
    try std.testing.expectEqual(SEGV_ACCERR, faultInfo(false, true, 0x10).code);
    try std.testing.expectEqual(BUS_ADRERR, faultInfo(true, false, 0x10).code);
    try std.testing.expectEqual(@as(u64, 0x10), faultInfo(false, false, 0x10).a);
}
