/* dirent.c — directory streams over getdents64 (see include/dirent.h). */
#include "../include/dirent.h"
#include "../include/errno.h"
#include "../include/stdlib.h"
#include "../include/string.h"
#include "../include/unistd.h"
#include "hostsys.h"

#define DIR_BUFSIZE 4096
#define O_DIRECTORY_ 0x10000
#define O_CLOEXEC_   0x80000
#define S_IFMT_      0170000
#define S_IFDIR_     0040000

struct __moqi_dir {
    int fd;
    int pad;
    unsigned long off;      /* bytes consumed from buf */
    unsigned long len;      /* bytes in buf */
    long next_pos;          /* the kernel's cookie (d_off) of the last record handed out */
    struct dirent cur;
    unsigned char buf[DIR_BUFSIZE] __attribute__((aligned(8)));
};

#ifdef MOQI_HOST_TEST_SYSCALL
#define D_MALLOC(n) test_malloc(n)
#define D_FREE(p) test_free(p)
extern void *test_malloc(unsigned long n);
extern void test_free(void *p);
#else
#define D_MALLOC(n) malloc(n)
#define D_FREE(p) free(p)
#endif

DIR *opendir(const char *path) {
    if (path == (const char *)0 || path[0] == '\0') {
        errno = ENOENT;
        return (DIR *)0;
    }
    long fd = MSYS3(SYS_open, path, O_CLOEXEC_, 0);
    if (__moqi_is_error(fd)) {
        errno = (int)-fd;
        return (DIR *)0;
    }
    /* open() succeeds on any file; a directory is what fstat says it is. */
    unsigned char st[144];
    long r = MSYS2(SYS_fstat, fd, st);
    unsigned int mode = 0;
    if (!__moqi_is_error(r)) mode = (unsigned int)st[24] | ((unsigned int)st[25] << 8) | ((unsigned int)st[26] << 16) | ((unsigned int)st[27] << 24);
    if (__moqi_is_error(r) || (mode & S_IFMT_) != S_IFDIR_) {
        MSYS1(SYS_close, fd);
        errno = __moqi_is_error(r) ? (int)-r : ENOTDIR;
        return (DIR *)0;
    }
    DIR *d = (DIR *)D_MALLOC(sizeof *d);
    if (d == (DIR *)0) {
        MSYS1(SYS_close, fd);
        errno = ENOMEM;
        return (DIR *)0;
    }
    d->fd = (int)fd;
    d->pad = 0;
    d->off = d->len = 0;
    d->next_pos = 0;
    return d;
}

struct dirent *readdir(DIR *d) {
    if (d->off >= d->len) {
        long n = MSYS3(SYS_getdents64, d->fd, d->buf, DIR_BUFSIZE);
        if (__moqi_is_error(n)) {
            errno = (int)-n;
            return (struct dirent *)0;
        }
        if (n == 0) return (struct dirent *)0;
        d->off = 0;
        d->len = (unsigned long)n;
    }
    const unsigned char *rec = d->buf + d->off;
    unsigned long ino = 0, doff = 0;
    for (int i = 7; i >= 0; i--) {
        ino = (ino << 8) | rec[i];
        doff = (doff << 8) | rec[8 + i];
    }
    unsigned short reclen = (unsigned short)(rec[16] | (rec[17] << 8));
    if (reclen < 20 || d->off + reclen > d->len) {
        errno = EIO;
        d->off = d->len;
        return (struct dirent *)0;
    }
    d->cur.d_ino = ino;
    d->cur.d_off = (long)doff;
    d->cur.d_reclen = reclen;
    d->cur.d_type = rec[18];
    unsigned long max_name = reclen - 19;
    unsigned long i = 0;
    while (i < max_name && i < sizeof d->cur.d_name - 1 && rec[19 + i]) {
        d->cur.d_name[i] = (char)rec[19 + i];
        i++;
    }
    d->cur.d_name[i] = '\0';
    d->off += reclen;
    d->next_pos = (long)doff;
    return &d->cur;
}

int closedir(DIR *d) {
    long r = MSYS1(SYS_close, d->fd);
    D_FREE(d);
    return __moqi_ret(r);
}

void rewinddir(DIR *d) {
    MSYS3(SYS_lseek, d->fd, 0, 0);
    d->off = d->len = 0;
    d->next_pos = 0;
}

long telldir(DIR *d) {
    return d->next_pos;
}

void seekdir(DIR *d, long pos) {
    MSYS3(SYS_lseek, d->fd, pos, 0);
    d->off = d->len = 0;
    d->next_pos = pos;
}

int dirfd(DIR *d) {
    return d->fd;
}
