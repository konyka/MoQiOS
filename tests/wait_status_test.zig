const std = @import("std");
const p = @import("kernel_shared").wait_status_policy;

test "exit(code) encodes as WIFEXITED with WEXITSTATUS" {
    const s = p.encode(p.fromInternal(1, true));
    try std.testing.expect(p.wifexited(s));
    try std.testing.expect(!p.wifsignaled(s));
    try std.testing.expectEqual(@as(u8, 1), p.wexitstatus(s));
    try std.testing.expectEqual(@as(i32, 0x100), s);
}

test "exit(0) is status 0" {
    try std.testing.expectEqual(@as(i32, 0), p.encode(p.fromInternal(0, true)));
}

test "signal death encodes as WIFSIGNALED with WTERMSIG" {
    const s = p.encode(p.fromInternal(128 + 9, false));
    try std.testing.expect(p.wifsignaled(s));
    try std.testing.expect(!p.wifexited(s));
    try std.testing.expectEqual(@as(u8, 9), p.wtermsig(s));
    try std.testing.expectEqual(@as(i32, 9), s);
}

test "exit(137) is not mistaken for a SIGKILL death" {
    const by_exit = p.encode(p.fromInternal(137, true));
    const by_kill = p.encode(p.fromInternal(137, false));
    try std.testing.expect(p.wifexited(by_exit));
    try std.testing.expectEqual(@as(u8, 137), p.wexitstatus(by_exit));
    try std.testing.expect(p.wifsignaled(by_kill));
    try std.testing.expect(by_exit != by_kill);
}

test "SIGSEGV fault death is WTERMSIG 11" {
    const s = p.encode(p.fromInternal(139, false));
    try std.testing.expectEqual(@as(u8, 11), p.wtermsig(s));
}

test "a non-syscall code at or below 128 is treated as a plain exit" {
    const s = p.encode(p.fromInternal(0, false));
    try std.testing.expect(p.wifexited(s));
    try std.testing.expectEqual(@as(u8, 0), p.wexitstatus(s));
}
