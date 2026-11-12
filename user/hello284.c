/// hello284: waitpid reports stopped and continued children (WUNTRACED, WCONTINUED). Measured on the host (build with -DHOST): a child
/// stopped by SIGSTOP is reported once as 0x137f with WUNTRACED and not at all without it; after SIGCONT it is reported once as 0xffff
/// with WCONTINUED; a blocking WUNTRACED wait returns when the child stops; the parent gets SIGCHLD on stop unless SA_NOCLDSTOP is set.
#ifdef HOST
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static void set_chld(void (*h)(int), unsigned long flags) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = h;
    sa.sa_flags = (int)flags;
    sigaction(SIGCHLD, &sa, 0);
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
static void set_chld(void (*h)(int), unsigned long flags) {
    struct ksigaction sa = { h, flags, 0, 0 };
    sigaction(SIGCHLD, &sa, 0);
}
#endif
#ifndef WNOHANG
#define WNOHANG 1
#endif
#ifndef WUNTRACED
#define WUNTRACED 2
#endif
#ifndef WCONTINUED
#define WCONTINUED 8
#endif
#ifndef SA_NOCLDSTOP
#define SA_NOCLDSTOP 1
#endif
#ifndef SIGSTOP
#define SIGSTOP 19
#endif
#ifndef SIGCONT
#define SIGCONT 18
#endif

static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello284:   ok   " : "hello284:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static volatile int chld_count;
static void on_chld(int s) { (void)s; chld_count++; }
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

/* Third field of /proc/<pid>/stat: "pid (comm) S ...". */
static char state_of(long pid) {
    char path[32], b[128];
    snprintf(path, sizeof path, "/proc/%ld/stat", pid);
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return 0;
    long n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return 0;
    b[n] = 0;
    char *p = strrchr(b, ')');
    return p && p[1] == ' ' ? p[2] : 0;
}

static void wait_state(long pid, char want) {
    for (int i = 0; i < 400 && state_of(pid) != want; i++) nap(5);
}

static long spawn_stopper(int delay_ms) {
    long c = fork();
    if (c == 0) {
        if (delay_ms) nap(delay_ms);
        kill(getpid(), SIGSTOP);
        for (int i = 0; i < 300; i++) nap(10);
        _exit(7);
    }
    return c;
}

int main(void) {
    int st = 0;
    long r;

    set_chld(on_chld, 0);
    long c = spawn_stopper(0);
    wait_state(c, 'T');
    for (int i = 0; i < 100 && chld_count == 0; i++) nap(5);
    snprintf(msg, sizeof msg, "A: the parent got SIGCHLD when the child stopped (count %d)", chld_count);
    check(chld_count == 1, msg);
    r = waitpid(c, &st, WNOHANG);
    snprintf(msg, sizeof msg, "A: without WUNTRACED a stopped child is not reported (%ld)", r);
    check(r == 0, msg);
    st = 0;
    r = waitpid(c, &st, WUNTRACED | WNOHANG);
    snprintf(msg, sizeof msg, "A: WUNTRACED reports the stop as 0x137f (%ld, 0x%x)", r, st);
    check(r == c && st == 0x137f, msg);
    r = waitpid(c, &st, WUNTRACED | WNOHANG);
    snprintf(msg, sizeof msg, "A: the stop is reported only once (%ld)", r);
    check(r == 0, msg);
    r = waitpid(c, &st, WCONTINUED | WNOHANG);
    snprintf(msg, sizeof msg, "A: WCONTINUED before SIGCONT reports nothing (%ld)", r);
    check(r == 0, msg);
    int before = chld_count;
    kill(c, SIGCONT);
    st = 0;
    r = waitpid(c, &st, WCONTINUED);
    snprintf(msg, sizeof msg, "A: blocking WCONTINUED reports the continue as 0xffff (%ld, 0x%x)", r, st);
    check(r == c && st == 0xffff, msg);
    for (int i = 0; i < 100 && chld_count == before; i++) nap(5);
    snprintf(msg, sizeof msg, "A: the parent got SIGCHLD when the child continued (%d -> %d)", before, chld_count);
    check(chld_count == before + 1, msg);
    r = waitpid(c, &st, WCONTINUED | WNOHANG);
    snprintf(msg, sizeof msg, "A: the continue is reported only once (%ld)", r);
    check(r == 0, msg);
    kill(c, 9);
    st = 0;
    r = waitpid(c, &st, WUNTRACED | WCONTINUED);
    snprintf(msg, sizeof msg, "A: the kill is then reported as an exit by signal 9 (%ld, 0x%x)", r, st);
    check(r == c && st == 9, msg);

    c = spawn_stopper(100);
    st = 0;
    r = waitpid(c, &st, WUNTRACED);
    snprintf(msg, sizeof msg, "B: a blocking WUNTRACED wait returns when the child stops (%ld, 0x%x)", r, st);
    check(r == c && st == 0x137f, msg);
    kill(c, 9);
    r = waitpid(c, &st, 0);
    check(r == c && st == 9, "B: the stopped child is reaped after SIGKILL");

    set_chld(on_chld, SA_NOCLDSTOP);
    chld_count = 0;
    c = spawn_stopper(0);
    wait_state(c, 'T');
    nap(50);
    snprintf(msg, sizeof msg, "C: with SA_NOCLDSTOP the stop sends no SIGCHLD (count %d)", chld_count);
    check(chld_count == 0, msg);
    st = 0;
    r = waitpid(c, &st, WUNTRACED | WNOHANG);
    snprintf(msg, sizeof msg, "C: the stop is still reported to WUNTRACED (%ld, 0x%x)", r, st);
    check(r == c && st == 0x137f, msg);
    kill(c, 9);
    waitpid(c, &st, 0);

    print(failures == 0 ? "hello284: PASS\n" : "hello284: FAIL\n");
    return failures;
}
