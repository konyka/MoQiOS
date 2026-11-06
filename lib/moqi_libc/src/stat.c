/* stat.c -- stat, lstat, fstat, chmod, fchmod, readlink, symlink and link (see include/stat.h). */
#include <string.h>

#include "../include/stat.h"
#include "hostsys.h"

#define AT_FDCWD_ARG (-100L)
#define AT_SYMLINK_NOFOLLOW_ARG 0x100L
#define STATX_BASIC_ALL 0x7ffL

#define STATX_TYPE   0x1u
#define STATX_MODE   0x2u
#define STATX_NLINK  0x4u
#define STATX_UID    0x8u
#define STATX_GID    0x10u
#define STATX_ATIME  0x20u
#define STATX_MTIME  0x40u
#define STATX_CTIME  0x80u
#define STATX_INO    0x100u
#define STATX_SIZE   0x200u
#define STATX_BLOCKS 0x400u

static unsigned int rd32(const unsigned char *p, int o) {
    unsigned int v;
    memcpy(&v, p + o, 4);
    return v;
}
static unsigned long rd64(const unsigned char *p, int o) {
    unsigned long v;
    memcpy(&v, p + o, 8);
    return v;
}

/* The 144-byte statx the kernel fills is converted field by field; what its mask does not claim is 0. */
static int stat_via_statx(const char *path, struct stat *buf, long flags) {
    unsigned char sx[144];
    long r = MSYS5(SYS_statx, AT_FDCWD_ARG, path, flags, STATX_BASIC_ALL, sx);
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    unsigned int mask = rd32(sx, 0);
    memset(buf, 0, sizeof *buf);
    buf->st_blksize = (long)rd32(sx, 4);
    if (mask & STATX_NLINK) buf->st_nlink = rd32(sx, 16);
    if (mask & STATX_UID) buf->st_uid = rd32(sx, 20);
    if (mask & STATX_GID) buf->st_gid = rd32(sx, 24);
    if (mask & (STATX_TYPE | STATX_MODE)) buf->st_mode = (unsigned int)(sx[28] | (sx[29] << 8));
    if (mask & STATX_INO) buf->st_ino = rd64(sx, 32);
    if (mask & STATX_SIZE) buf->st_size = (long)rd64(sx, 40);
    if (mask & STATX_BLOCKS) buf->st_blocks = (long)rd64(sx, 48);
    if (mask & STATX_ATIME) { buf->st_atim.tv_sec = (long)rd64(sx, 64); buf->st_atim.tv_nsec = (long)rd32(sx, 72); }
    if (mask & STATX_CTIME) { buf->st_ctim.tv_sec = (long)rd64(sx, 96); buf->st_ctim.tv_nsec = (long)rd32(sx, 104); }
    if (mask & STATX_MTIME) { buf->st_mtim.tv_sec = (long)rd64(sx, 112); buf->st_mtim.tv_nsec = (long)rd32(sx, 120); }
    return 0;
}

int stat(const char *path, struct stat *buf) { return stat_via_statx(path, buf, 0); }
int lstat(const char *path, struct stat *buf) { return stat_via_statx(path, buf, AT_SYMLINK_NOFOLLOW_ARG); }

int fstat(int fd, struct stat *buf) { return __moqi_ret(MSYS2(SYS_fstat, fd, buf)); }

int chmod(const char *path, unsigned int mode) { return __moqi_ret(MSYS2(SYS_chmod, path, mode)); }
int fchmod(int fd, unsigned int mode) { return __moqi_ret(MSYS2(SYS_fchmod, fd, mode)); }

long readlink(const char *path, char *buf, size_t size) {
    long r = MSYS3(SYS_readlink, path, buf, size);
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return r;
}

int symlink(const char *target, const char *linkpath) { return __moqi_ret(MSYS2(SYS_symlink, target, linkpath)); }
int link(const char *oldpath, const char *newpath) { return __moqi_ret(MSYS2(SYS_link, oldpath, newpath)); }
