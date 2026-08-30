// hello89 - raw epoll_pwait/epoll_pwait2 timeout, mask, and ABI acceptance.
#include <stdint.h>

static inline int64_t syscall1(uint64_t n, uint64_t a) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall2(uint64_t n, uint64_t a, uint64_t b) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall3(uint64_t n, uint64_t a, uint64_t b, uint64_t c) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall4(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    register uint64_t y __asm__("r10") = d;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x), "r"(y) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall6(uint64_t n, uint64_t a, uint64_t b, uint64_t c,
                               uint64_t d, uint64_t e, uint64_t f) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    register uint64_t y __asm__("r10") = d;
    register uint64_t z __asm__("r8") = e;
    register uint64_t w __asm__("r9") = f;
    __asm__ volatile ("syscall" : "=a"(r)
                      : "a"(n), "D"(a), "S"(b), "r"(x), "r"(y), "r"(z), "r"(w)
                      : "rcx", "r11", "memory");
    return r;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_GETPID 4
#define SYS_CLOSE 11
#define SYS_READ 10
#define SYS_SIGACTION 13
#define SYS_SIGPROCMASK 14
#define SYS_RT_SIGTIMEDWAIT 221
#define SYS_PIPE 22
#define SYS_TKILL 223
#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_CTL 147
#define SYS_EPOLL_PWAIT 248
#define SYS_EPOLL_PWAIT2 441

#define EPOLL_CTL_ADD 1
#define EPOLLIN 0x001
#define EFAULT 14
#define EINVAL 22
#define EINTR 4
#define SIGUSR1 10
#define SIGUSR2 31

struct epoll_event {
    uint32_t events;
    uint64_t data;
};

struct sigaction_raw {
    uint64_t handler;
    uint64_t mask;
    uint64_t flags;
    uint64_t restorer;
};

struct timespec_raw {
    uint64_t sec;
    uint64_t nsec;
};

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello89: FAIL ");
        print(name);
        print("\n");
        return 1;
    }
    return 0;
}

static volatile int handled_signal;

static void sigusr1_handler(int sig) {
    handled_signal = sig;
}

__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (uint64_t)status);
    for (;;) {}
}

static int64_t epoll_pwait_raw(int64_t epfd, struct epoll_event *events,
                               uint64_t maxevents, int64_t timeout,
                               uint64_t *mask, uint64_t sigsetsize) {
    return syscall6(SYS_EPOLL_PWAIT, (uint64_t)epfd, (uint64_t)events,
                    maxevents, (uint64_t)timeout, (uint64_t)mask, sigsetsize);
}

static int64_t epoll_pwait2_raw(int64_t epfd, struct epoll_event *events,
                                uint64_t maxevents, struct timespec_raw *timeout,
                                uint64_t *mask, uint64_t sigsetsize) {
    return syscall6(SYS_EPOLL_PWAIT2, (uint64_t)epfd, (uint64_t)events,
                    maxevents, (uint64_t)timeout, (uint64_t)mask, sigsetsize);
}

void _start(void) {
    int failures = 0;
    int32_t pipe_fds[2] = {-1, -1};
    struct epoll_event registered = {EPOLLIN, 0x89};
    struct epoll_event returned = {0, 0};
    uint64_t old_mask = 0;
    uint64_t temporary_mask = (uint64_t)1 << (SIGUSR2 - 1);
    uint64_t signal_mask = (uint64_t)1 << (SIGUSR2 - 1);
    struct sigaction_raw handled = {(uint64_t)sigusr1_handler, 0, 0, 0};
    struct timespec_raw ts = {0, 0};
    int64_t epfd = -1;
    int64_t pid;

    print("hello89: start\n");
    failures += check(syscall3(SYS_SIGACTION, SIGUSR1, (uint64_t)&handled, 0) == 0,
                      "install SIGUSR1 handler");
    failures += check(syscall6(SYS_SIGPROCMASK, 2, (uint64_t)&signal_mask, 0, 8, 0, 0) == 0,
                      "block test signals");
    failures += check(syscall6(SYS_SIGPROCMASK, 0, 0, (uint64_t)&old_mask, 8, 0, 0) == 0 &&
                      old_mask == signal_mask, "observe blocked signal mask");

    failures += check(syscall1(SYS_PIPE, (uint64_t)pipe_fds) == 0 && pipe_fds[0] >= 0 && pipe_fds[1] >= 0,
                      "create pipe");
    epfd = syscall1(SYS_EPOLL_CREATE1, 0);
    failures += check(epfd >= 0, "create epoll instance");
    if (epfd >= 0 && pipe_fds[0] >= 0) {
        failures += check(syscall4(SYS_EPOLL_CTL, (uint64_t)epfd, EPOLL_CTL_ADD,
                                    (uint64_t)pipe_fds[0], (uint64_t)&registered) == 0,
                          "register pipe with epoll");
    }

    failures += check(epoll_pwait_raw(epfd, &returned, 0, 0, 0, 8) == -EINVAL,
                      "epoll_pwait maxevents zero");
    failures += check(epoll_pwait_raw(epfd, &returned, 1, 0, &temporary_mask, 4) == -EINVAL,
                      "epoll_pwait sigsetsize boundary");
    failures += check(epoll_pwait_raw(epfd, &returned, 1, 0, (uint64_t *)1, 8) == -EFAULT,
                      "epoll_pwait sigmask pointer boundary");
    failures += check(epoll_pwait_raw(epfd, 0, 1, 0, 0, 8) == -EFAULT,
                      "epoll_pwait output pointer boundary");
    failures += check(epoll_pwait_raw(epfd, &returned, 1, 0, 0, 8) == 0,
                      "epoll_pwait zero timeout");

    if (pipe_fds[1] >= 0) {
        failures += check(syscall3(SYS_WRITE, (uint64_t)pipe_fds[1], (uint64_t)"x", 1) == 1,
                          "write pipe event");
        returned.events = 0;
        returned.data = 0;
        failures += check(epoll_pwait_raw(epfd, &returned, 1, 0, 0, 8) == 1 &&
                          returned.events == EPOLLIN && returned.data == 0x89,
                          "epoll_pwait returns ready event");
        char drained;
        failures += check(syscall3(SYS_READ, (uint64_t)pipe_fds[0], (uint64_t)&drained, 1) == 1,
                          "drain epoll_pwait event");
    }

    pid = syscall1(SYS_GETPID, 0);
    failures += check(pid > 0, "get current pid");
    failures += check(syscall2(SYS_TKILL, (uint64_t)pid, SIGUSR2) == 0,
                      "queue blocked SIGUSR2");
    failures += check(epoll_pwait_raw(epfd, &returned, 1, 10, &temporary_mask, 8) == 0,
                      "epoll_pwait ignores temporarily blocked signal");
    failures += check(syscall2(SYS_TKILL, (uint64_t)pid, SIGUSR1) == 0,
                      "queue SIGUSR1");
    failures += check(epoll_pwait_raw(epfd, &returned, 1, 10, &temporary_mask, 8) == -EINTR &&
                      handled_signal == SIGUSR1, "epoll_pwait handled signal interrupts");
    old_mask = 0;
    failures += check(syscall6(SYS_SIGPROCMASK, 0, 0, (uint64_t)&old_mask, 8, 0, 0) == 0 &&
                      old_mask == signal_mask, "epoll_pwait restores signal mask");
    failures += check(syscall4(SYS_RT_SIGTIMEDWAIT, (uint64_t)&signal_mask, 0, 0, 8) == SIGUSR2,
                      "consume blocked SIGUSR2 after restoration");

    failures += check(epoll_pwait2_raw(epfd, &returned, 1, (struct timespec_raw *)1, 0, 8) == -EFAULT,
                      "epoll_pwait2 timeout pointer boundary");
    failures += check(epoll_pwait2_raw(epfd, &returned, 1, 0, &temporary_mask, 4) == -EINVAL,
                      "epoll_pwait2 sigsetsize boundary");
    failures += check(epoll_pwait2_raw(epfd, &returned, 1, 0, (uint64_t *)1, 8) == -EFAULT,
                      "epoll_pwait2 sigmask pointer boundary");
    ts.sec = 0;
    ts.nsec = 1000000000;
    failures += check(epoll_pwait2_raw(epfd, &returned, 1, &ts, 0, 8) == -EINVAL,
                      "epoll_pwait2 nanosecond boundary");
    ts.sec = (uint64_t)-1;
    ts.nsec = 0;
    failures += check(epoll_pwait2_raw(epfd, &returned, 1, &ts, 0, 8) == -EINVAL,
                      "epoll_pwait2 negative seconds boundary");
    ts.sec = 0;
    ts.nsec = 0;
    failures += check(epoll_pwait2_raw(epfd, &returned, 1, &ts, 0, 8) == 0,
                      "epoll_pwait2 zero timeout ready event");

    ts.nsec = 10000000;
    handled_signal = 0;
    failures += check(syscall2(SYS_TKILL, (uint64_t)pid, SIGUSR2) == 0,
                      "queue SIGUSR2");
    failures += check(syscall2(SYS_TKILL, (uint64_t)pid, SIGUSR1) == 0,
                      "queue SIGUSR1 for epoll_pwait2");
    failures += check(epoll_pwait2_raw(epfd, &returned, 1, &ts, &temporary_mask, 8) == -EINTR &&
                      handled_signal == SIGUSR1, "epoll_pwait2 handled signal interrupts");
    old_mask = 0;
    failures += check(syscall6(SYS_SIGPROCMASK, 0, 0, (uint64_t)&old_mask, 8, 0, 0) == 0 &&
                      old_mask == signal_mask, "epoll_pwait2 restores signal mask");
    failures += check(syscall4(SYS_RT_SIGTIMEDWAIT, (uint64_t)&signal_mask, 0, 0, 8) == SIGUSR2,
                      "consume blocked SIGUSR2 after epoll_pwait2");

    if (epfd >= 0) syscall1(SYS_CLOSE, (uint64_t)epfd);
    if (pipe_fds[0] >= 0) syscall1(SYS_CLOSE, (uint64_t)pipe_fds[0]);
    if (pipe_fds[1] >= 0) syscall1(SYS_CLOSE, (uint64_t)pipe_fds[1]);

    if (!failures) print("hello89: PASS\nhello89 done\n");
    exit_raw(failures != 0);
}
