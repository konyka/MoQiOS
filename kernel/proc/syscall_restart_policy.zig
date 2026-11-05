//! Pure SA_RESTART rules (POSIX sigaction semantics).
//!
//! A blocking system call that a signal handler interrupts returns -EINTR. When the handler was installed with SA_RESTART and the
//! call is one of the restartable kind, the kernel instead arranges for the call to run again once the handler has returned:
//! the saved user context gets the syscall number back in rax and its rip moved back over the 2-byte `syscall` instruction, so
//! sigreturn resumes at the instruction and the arguments (still in rdi/rsi/rdx/r10/r8/r9) are used again.
//! Sleeps, pause, sigsuspend, poll/select/epoll waits and timers are never restarted: they keep returning -EINTR.

pub const SA_RESTART: u64 = 0x1000_0000;
pub const EINTR_RESULT: i64 = -4;
pub const SYSCALL_INSN_LEN: u64 = 2;

/// Native syscall numbers that restart: write (1), waitpid (6) and read (10) -- the calls whose dispatch delivers the handler on the
/// way out (checkSignalsOnSyscallReturn), which is where the restart is arranged.
pub fn restartable(nr: u64) bool {
    return switch (nr) {
        1, 6, 10 => true,
        else => false,
    };
}

pub fn shouldRestart(result: i64, nr: u64, sa_flags: u64) bool {
    return result == EINTR_RESULT and sa_flags & SA_RESTART != 0 and restartable(nr);
}

/// User rip to resume at when the call is restarted: back over the `syscall` instruction.
pub fn restartRip(rip_after_syscall: u64) u64 {
    return rip_after_syscall - SYSCALL_INSN_LEN;
}

const testing = @import("std").testing;

test "only an EINTR result under SA_RESTART restarts" {
    try testing.expect(shouldRestart(-4, 10, SA_RESTART));
    try testing.expect(!shouldRestart(-4, 10, 0));
    try testing.expect(!shouldRestart(3, 10, SA_RESTART));
    try testing.expect(!shouldRestart(-11, 10, SA_RESTART));
    try testing.expect(!shouldRestart(0, 6, SA_RESTART));
}

test "other flag bits do not matter" {
    try testing.expect(shouldRestart(-4, 6, SA_RESTART | 0x4000_0000 | 0x0400_0000));
    try testing.expect(!shouldRestart(-4, 6, 0x4000_0000 | 0x0400_0000));
}

test "read, write and waitpid restart" {
    for ([_]u64{ 1, 6, 10 }) |nr| try testing.expect(restartable(nr));
}

test "sleeps and waits that name a timeout never restart" {
    // nanosleep 35/199, clock_nanosleep 247, pause 34, rt_sigsuspend 220, epoll_pwait 248/441, futex 143, select/poll
    for ([_]u64{ 35, 199, 247, 34, 220, 248, 441, 143, 61, 263, 0, 2, 9, 11 }) |nr| {
        try testing.expect(!restartable(nr));
        try testing.expect(!shouldRestart(-4, nr, SA_RESTART));
    }
}

test "restart rewinds exactly the syscall instruction" {
    try testing.expectEqual(@as(u64, 0x401000), restartRip(0x401002));
}
