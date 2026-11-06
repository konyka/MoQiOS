//! Pure argument rules for getrandom(2), kept free of kernel state so the host tests can check them.
//!
//! Measured on Linux (glibc 2.43 raw syscall): flags other than GRND_NONBLOCK (1), GRND_RANDOM (2) and GRND_INSECURE (4) are EINVAL, and
//! so is GRND_RANDOM|GRND_INSECURE together; a zero-length request succeeds with 0 whatever the pointer is; a non-zero request with a
//! NULL or unmapped pointer is EFAULT; any length up to 1 MiB (and well beyond) is served in full for an ordinary caller.

pub const GRND_NONBLOCK: u64 = 0x1;
pub const GRND_RANDOM: u64 = 0x2;
pub const GRND_INSECURE: u64 = 0x4;
const KNOWN: u64 = GRND_NONBLOCK | GRND_RANDOM | GRND_INSECURE;

/// Largest request one call serves in full; larger ones return a short count (as Linux does above 32 MiB).
pub const MAX_PER_CALL: u64 = 32 * 1024 * 1024;

pub const Check = union(enum) { ok: u64, err: i64 };

/// 0 bytes to produce, or the errno for flags the kernel refuses. `len` is clamped to MAX_PER_CALL.
pub fn check(len: u64, flags: u64) Check {
    if ((flags & ~KNOWN) != 0) return .{ .err = -22 }; // EINVAL
    if ((flags & GRND_RANDOM) != 0 and (flags & GRND_INSECURE) != 0) return .{ .err = -22 };
    return .{ .ok = if (len > MAX_PER_CALL) MAX_PER_CALL else len };
}

/// Errno for the destination pointer: a zero-length request never touches it.
pub fn pointerErrno(len: u64, valid: bool) i64 {
    if (len == 0) return 0;
    return if (valid) 0 else -14; // EFAULT
}
