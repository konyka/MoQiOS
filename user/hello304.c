/* hello304: killing a process that is blocked writing into a full pipe releases its write end.
 * Measured on the host (build with -DHOST): A a child blocked in write() on a full pipe is killed with SIGKILL; the parent drains the
 * pipe and then read() returns 0 (end of file, the child's write end is gone) instead of waiting for more data. B the same with the
 * child blocked in splice() from a file into the full pipe (Linux blocks there rather than returning 0). C after ten such children the
 * pipe slots are still available: 32 fresh pipes can be created. D a blocked child that gets SIGTERM (default action) behaves the
 * same. E sendfile() from a file into the full pipe blocks and is killed the same way. F splice() with SIGTERM. G a waiting
 * file-to-pipe splice completes with all 16 bytes once the reader drains the pipe. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long spl(long in, long out, long len) {
    long r = syscall(SYS_splice, in, 0L, out, 0L, len, 0);
    return r < 0 ? -errno : r;
}
static long sfile(long out, long in, long n) {
    long r = syscall(SYS_sendfile, out, in, 0L, n);
    return r < 0 ? -errno : r;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long spl(long in, long out, long len) { return syscall6(145, in, 0, out, 0, len, 0); }
static long sfile(long out, long in, long n) { return syscall4(144, out, in, 0, n); }
#endif

#define S_KILL 9
#define S_TERM 15
#define SLEEP_MS 40

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello304:   ok   " : "hello304:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* Fill the pipe until a non-blocking write cannot take a single byte more, leaving it full. */
static void fill(int fd) {
    char b[512];
    memset(b, 'f', sizeof b);
    int fl = (int)fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    while (write(fd, b, sizeof b) > 0) {}
    while (write(fd, b, 1) > 0) {}
    fcntl(fd, F_SETFL, fl);
}
/* Drain what is in the pipe; 1 when the read end reports end of file, 0 when it only ran out of data, -1 on error. */
static int drain_eof(int fd, long *bytes) {
    char b[512];
    long total = 0;
    int fl = (int)fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    for (int i = 0; i < 400; i++) {
        long r = read(fd, b, sizeof b);
        if (r > 0) {
            total += r;
            continue;
        }
        if (r == 0) {
            fcntl(fd, F_SETFL, fl);
            if (bytes) *bytes = total;
            return 1;
        }
        nap(5);
    }
    fcntl(fd, F_SETFL, fl);
    if (bytes) *bytes = total;
    return 0;
}

/* A child blocks writing into `wfd` (a full pipe) and is killed; the parent's read end must then reach end of file. */
/* via: 0 write(), 1 splice() from a file, 2 sendfile() from a file. */
static void one(const char *name, int via, int sig) {
    int p[2];
    if (pipe(p) != 0) {
        check(0, "pipe failed");
        return;
    }
    fill(p[1]);
    int f = -1;
    if (via != 0) {
        f = (int)open("/tmp/h304", O_RDWR | O_CREAT | O_TRUNC, 0644);
        write(f, "0123456789abcdef", 16);
        lseek(f, 0, 0);
    }
    long c = fork();
    if (c == 0) {
        /* The child's own descriptor of the same pipe: the parent's fill already took every free slot. */
        long r = via == 1 ? spl(f, p[1], 16) : via == 2 ? sfile(p[1], f, 16) : write(p[1], "0123456789abcdef", 16);
        _exit(r > 0 ? 0 : 1);
    }
    nap(SLEEP_MS); /* the child is inside the write */
    int st = 0;
    /* It must still be there, blocked: a write that went through would make the check below meaningless. */
    long early = waitpid(c, &st, 1 /* WNOHANG */);
    kill(c, sig);
    waitpid(c, &st, 0);
    close(p[1]);
    if (via != 0) close(f);
    long got = 0;
    int eof = drain_eof(p[0], &got);
    snprintf(what, sizeof what, "%s: the writer was blocked (%s), and after it is killed the pipe reaches end of file (%d, drained %ld bytes)", name,
             early == 0 ? "yes" : "no", eof, got);
    check(early == 0 && eof == 1, what);
    close(p[0]);
}

int main(void) {
    print("hello304: a killed pipe writer releases its end\n");
    unlink("/tmp/h304");
    one("A write()", 0, S_KILL);
    one("B splice() from a file", 1, S_KILL);
    one("D write() and SIGTERM", 0, S_TERM);
    one("E sendfile() from a file", 2, S_KILL);
    one("F splice() from a file and SIGTERM", 1, S_TERM);
    /* G: once the reader makes room, a waiting file-to-pipe splice completes with all its bytes. */
    {
        int p[2];
        pipe(p);
        fill(p[1]);
        int f = (int)open("/tmp/h304", O_RDWR | O_CREAT | O_TRUNC, 0644);
        write(f, "0123456789abcdef", 16);
        lseek(f, 0, 0);
        long c = fork();
        if (c == 0) _exit(spl(f, p[1], 16) == 16 ? 0 : 1);
        nap(SLEEP_MS);
        int st = 0;
        long early = waitpid(c, &st, 1 /* WNOHANG */);
        char b[512];
        int fl = (int)fcntl(p[0], F_GETFL, 0);
        fcntl(p[0], F_SETFL, fl | O_NONBLOCK);
        while (read(p[0], b, sizeof b) > 0) {}
        fcntl(p[0], F_SETFL, fl);
        /* The child must finish on its own within 2 s of the drain; a lost wake-up leaves it waiting. */
        long wr = early == c ? c : 0;
        if (early != c) st = -1;
        for (int i = 0; i < 400 && wr == 0; i++) {
            wr = waitpid(c, &st, 1);
            if (wr == 0) nap(5);
        }
        if (wr != c) {
            kill(c, S_KILL);
            waitpid(c, 0, 0);
        }
        snprintf(what, sizeof what, "G: a file-to-pipe splice into a full pipe waits (%s) and completes with 16 bytes once the reader drains it (%s, status 0x%x)",
                 early == 0 ? "yes" : "no", early == c ? "it had already returned" : wr == c ? "finished" : "still waiting after 2 s", st);
        check(early == 0 && wr == c && st == 0, what);
        close(f);
        close(p[0]);
        close(p[1]);
    }
    /* C: repeated kills must not tie up the pipe slots. */
    int made = 0, pp[2];
    for (int i = 0; i < 10; i++) {
        int q[2];
        if (pipe(q) != 0) break;
        fill(q[1]);
        long c = fork();
        if (c == 0) {
            write(q[1], "x", 1);
            _exit(0);
        }
        nap(20);
        kill(c, S_KILL);
        waitpid(c, 0, 0);
        close(q[1]);
        close(q[0]);
    }
    for (int i = 0; i < 32; i++) {
        if (pipe(pp) != 0) break;
        made++;
        close(pp[0]);
        close(pp[1]);
    }
    snprintf(what, sizeof what, "C: after ten killed blocked writers 32 fresh pipes can be made (%d)", made);
    check(made == 32, what);
    unlink("/tmp/h304");
    print(failures == 0 ? "hello304: PASS\n" : "hello304: FAIL\n");
    return failures;
}
