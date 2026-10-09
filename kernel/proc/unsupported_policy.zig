//! Pure policy for syscall ABIs that are not implemented by MoQiOS.

const errno = @import("../lib/errno.zig");

pub fn acct() i64 {
    return errno.ENOSYS;
}

pub fn unshare() i64 {
    return errno.ENOSYS;
}

pub fn processMadvise() i64 {
    return errno.ENOSYS;
}

pub fn mountSetattr() i64 {
    return errno.ENOSYS;
}

pub fn quotactlFd() i64 {
    return errno.ENOSYS;
}

pub fn rseqSliceYield() i64 {
    return errno.ENOSYS;
}

pub fn processMrelease() i64 {
    return errno.ENOSYS;
}

pub fn memfdSecret() i64 {
    return errno.ENOSYS;
}

pub fn listns() i64 {
    return errno.ENOSYS;
}

pub fn landlock() i64 {
    return errno.ENOSYS;
}

pub fn lsm() i64 {
    return errno.ENOSYS;
}
