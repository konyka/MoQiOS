/* hello440: rt_sigaction requires sigsetsize == sizeof(sigset_t) (8) before it looks at anything else (Linux kernel/signal.c
 * rt_sigaction: EINVAL first, then the act copy, then do_sigaction). The kernel used to ignore the fourth argument (it was not even
 * passed from the dispatcher), so every size was accepted.
 * Measured on the host (build with -DHOST):
 *   A. rt_sigaction(SIGUSR1, act, 0, 4), (.., 0) and (.., 16): -22 each, and the action stays SIG_DFL;
 *   B. a bad act pointer with sigsetsize 4: -22 (the size is checked before the pointer); with 8: -14;
 *   C. a query (act NULL) with sigsetsize 4: -22; with 8: 0;
 *   D. installing SIG_IGN with sigsetsize 8: 0, and a query reads it back as 1. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sys4(long n, long a, long b, long c, long d) { long r = syscall(n, a, b, c, d); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sys4(long n, long a, long b, long c, long d) { return syscall4(n, a, b, c, d); }
#endif
#define NR_SIGACTION 13
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello440:   ok   " : "hello440:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned long handler_of(int sig) {
    unsigned long o[4] = { 99, 99, 99, 99 };
    sys4(NR_SIGACTION, sig, 0, (long)o, 8);
    return o[0];
}
int main(void) {
    print("hello440: rt_sigaction requires sigsetsize 8\n");
    unsigned long ign[4] = { 1, 0, 0, 0 };
    long a4 = sys4(NR_SIGACTION, 10, (long)ign, 0, 4), a0 = sys4(NR_SIGACTION, 10, (long)ign, 0, 0), a16 = sys4(NR_SIGACTION, 10, (long)ign, 0, 16);
    unsigned long h = handler_of(10);
    snprintf(msg, sizeof msg, "A: sizes 4 0 16: %ld %ld %ld; SIGUSR1 handler still %lu (-22 -22 -22; 0)", a4, a0, a16, h);
    check(a4 == -22 && a0 == -22 && a16 == -22 && h == 0, msg);

    long b4 = sys4(NR_SIGACTION, 10, 8, 0, 4), b8 = sys4(NR_SIGACTION, 10, 8, 0, 8);
    snprintf(msg, sizeof msg, "B: bad act with size 4 %ld, with size 8 %ld (-22 -14)", b4, b8);
    check(b4 == -22 && b8 == -14, msg);

    unsigned long o[4];
    long c4 = sys4(NR_SIGACTION, 10, 0, (long)o, 4), c8 = sys4(NR_SIGACTION, 10, 0, (long)o, 8);
    snprintf(msg, sizeof msg, "C: query with size 4 %ld, with size 8 %ld (-22 0)", c4, c8);
    check(c4 == -22 && c8 == 0, msg);

    long d = sys4(NR_SIGACTION, 10, (long)ign, 0, 8);
    unsigned long hd = handler_of(10);
    unsigned long dfl[4] = { 0, 0, 0, 0 };
    sys4(NR_SIGACTION, 10, (long)dfl, 0, 8);
    snprintf(msg, sizeof msg, "D: SIG_IGN with size 8 %ld, reads back %lu (0 1)", d, hd);
    check(d == 0 && hd == 1, msg);
    print(failures == 0 ? "hello440: PASS\n" : "hello440: FAIL\n");
    return failures == 0 ? 0 : 1;
}
