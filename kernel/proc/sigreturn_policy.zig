//! Safe validation for user-controlled sigreturn register targets.

pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

/// RFLAGS bits a user task may restore through sigreturn (Linux FIX_EFLAGS):
/// CF PF AF ZF SF TF DF OF RF AC ID. Everything else is kernel-owned — IOPL
/// would grant port I/O and cli/sti, NT/VM/VIF/VIP change iret semantics.
pub const USER_RFLAGS: u64 = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) |
    (1 << 8) | (1 << 10) | (1 << 11) | (1 << 16) | (1 << 18) | (1 << 21);
const FORCED_RFLAGS: u64 = (1 << 1) | (1 << 9);

pub fn userTargetValid(value: u64) bool {
    return value != 0 and value < USER_LIMIT;
}

/// The saved image is legitimately allowed to differ from what user code
/// could set itself: a handler entered from a fault frame carries RF=1.
/// Masking rather than rejecting keeps those returns working.
pub fn sanitizeRflags(value: u64) u64 {
    return (value & USER_RFLAGS) | FORCED_RFLAGS;
}

/// What sigreturn does with uc_mcontext.fpregs (Linux restore_sigcontext → fpu__restore_sig): null resets the FPU to its initial
/// state (fpu__clear_user_states); a pointer that is not 16-byte aligned or not readable user memory fails the sigreturn, which
/// ends in SIGSEGV (badframe → force_sig); anything else is the FXSAVE image to load, wherever the handler pointed it.
pub const FpRestore = enum { init, load, bad };

pub fn fpRestore(fpregs: u64) FpRestore {
    if (fpregs == 0) return .init;
    if (fpregs & 15 != 0 or fpregs >= USER_LIMIT - 512) return .bad;
    return .load;
}

/// The FXSAVE image of a freshly initialised FPU (fninit + the default MXCSR): FCW 0x037F, MXCSR 0x1F80, every register zero.
pub fn initFxsave() [512]u8 {
    var img: [512]u8 = @splat(0);
    img[0] = 0x7F;
    img[1] = 0x03;
    img[24] = 0x80;
    img[25] = 0x1F;
    return img;
}

test "sigreturn's fpregs: null resets, misaligned or kernel is a bad frame" {
    const std = @import("std");
    try std.testing.expectEqual(FpRestore.init, fpRestore(0));
    try std.testing.expectEqual(FpRestore.bad, fpRestore(8));
    try std.testing.expectEqual(FpRestore.bad, fpRestore(0xffff_8000_0000_0000));
    try std.testing.expectEqual(FpRestore.load, fpRestore(0x7fff_0000));
    try std.testing.expectEqual(@as(u8, 0x1F), initFxsave()[25]);
}

test "sigreturn rejects kernel targets and masks privileged flags" {
    const std = @import("std");
    try std.testing.expect(userTargetValid(0x4000));
    try std.testing.expect(!userTargetValid(0));
    try std.testing.expect(!userTargetValid(USER_LIMIT));
    try std.testing.expectEqual(@as(u64, 0x202), sanitizeRflags(0x202));
    try std.testing.expectEqual(@as(u64, 0x203), sanitizeRflags(0x203));
    try std.testing.expectEqual(@as(u64, 0x202), sanitizeRflags(0x2));
    try std.testing.expectEqual(@as(u64, 0x202), sanitizeRflags(0x4202));
    try std.testing.expectEqual(@as(u64, 0x10202), sanitizeRflags(0x10202));
}
