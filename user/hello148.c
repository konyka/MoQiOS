/// hello135: signal call argument and errno rules.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_OPEN      9
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_SOCKETPAIR 53
#define SYS_UNLINK    87
#define SYS_MKDIR     83
#define SYS_RMDIR     84
#define SYS_FSTAT     110
#define SYS_SOCKET    117
#define SYS_EVENTFD2  169
#define SYS_EPOLL_CREATE1 146
#define O_RDWR_CREAT 0x42
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define S_IFMT   0170000
#define S_IFSOCK 0140000
#define S_IFLNK  0120000
#define S_IFREG  0100000
#define S_IFBLK  0060000
#define S_IFDIR  0040000
#define S_IFCHR  0020000
#define S_IFIFO  0010000

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello148:   ok   " : "hello148:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
/* struct stat (x86-64): dev@0 ino@8 nlink@16 mode@24 uid@28 gid@32 rdev@40 size@48 blksize@56 blocks@64 */
static uint64_t st[18];
static int64_t fstat_of(int64_t fd) {
    for (int i = 0; i < 18; i++) st[i] = 0xAAAAAAAAAAAAAAAAULL;
    return syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)st);
}
static uint32_t st_mode(void) { return (uint32_t)(st[3] & 0xFFFFFFFF); }
static uint64_t st_ino(void) { return st[1]; }
static uint64_t st_nlink(void) { return st[2]; }

void _start(void) {
    print("hello148: fstat reports the right file type for every descriptor kind\n");

    /* A: pipes, sockets, eventfd, epoll */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        check(fstat_of(pp[0]) == 0 && (st_mode() & S_IFMT) == S_IFIFO, "A: a pipe read end is S_IFIFO");
        check(fstat_of(pp[1]) == 0 && (st_mode() & S_IFMT) == S_IFIFO, "A: a pipe write end is S_IFIFO");
        check((st_mode() & 0222) != 0 && (st_mode() & 0111) == 0, "A: the write end is writable and not executable");
        syscall1(SYS_CLOSE, pp[0]); syscall1(SYS_CLOSE, pp[1]);

        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        check(fstat_of(sv[0]) == 0 && (st_mode() & S_IFMT) == S_IFSOCK, "A: an AF_UNIX socket is S_IFSOCK");
        syscall1(SYS_CLOSE, sv[0]); syscall1(SYS_CLOSE, sv[1]);

        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        check(fstat_of(u) == 0 && (st_mode() & S_IFMT) == S_IFSOCK, "A: a UDP socket is S_IFSOCK");
        syscall1(SYS_CLOSE, u);
        int64_t t = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        check(fstat_of(t) == 0 && (st_mode() & S_IFMT) == S_IFSOCK, "A: a TCP socket is S_IFSOCK");
        syscall1(SYS_CLOSE, t);

        int64_t e = syscall2(SYS_EVENTFD2, 0, 0);
        check(fstat_of(e) == 0 && st_mode() == (S_IFREG | 0600), "A: an eventfd is an anonymous inode: S_IFREG, mode 0600 (as on Linux)");
        syscall1(SYS_CLOSE, e);
        int64_t ep = syscall1(SYS_EPOLL_CREATE1, 0);
        check(fstat_of(ep) == 0 && st_mode() == (S_IFREG | 0600), "A: an epoll instance is an anonymous inode: S_IFREG, mode 0600");
        syscall1(SYS_CLOSE, ep);
    }

    /* B: devices and the console */
    {
        int64_t nul = syscall3(SYS_OPEN, (uint64_t)"/dev/null", 2, 0);
        check(nul >= 0 && fstat_of(nul) == 0 && (st_mode() & S_IFMT) == S_IFCHR, "B: /dev/null is S_IFCHR");
        syscall1(SYS_CLOSE, nul);
        check(fstat_of(1) == 0 && (st_mode() & S_IFMT) == S_IFCHR, "B: stdout is S_IFCHR");
        int64_t dd = syscall3(SYS_OPEN, (uint64_t)"/dev", 0, 0);
        check(dd >= 0 && fstat_of(dd) == 0 && (st_mode() & S_IFMT) == S_IFDIR, "B: the /dev directory is S_IFDIR");
        syscall1(SYS_CLOSE, dd);
    }

    /* C: files and directories on each filesystem */
    {
        syscall1(SYS_UNLINK, (uint64_t)"/testdir/h148-f");
        int64_t f = syscall3(SYS_OPEN, (uint64_t)"/testdir/h148-f", O_RDWR_CREAT, 0644);
        syscall3(SYS_WRITE, f, (uint64_t)"abcde", 5);
        check(fstat_of(f) == 0 && (st_mode() & S_IFMT) == S_IFREG && st[6] == 5, "C: an ext2 file is S_IFREG with the right size");
        check(st_nlink() == 1, "C: with one link");
        uint64_t ino = st_ino();
        check(ino > 2 && ino != (uint64_t)f, "C: and its inode number is the real one, not the fd");
        syscall1(SYS_CLOSE, f);
        syscall1(SYS_UNLINK, (uint64_t)"/testdir/h148-f");

        int64_t d = syscall3(SYS_OPEN, (uint64_t)"/testdir", 0, 0);
        check(d >= 0 && fstat_of(d) == 0 && (st_mode() & S_IFMT) == S_IFDIR, "C: an ext2 directory is S_IFDIR");
        syscall1(SYS_CLOSE, d);

        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h148-t");
        int64_t tf = syscall3(SYS_OPEN, (uint64_t)"/tmp/h148-t", O_RDWR_CREAT, 0644);
        syscall3(SYS_WRITE, tf, (uint64_t)"xyz", 3);
        check(fstat_of(tf) == 0 && (st_mode() & S_IFMT) == S_IFREG && st[6] == 3, "C: a tmpfs file is S_IFREG with the right size");
        uint64_t tino = st_ino();
        int64_t tf2 = syscall3(SYS_OPEN, (uint64_t)"/tmp/h148-t2", O_RDWR_CREAT, 0644);
        fstat_of(tf2);
        check(st_ino() != tino, "C: two tmpfs files have different inode numbers");
        syscall1(SYS_CLOSE, tf2); syscall1(SYS_UNLINK, (uint64_t)"/tmp/h148-t2");
        syscall1(SYS_CLOSE, tf);
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h148-t");
    }

    /* D: st_blksize and st_nlink are never garbage, and a closed fd is EBADF */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        fstat_of(pp[0]);
        check(st_nlink() == 1, "D: a pipe has one link");
        check(st[7] != 0xAAAAAAAAAAAAAAAAULL, "D: st_blksize was written");
        syscall1(SYS_CLOSE, pp[0]); syscall1(SYS_CLOSE, pp[1]);
        check(fstat_of(55) == -9, "D: a closed fd is EBADF");
        check(syscall2(SYS_FSTAT, 1, 0) < 0, "D: a NULL buffer is an error");
    }

    /* E: statx(AT_EMPTY_PATH) on a descriptor agrees with fstat */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        uint8_t sx[144];
        for (int i = 0; i < 144; i++) sx[i] = 0xEE;
        fstat_of(pp[0]);
        uint32_t fm = st_mode();
        int64_t r = syscall5(183, (uint64_t)pp[0], (uint64_t)"", 0x1000, 0x7ff, (uint64_t)sx);
        uint16_t sm = *(uint16_t *)(sx + 28);
        check(r == 0 && (sm & S_IFMT) == S_IFIFO && sm == (uint16_t)fm, "E: statx of a pipe descriptor reports S_IFIFO, like fstat");
        syscall1(SYS_CLOSE, pp[0]); syscall1(SYS_CLOSE, pp[1]);
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        r = syscall5(183, (uint64_t)sv[0], (uint64_t)"", 0x1000, 0x7ff, (uint64_t)sx);
        sm = *(uint16_t *)(sx + 28);
        check(r == 0 && (sm & S_IFMT) == S_IFSOCK, "E: statx of a socket descriptor reports S_IFSOCK");
        syscall1(SYS_CLOSE, sv[0]); syscall1(SYS_CLOSE, sv[1]);
        int64_t nul = syscall3(SYS_OPEN, (uint64_t)"/dev/null", 2, 0);
        r = syscall5(183, (uint64_t)nul, (uint64_t)"", 0x1000, 0x7ff, (uint64_t)sx);
        sm = *(uint16_t *)(sx + 28);
        check(r == 0 && (sm & S_IFMT) == S_IFCHR, "E: statx of /dev/null reports S_IFCHR");
        syscall1(SYS_CLOSE, nul);
    }

    print(failures == 0 ? "hello148: PASS\n" : "hello148: FAIL\n");
    print("hello148 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
