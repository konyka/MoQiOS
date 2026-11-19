//! Pure rules for signalfd (Linux fs/signalfd.c): the signalfd4 argument checks and the 128-byte struct signalfd_siginfo a read
//! returns for one dequeued signal (signalfd_copyinfo).

const si = @import("siginfo_policy.zig");

pub const SFD_NONBLOCK: u64 = 0x800;
pub const SFD_CLOEXEC: u64 = 0x80000;
pub const RECORD_SIZE: usize = 128;
const UNBLOCKABLE: u64 = (1 << 8) | (1 << 18); // SIGKILL, SIGSTOP

/// signalfd4: sizemask must be sizeof(sigset_t) and only SFD_NONBLOCK / SFD_CLOEXEC may be set (EINVAL otherwise).
pub fn argsErrno(sizemask: u64, flags: u64) i64 {
    if (sizemask != 8) return -22;
    if (flags & ~(SFD_NONBLOCK | SFD_CLOEXEC) != 0) return -22;
    return 0;
}

/// The mask a signalfd keeps: SIGKILL and SIGSTOP can never be read from one (sigdelsetmask).
pub fn cleanMask(mask: u64) u64 {
    return mask & ~UNBLOCKABLE;
}

fn put32(out: *[RECORD_SIZE]u8, off: usize, v: u32) void {
    out[off] = @truncate(v);
    out[off + 1] = @truncate(v >> 8);
    out[off + 2] = @truncate(v >> 16);
    out[off + 3] = @truncate(v >> 24);
}

fn put64(out: *[RECORD_SIZE]u8, off: usize, v: u64) void {
    put32(out, off, @truncate(v));
    put32(out, off + 4, @truncate(v >> 32));
}

/// The signalfd_siginfo for signal `signo` taken with `info`: ssi_signo@0, ssi_code@8, then by layout ssi_pid@12 / ssi_uid@16 (kill,
/// sigqueue, SIGCHLD), ssi_tid@24 / ssi_overrun@32 (a POSIX timer), ssi_status@40 (SIGCHLD), ssi_int@44 / ssi_ptr@48 (sigqueue, a
/// timer), ssi_addr@72 (a fault). Unused fields are 0.
pub fn encode(signo: u32, info: si.Info) [RECORD_SIZE]u8 {
    var out: [RECORD_SIZE]u8 = @splat(0);
    put32(&out, 0, signo);
    put32(&out, 8, @bitCast(info.code));
    const fault = signo == 11 or signo == 7 or signo == 4 or signo == 8 or signo == 5; // SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP
    if (info.code == si.SI_TIMER) {
        put32(&out, 24, @truncate(info.a)); // timer id
        put32(&out, 32, @truncate(info.a >> 32)); // overrun
        put32(&out, 44, @truncate(info.b));
        put64(&out, 48, info.b);
    } else if (fault and info.code > 0 and info.code != si.SI_KERNEL) {
        put64(&out, 72, info.a);
    } else {
        put32(&out, 12, @truncate(info.a)); // pid
        put32(&out, 16, @truncate(info.a >> 32)); // uid
        if (signo == 17) {
            put32(&out, 40, @truncate(info.b)); // SIGCHLD status
        } else if (info.code < 0) {
            put32(&out, 44, @truncate(info.b));
            put64(&out, 48, info.b);
        }
    }
    return out;
}
