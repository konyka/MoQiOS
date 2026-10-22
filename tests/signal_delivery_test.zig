const std = @import("std");
const p = @import("kernel_shared").signal_delivery_policy;

const SIGINT: u32 = 2;
const SIGUSR1: u32 = 10;
const SIGALRM: u32 = 14;

fn bit(s: u32) u64 {
    return @as(u64, 1) << @intCast(s - 1);
}

test "handler mask blocks the delivered signal and its sa_mask" {
    const m = p.handlerMask(0, SIGALRM, bit(SIGUSR1), 0);
    try std.testing.expect(m & bit(SIGALRM) != 0);
    try std.testing.expect(m & bit(SIGUSR1) != 0);
    try std.testing.expect(m & bit(SIGINT) == 0);
}

test "handler mask keeps the interrupted mask" {
    const m = p.handlerMask(bit(SIGINT), SIGALRM, 0, 0);
    try std.testing.expect(m & bit(SIGINT) != 0);
    try std.testing.expect(m & bit(SIGALRM) != 0);
}

test "SA_NODEFER leaves the delivered signal unblocked" {
    const m = p.handlerMask(0, SIGALRM, 0, p.SA_NODEFER);
    try std.testing.expect(m & bit(SIGALRM) == 0);
}

test "SIGKILL and SIGSTOP are never blocked during a handler" {
    const m = p.handlerMask(~@as(u64, 0), SIGALRM, ~@as(u64, 0), 0);
    try std.testing.expect(m & bit(9) == 0);
    try std.testing.expect(m & bit(19) == 0);
    try std.testing.expect(p.restoredMask(~@as(u64, 0)) & bit(9) == 0);
}

test "SA_RESETHAND makes the handler one-shot" {
    try std.testing.expectEqual(@as(u64, 0), p.handlerAfterDelivery(0x401000, p.SA_RESETHAND));
    try std.testing.expectEqual(@as(u64, 0x401000), p.handlerAfterDelivery(0x401000, 0));
}

test "sigreturn restores the saved interrupted mask" {
    try std.testing.expectEqual(bit(SIGINT), p.restoredMask(bit(SIGINT)));
}
