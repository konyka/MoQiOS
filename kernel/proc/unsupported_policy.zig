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

pub fn setMempolicyHomeNode() i64 {
    return errno.ENOSYS;
}

pub fn mapShadowStack() i64 {
    return errno.ENOSYS;
}

pub fn statmount() i64 {
    return errno.ENOSYS;
}

pub fn chroot() i64 {
    return errno.ENOSYS;
}

pub fn listmount() i64 {
    return errno.ENOSYS;
}

pub fn landlock() i64 {
    return errno.ENOSYS;
}

pub fn lsm() i64 {
    return errno.ENOSYS;
}

/// name_to_handle_at / open_by_handle_at: no file-handle support.
pub fn fileHandles() i64 {
    return errno.ENOSYS;
}

pub fn openTreeAttr() i64 {
    return errno.ENOSYS;
}

pub fn fileGetattr() i64 {
    return errno.ENOSYS;
}

pub fn fileSetattr() i64 {
    return errno.ENOSYS;
}
