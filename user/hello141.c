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
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_SOCKETPAIR 53
#define SYS_UNLINK    87
#define SYS_FCNTL     142
#define SYS_IOCTL     165
#define SYS_EVENTFD2  169
#define O_RDWR_CREAT 0x42
#define F_GETFD 1
#define F_GETFL 3
#define FD_CLOEXEC 1
#define O_NONBLOCK 0x800
#define TCGETS     0x5401
#define TCSETS     0x5402
#define TIOCGPGRP  0x540F
#define TIOCSPGRP  0x5410
#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414
#define FIONREAD   0x541B
#define FIONBIO    0x5421
#define FIOCLEX    0x5451
#define FIONCLEX   0x5450
#define EBADF_  9
#define EFAULT_ 14
#define ENOTTY_ 25
#define EINVAL_ 22

struct winsize { uint16_t row, col, xp, yp; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello141:   ok   " : "hello141:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t ioctl(int64_t fd, uint64_t cmd, uint64_t arg) { return syscall3(SYS_IOCTL, (uint64_t)fd, cmd, arg); }
static int64_t fcntl(int64_t fd, uint64_t cmd, uint64_t arg) { return syscall3(SYS_FCNTL, (uint64_t)fd, cmd, arg); }
#define BAD ((uint64_t)0x8000000000000000ULL)

void _start(void) {
    print("hello141: ioctl requests\n");
    uint8_t termios[64];

    /* A: isatty() is TCGETS: only terminals answer */
    {
        int64_t f = syscall3(SYS_OPEN, (uint64_t)"/tmp/h141", O_RDWR_CREAT, 0644);
        check(f >= 0, "A: create a regular file");
        check(ioctl(f, TCGETS, (uint64_t)termios) == -ENOTTY_, "A: TCGETS on a regular file is ENOTTY");
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        check(ioctl(pp[0], TCGETS, (uint64_t)termios) == -ENOTTY_, "A: TCGETS on a pipe is ENOTTY");
        int sv[2];
        syscall4(SYS_SOCKETPAIR, 1, 1, 0, (uint64_t)sv);
        check(ioctl(sv[0], TCGETS, (uint64_t)termios) == -ENOTTY_, "A: TCGETS on a socket is ENOTTY");
        int64_t e = syscall2(SYS_EVENTFD2, 0, 0);
        check(ioctl(e, TCGETS, (uint64_t)termios) == -ENOTTY_, "A: TCGETS on an eventfd is ENOTTY");
        int64_t nul = syscall3(SYS_OPEN, (uint64_t)"/dev/null", 2, 0);
        check(nul >= 0 && ioctl(nul, TCGETS, (uint64_t)termios) == -ENOTTY_, "A: TCGETS on /dev/null is ENOTTY");
        check(ioctl(0, TCGETS, (uint64_t)termios) == 0 || ioctl(0, TCGETS, (uint64_t)termios) == -ENOTTY_, "A: stdin answers TCGETS (terminal or ENOTTY)");
        check(ioctl(f, TIOCGWINSZ, (uint64_t)termios) == -ENOTTY_, "A: TIOCGWINSZ on a regular file is ENOTTY");
        check(ioctl(pp[0], TIOCGPGRP, (uint64_t)termios) == -ENOTTY_, "A: TIOCGPGRP on a pipe is ENOTTY");
        syscall1(SYS_CLOSE, nul);
        syscall1(SYS_CLOSE, e);
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
        syscall1(SYS_CLOSE, pp[0]);
        syscall1(SYS_CLOSE, pp[1]);
        syscall1(SYS_CLOSE, f);
    }

    /* B: descriptor and pointer validation */
    {
        check(ioctl(99, TCGETS, (uint64_t)termios) == -EBADF_, "B: a closed fd is EBADF");
        check(ioctl(30, FIONREAD, (uint64_t)termios) == -EBADF_, "B: FIONREAD on a closed fd is EBADF");
        check(ioctl(-1, FIONREAD, (uint64_t)termios) == -EBADF_, "B: fd -1 is EBADF");
        check(ioctl(0, 0x12345, 0) == -ENOTTY_, "B: an unknown request is ENOTTY");
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        check(ioctl(pp[0], FIONREAD, 0) == -EFAULT_, "B: FIONREAD(NULL) is EFAULT");
        check(ioctl(pp[0], FIONREAD, BAD) == -EFAULT_, "B: FIONREAD(kernel pointer) is EFAULT");
        syscall1(SYS_CLOSE, pp[0]);
        syscall1(SYS_CLOSE, pp[1]);
    }

    /* C: FIONREAD */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        int n = 99;
        check(ioctl(pp[0], FIONREAD, (uint64_t)&n) == 0 && n == 0, "C: an empty pipe has 0 readable bytes");
        syscall3(SYS_WRITE, pp[1], (uint64_t)"hello", 5);
        check(ioctl(pp[0], FIONREAD, (uint64_t)&n) == 0 && n == 5, "C: a pipe holding 5 bytes reports 5");
        n = 99;
        check(ioctl(pp[1], FIONREAD, (uint64_t)&n) == 0, "C: FIONREAD on the write end succeeds");
        int sv[2];
        syscall4(SYS_SOCKETPAIR, 1, 1, 0, (uint64_t)sv);
        n = 99;
        check(ioctl(sv[0], FIONREAD, (uint64_t)&n) == 0 && n == 0, "C: an idle socket has 0 readable bytes");
        syscall3(SYS_WRITE, sv[1], (uint64_t)"abc", 3);
        check(ioctl(sv[0], FIONREAD, (uint64_t)&n) == 0 && n == 3, "C: a socket holding 3 bytes reports 3");
        int64_t f = syscall3(SYS_OPEN, (uint64_t)"/tmp/h141", O_RDWR_CREAT, 0644);
        syscall3(SYS_WRITE, f, (uint64_t)"0123456789", 10);
        syscall3(197, f, 4, 0);
        n = 99;
        check(ioctl(f, FIONREAD, (uint64_t)&n) == 0 && n == 6, "C: a regular file reports the bytes left after the offset");
        syscall1(SYS_CLOSE, f);
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
        syscall1(SYS_CLOSE, pp[0]);
        syscall1(SYS_CLOSE, pp[1]);
    }

    /* D: FIONBIO, FIOCLEX, FIONCLEX */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        int on = 1, off = 0;
        check(ioctl(pp[0], FIONBIO, (uint64_t)&on) == 0 && (fcntl(pp[0], F_GETFL, 0) & O_NONBLOCK), "D: FIONBIO(1) sets O_NONBLOCK");
        check(ioctl(pp[0], FIONBIO, (uint64_t)&off) == 0 && !(fcntl(pp[0], F_GETFL, 0) & O_NONBLOCK), "D: FIONBIO(0) clears it");
        check(ioctl(pp[0], FIONBIO, 0) == -EFAULT_, "D: FIONBIO(NULL) is EFAULT");
        check(ioctl(pp[0], FIOCLEX, 0) == 0 && fcntl(pp[0], F_GETFD, 0) == FD_CLOEXEC, "D: FIOCLEX sets FD_CLOEXEC");
        check(ioctl(pp[0], FIONCLEX, 0) == 0 && fcntl(pp[0], F_GETFD, 0) == 0, "D: FIONCLEX clears it");
        check(ioctl(77, FIOCLEX, 0) == -EBADF_, "D: FIOCLEX on a closed fd is EBADF");
        syscall1(SYS_CLOSE, pp[0]);
        syscall1(SYS_CLOSE, pp[1]);
    }

    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h141");
    print(failures == 0 ? "hello141: PASS\n" : "hello141: FAIL\n");
    print("hello141 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
