// hello66 - RLIMIT_FSIZE execution semantics acceptance test.
// Covers byte-boundary writes, SIGXFSZ, pwrite offset handling, fork
// inheritance, and the fact that streams such as pipes are not file-sized.
#include "../lib/moqi_libc/include/resource.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
static volatile int xfsz_hits;
#define CHECK(cond, name) do { if (!(cond)) { print("hello66: FAIL " name "\n"); failures++; } } while (0)

#define O_RDWR_CREAT_TRUNC 0x242
#define SYS_WRITEV 20
#define SYS_PWRITEV 141
#define SYS_FTRUNCATE 77

struct iovec {
    void *iov_base;
    unsigned long iov_len;
};

static void on_xfsz(int signum) {
    if (signum == SIGXFSZ) xfsz_hits++;
}

static void wait_for_xfsz(void) {
    struct timespec pause = { 0, 5 * 1000 * 1000 };
    for (int i = 0; i < 40 && xfsz_hits == 0; i++) nanosleep(&pause, 0);
}

static long pwrite_raw(long fd, const void *buf, long count, long offset) {
    return syscall6(18, fd, (long)buf, count, offset, 0, 0);
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    print("hello66: start\n");

    struct ksigaction action = { on_xfsz, 0, 0, 0 };
    CHECK(sigaction(SIGXFSZ, &action, 0) == 0, "install SIGXFSZ handler");

    struct rlimit initial;
    CHECK(getrlimit(RLIMIT_FSIZE, &initial) == 0, "getrlimit FSIZE");
    CHECK(initial.rlim_cur == RLIM_INFINITY && initial.rlim_max == RLIM_INFINITY,
          "default FSIZE infinity");

    struct rlimit limit = { 8, RLIM_INFINITY };
    CHECK(setrlimit(RLIMIT_FSIZE, &limit) == 0, "set 8-byte FSIZE");
    struct rlimit readback;
    CHECK(getrlimit(RLIMIT_FSIZE, &readback) == 0 && readback.rlim_cur == 8,
          "readback FSIZE");

    long fd = open("/tmp/hello66-fsize", O_RDWR_CREAT_TRUNC, 0666);
    CHECK(fd >= 0, "open tmpfs file");
    if (fd >= 0) {
        char data[16] = "0123456789abcdef";
        CHECK(write((int)fd, data, 8) == 8, "write exactly to limit");
        CHECK(write((int)fd, data, 4) == -27, "write at limit returns EFBIG");
        wait_for_xfsz();
        CHECK(xfsz_hits > 0, "SIGXFSZ delivered on write overflow");

        xfsz_hits = 0;
        CHECK(pwrite_raw(fd, data, 8, 4) == 4, "pwrite truncates at limit");
        wait_for_xfsz();
        CHECK(xfsz_hits > 0, "SIGXFSZ delivered on pwrite overflow");
        CHECK(write((int)fd, data, 1) == -27, "pwrite leaves shared offset unchanged");
        struct iovec vec = { data, 8 };
        CHECK(syscall3(SYS_WRITEV, fd, (long)&vec, 1) == -27, "writev at limit returns EFBIG");
        wait_for_xfsz();
        xfsz_hits = 0;
        CHECK(syscall4(SYS_PWRITEV, fd, (long)&vec, 1, 4) == 4, "pwritev truncates at limit");
        wait_for_xfsz();
        CHECK(xfsz_hits > 0, "SIGXFSZ delivered on pwritev overflow");
        CHECK(syscall2(SYS_FTRUNCATE, fd, 9) == -27, "ftruncate beyond limit EFBIG");
        close((int)fd);
    }

    int pipe_fds[2] = { -1, -1 };
    CHECK(pipe(pipe_fds) == 0, "create pipe under FSIZE limit");
    if (pipe_fds[1] >= 0) {
        char stream[16] = "pipe-is-not-file";
        CHECK(write(pipe_fds[1], stream, 15) == 15, "pipe write ignores FSIZE");
        close(pipe_fds[0]);
        close(pipe_fds[1]);
    }

    long child = fork();
    CHECK(child >= 0, "fork FSIZE child");
    if (child == 0) {
        struct rlimit child_limit;
        _exit(getrlimit(RLIMIT_FSIZE, &child_limit) == 0 && child_limit.rlim_cur == 8 ? 0 : 3);
    }
    if (child > 0) {
        int status = 0;
        CHECK(waitpid(child, &status, 0) == child && status == 0, "child inherits FSIZE");
    }

    struct rlimit unlimited = { RLIM_INFINITY, RLIM_INFINITY };
    CHECK(setrlimit(RLIMIT_FSIZE, &unlimited) == 0, "restore FSIZE infinity");

    if (failures == 0) {
        print("hello66: PASS\nhello66 done\n");
        _exit(0);
    }
    print("hello66: FAIL\nhello66 done\n");
    _exit(1);
}
