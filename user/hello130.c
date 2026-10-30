/// hello130: fcntl / dup3 / pipe semantics.

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
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_UNLINK    87
#define SYS_FCNTL     142
#define SYS_DUP       160
#define SYS_DUP3      161
#define SYS_PIPE2     250
#define SYS_RT_SIGACTION 13
#define F_DUPFD 0
#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4
#define F_DUPFD_CLOEXEC 1030
#define FD_CLOEXEC 1
#define O_RDONLY 0
#define O_RDWR 2
#define O_NONBLOCK 0x800
#define O_APPEND 0x400
#define O_CLOEXEC 0x80000
#define O_RDWR_CREAT 0x42

#define EAGAIN_ 11
#define EBADF_  9
#define EINVAL_ 22
#define EMFILE_ 24
#define EPIPE_  32

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello130:   ok   " : "hello130:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t fcntl(int64_t fd, uint64_t cmd, uint64_t arg) { return syscall3(SYS_FCNTL, (uint64_t)fd, cmd, arg); }

void _start(void) {
    print("hello130: fcntl, dup3, pipes\n");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h130");
    int64_t f = syscall3(SYS_OPEN, (uint64_t)"/tmp/h130", O_RDWR_CREAT | O_APPEND, 0644);

    /* A: F_GETFL / F_SETFL / F_GETFD / F_SETFD */
    int64_t fl = fcntl(f, F_GETFL, 0);
    check(fl >= 0 && (fl & 3) == O_RDWR, "F_GETFL reports the access mode (O_RDWR)");
    check(fl >= 0 && (fl & O_APPEND) != 0, "F_GETFL reports O_APPEND");
    check(fcntl(f, F_SETFL, O_NONBLOCK) == 0 && (fcntl(f, F_GETFL, 0) & O_NONBLOCK) != 0, "F_SETFL sets O_NONBLOCK");
    check((fcntl(f, F_GETFL, 0) & O_APPEND) == 0, "F_SETFL replaces the modifiable bits (O_APPEND cleared)");
    check((fcntl(f, F_GETFL, 0) & 3) == O_RDWR, "F_SETFL leaves the access mode alone");
    check(fcntl(f, F_GETFD, 0) == 0, "FD_CLOEXEC is clear by default");
    check(fcntl(f, F_SETFD, FD_CLOEXEC) == 0 && fcntl(f, F_GETFD, 0) == FD_CLOEXEC, "F_SETFD sets FD_CLOEXEC");
    check(fcntl(f, 9999, 0) == -EINVAL_, "an unknown fcntl command is EINVAL");
    check(fcntl(999, F_GETFD, 0) == -EBADF_, "fcntl on a bad fd is EBADF");

    /* B: dup variants and the cloexec bit */
    int64_t d = syscall1(SYS_DUP, (uint64_t)f);
    check(d >= 0 && fcntl(d, F_GETFD, 0) == 0, "dup clears FD_CLOEXEC on the copy");
    int64_t d2 = fcntl(f, F_DUPFD, 20);
    check(d2 >= 20, "F_DUPFD returns the lowest free fd >= arg");
    check(d2 >= 0 && fcntl(d2, F_GETFD, 0) == 0, "F_DUPFD does not set FD_CLOEXEC");
    int64_t d3 = fcntl(f, F_DUPFD_CLOEXEC, 30);
    check(d3 >= 30 && fcntl(d3, F_GETFD, 0) == FD_CLOEXEC, "F_DUPFD_CLOEXEC sets FD_CLOEXEC");
    check(fcntl(f, F_DUPFD, 1000) == -EINVAL_, "F_DUPFD with a minimum beyond the table is EINVAL");
    check(syscall3(SYS_DUP3, (uint64_t)f, 40, O_CLOEXEC) == 40 && fcntl(40, F_GETFD, 0) == FD_CLOEXEC, "dup3(O_CLOEXEC) sets FD_CLOEXEC");
    check(syscall3(SYS_DUP3, (uint64_t)f, 41, 0) == 41 && fcntl(41, F_GETFD, 0) == 0, "dup3(0) leaves it clear");
    check(syscall3(SYS_DUP3, (uint64_t)f, (uint64_t)f, 0) == -EINVAL_, "dup3 with oldfd == newfd is EINVAL");
    check(syscall3(SYS_DUP3, 999, 42, 0) == -EBADF_, "dup3 of a bad fd is EBADF");
    check(syscall1(SYS_DUP, 999) == -EBADF_, "dup of a bad fd is EBADF");
    /* the status flags belong to the shared open file description */
    check(fcntl(d, F_SETFL, 0) == 0 && (fcntl(f, F_GETFL, 0) & O_NONBLOCK) == 0, "F_SETFL through a dup is visible through the original");
    syscall1(SYS_CLOSE, (uint64_t)d); syscall1(SYS_CLOSE, (uint64_t)d2); syscall1(SYS_CLOSE, (uint64_t)d3);
    syscall1(SYS_CLOSE, 40); syscall1(SYS_CLOSE, 41);
    syscall1(SYS_CLOSE, (uint64_t)f);
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h130");

    /* C: pipes */
    int p[2] = { -1, -1 };
    check(syscall1(SYS_PIPE, (uint64_t)p) == 0 && p[0] >= 0 && p[1] >= 0 && p[0] != p[1], "pipe creates two descriptors");
    check((fcntl(p[0], F_GETFL, 0) & 3) == O_RDONLY && (fcntl(p[1], F_GETFL, 0) & 3) == 1, "read end is O_RDONLY, write end O_WRONLY");
    char b[8];
    check(syscall3(SYS_WRITE, (uint64_t)p[0], (uint64_t)"x", 1) < 0, "writing to the read end fails");
    check(syscall3(SYS_READ, (uint64_t)p[1], (uint64_t)b, 1) < 0, "reading from the write end fails");
    check(fcntl(p[0], F_SETFL, O_NONBLOCK) == 0 && syscall3(SYS_READ, (uint64_t)p[0], (uint64_t)b, 4) == -EAGAIN_, "an empty O_NONBLOCK pipe read is EAGAIN");
    check(syscall3(SYS_WRITE, (uint64_t)p[1], (uint64_t)"abc", 3) == 3 && syscall3(SYS_READ, (uint64_t)p[0], (uint64_t)b, 8) == 3 && b[0] == 'a' && b[2] == 'c', "data written is read back in order");
    syscall1(SYS_CLOSE, (uint64_t)p[1]);
    check(syscall3(SYS_READ, (uint64_t)p[0], (uint64_t)b, 4) == 0, "with every writer closed the read returns 0 (EOF)");
    syscall1(SYS_CLOSE, (uint64_t)p[0]);

    int q[2] = { -1, -1 };
    check(syscall2(SYS_PIPE2, (uint64_t)q, O_NONBLOCK | O_CLOEXEC) == 0, "pipe2(O_NONBLOCK|O_CLOEXEC)");
    check((fcntl(q[0], F_GETFL, 0) & O_NONBLOCK) != 0 && fcntl(q[0], F_GETFD, 0) == FD_CLOEXEC, "pipe2 applies both flags to both ends");
    check(fcntl(q[1], F_GETFD, 0) == FD_CLOEXEC, "pipe2 applies O_CLOEXEC to the write end");
    check(syscall2(SYS_PIPE2, (uint64_t)q, 0x4) == -EINVAL_, "pipe2 with unknown flags is EINVAL");
    /* write with no reader: EPIPE (SIGPIPE ignored so the write reports it) */
    {
        uint64_t act[4] = { 1 /* SIG_IGN */, 0, 0, 0 };
        syscall4(SYS_RT_SIGACTION, 13, (uint64_t)act, 0, 8);
        syscall1(SYS_CLOSE, (uint64_t)q[0]);
        check(syscall3(SYS_WRITE, (uint64_t)q[1], (uint64_t)"z", 1) == -EPIPE_, "a write with no reader is EPIPE");
        syscall1(SYS_CLOSE, (uint64_t)q[1]);
    }
    /* a full non-blocking pipe: EAGAIN, and the bytes that fit were accepted */
    {
        int r[2];
        syscall2(SYS_PIPE2, (uint64_t)r, O_NONBLOCK);
        static char big[8192];
        for (int i = 0; i < 8192; i++) big[i] = 'p';
        int64_t w1 = syscall3(SYS_WRITE, (uint64_t)r[1], (uint64_t)big, 8192);
        check(w1 > 0 && w1 <= 8192, "a large write to an empty pipe is accepted (possibly short)");
        int64_t w2 = 0, total = w1;
        int guard = 0;
        while (w2 >= 0 && guard++ < 64) { w2 = syscall3(SYS_WRITE, (uint64_t)r[1], (uint64_t)big, 4096); if (w2 > 0) total += w2; }
        check(w2 == -EAGAIN_, "a full O_NONBLOCK pipe write is EAGAIN");
        char rb[4096]; int64_t got = 0, n;
        while ((n = syscall3(SYS_READ, (uint64_t)r[0], (uint64_t)rb, 4096)) > 0) got += n;
        check(got == total, "everything accepted can be read back");
        syscall1(SYS_CLOSE, (uint64_t)r[0]); syscall1(SYS_CLOSE, (uint64_t)r[1]);
    }

    print(failures == 0 ? "hello130: PASS\n" : "hello130: FAIL\n");
    print("hello130 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
