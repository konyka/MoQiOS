// hello91 - raw fd lifecycle acceptance for pipe, dup, dup2, fork, and waitpid.
#include <stdint.h>

static inline int64_t syscall0(uint64_t n) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n) : "rcx", "r11", "memory");
    return r;
}

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
    __asm__ volatile ("syscall" : "=a"(r)
                      : "a"(n), "D"(a), "S"(b), "r"(x)
                      : "rcx", "r11", "memory");
    return r;
}

#define SYS_READ 10
#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_CLOSE 11
#define SYS_PIPE 22
#define SYS_DUP 32
#define SYS_DUP2 33
#define SYS_FORK 57
#define SYS_WAITPID 6
#define SYS_FCNTL 72

#define F_DUPFD 0
#define F_GETFD 1

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (uint64_t)status);
    for (;;) {}
}

static void close_if_open(int64_t fd) {
    if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
}

static int64_t active_fds[6] = {-1, -1, -1, -1, -1, -1};

static void fail(const char *case_name) {
    uint64_t i;
    print("hello91: FAIL ");
    print(case_name);
    print("\n");
    for (i = 0; i < 6; i++) close_if_open(active_fds[i]);
    exit_raw(1);
}

void _start(void) {
    static const char token[] = "hello91-token";
    char received[sizeof(token) - 1];
    int32_t pipe_fds[2] = {-1, -1};
    int64_t read_dup = -1;
    int64_t write_dup = -1;
    int64_t min_dup = -1;
    int64_t reused_dup = -1;
    int64_t child = -1;
    int32_t status = -1;

    print("hello91: start\n");

    if (syscall1(SYS_PIPE, (uint64_t)pipe_fds) != 0)
        fail("create pipe");
    active_fds[0] = pipe_fds[0];
    active_fds[1] = pipe_fds[1];

    read_dup = syscall1(SYS_DUP, (uint64_t)pipe_fds[0]);
    if (read_dup < 0)
        fail("dup read end");
    active_fds[2] = read_dup;

    write_dup = syscall2(SYS_DUP2, (uint64_t)pipe_fds[1], 8);
    if (write_dup != 8)
        fail("dup2 write end");
    active_fds[3] = write_dup;

    if (syscall3(SYS_FCNTL, (uint64_t)read_dup, F_GETFD, 0) < 0 ||
        syscall3(SYS_FCNTL, (uint64_t)write_dup, F_GETFD, 0) < 0)
        fail("validate duplicated fds");

    min_dup = syscall3(SYS_FCNTL, (uint64_t)read_dup, F_DUPFD, 10);
    if (min_dup < 10 || syscall3(SYS_FCNTL, (uint64_t)min_dup, F_GETFD, 0) < 0)
        fail("fcntl F_DUPFD minimum");
    active_fds[4] = min_dup;

    if (syscall1(SYS_CLOSE, (uint64_t)min_dup) < 0)
        fail("close fd for reuse");
    active_fds[4] = -1;
    if (syscall3(SYS_FCNTL, (uint64_t)min_dup, F_GETFD, 0) >= 0)
        fail("closed fd still valid");
    min_dup = -1;
    reused_dup = syscall2(SYS_DUP2, (uint64_t)read_dup, 10);
    if (reused_dup != 10 || syscall3(SYS_FCNTL, (uint64_t)reused_dup, F_GETFD, 0) < 0)
        fail("reuse closed fd slot");
    active_fds[4] = reused_dup;

    if (syscall1(SYS_CLOSE, (uint64_t)pipe_fds[1]) < 0)
        fail("close original write end");
    pipe_fds[1] = -1;
    active_fds[1] = -1;

    child = syscall0(SYS_FORK);
    if (child < 0)
        fail("fork with duplicated ends");
    if (child == 0) {
        int64_t written = syscall3(SYS_WRITE, (uint64_t)write_dup,
                                    (uint64_t)token, sizeof(token) - 1);
        close_if_open(write_dup);
        exit_raw(written == (int64_t)(sizeof(token) - 1) ? 0 : 1);
    }

    if (syscall1(SYS_CLOSE, (uint64_t)write_dup) < 0)
        fail("close parent write duplicate");
    write_dup = -1;
    active_fds[3] = -1;

    if (syscall3(SYS_READ, (uint64_t)read_dup, (uint64_t)received,
                 sizeof(received)) != (int64_t)(sizeof(received)) ||
        received[0] != token[0])
        fail("read inherited child token");
    {
        uint64_t i;
        for (i = 0; i < sizeof(received); i++) {
            if (received[i] != token[i])
                fail("compare inherited child token");
        }
    }

    if (syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&status, 0) != child || status != 0)
        fail("waitpid child success");

    for (uint64_t i = 0; i < 6; i++) close_if_open(active_fds[i]);

    print("hello91: PASS\n");
    print("hello91 done\n");
    exit_raw(0);
}
