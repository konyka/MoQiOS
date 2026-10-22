//! Pure Linux wait-status encoding (the int that waitpid/wait4 write back).
//!
//!   normal exit(code):  (code & 0xff) << 8        WIFEXITED,  WEXITSTATUS
//!   killed by signal:   sig & 0x7f                WIFSIGNALED, WTERMSIG
//!
//! The kernel's internal exit paths still report a signal death as
//! `128 + sig` (exitTask callers, fault handlers); `fromInternal` tells the
//! two apart using the exit() syscall's own marker, so `exit(137)` and a
//! SIGKILL are no longer indistinguishable.

pub const Exit = struct {
    /// True when the task died from a signal, false for exit()/_exit().
    signaled: bool,
    /// Exit status (0-255) or signal number (1-127).
    value: u8,
};

/// Classify an internal exit code. `via_exit_syscall` is true only for the
/// exit()/_exit() syscall path; every other exitTask caller reports a
/// signal death as 128 + sig.
pub fn fromInternal(internal_code: i32, via_exit_syscall: bool) Exit {
    if (via_exit_syscall) return .{ .signaled = false, .value = @truncate(@as(u32, @bitCast(internal_code))) };
    if (internal_code > 128 and internal_code < 256)
        return .{ .signaled = true, .value = @intCast(internal_code - 128) };
    return .{ .signaled = false, .value = @truncate(@as(u32, @bitCast(internal_code))) };
}

/// The status word waitpid writes to user memory.
pub fn encode(e: Exit) i32 {
    if (e.signaled) return @as(i32, e.value & 0x7f);
    return @as(i32, e.value) << 8;
}

pub fn wifexited(status: i32) bool {
    return (status & 0x7f) == 0;
}
pub fn wexitstatus(status: i32) u8 {
    return @truncate(@as(u32, @bitCast(status)) >> 8);
}
pub fn wifsignaled(status: i32) bool {
    const low = status & 0x7f;
    return low != 0 and low != 0x7f;
}
pub fn wtermsig(status: i32) u8 {
    return @intCast(status & 0x7f);
}
