/* hello431: the sigsetsize argument of rt_sigprocmask, rt_sigpending, rt_sigsuspend and rt_sigtimedwait (Linux kernel/signal.c).
 * rt_sigprocmask, rt_sigsuspend and rt_sigtimedwait return EINVAL unless sigsetsize is sizeof(sigset_t) (8), and check it before
 * they touch any pointer. rt_sigpending only rejects sizes above 8 and copies exactly sigsetsize bytes out, so a 4-byte or 0-byte
 * request succeeds and leaves the rest of the buffer alone.
 * Measured on the host (build with -DHOST):
 *   A. rt_sigprocmask with sizes 4, 0 and 16: -22 each, also with a bad set pointer; the mask and the old-set buffer are untouched;
 *   B. rt_sigpending with SIGUSR1 pending: size 4 -> 0, writes 02 00 00 00 and leaves byte 4; size 0 -> 0, writes nothing; size 0
 *      with a NULL buffer -> 0; size 4 with NULL -> -14; size 16 -> -22; size 8 -> 0 with bit 9 set;
 *   C. rt_sigsuspend with sizes 4 and 16 and with a bad pointer and size 4: -22;
 *   D. rt_sigtimedwait with sizes 4 and 16 and with a bad set pointer and size 4: -22, the signal stays pending; size 8 takes it. */
#ifdef HOST
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sys4(long n, long a, long b, long c, long d) { long r = syscall(n, a, b, c, d); return r < 0 ? -errno : r; }
#define NR_PROCMASK 14
#define NR_PENDING 127
#define NR_SUSPEND 130
#define NR_TIMEDWAIT 128
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sys4(long n, long a, long b, long c, long d) { return syscall4(n, a, b, c, d); }
#define NR_PROCMASK 14
#define NR_PENDING 219
#define NR_SUSPEND 220
#define NR_TIMEDWAIT 221
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello431:   ok   " : "hello431:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned long mask_now(void) {
    unsigned long m = 0;
    sys4(NR_PROCMASK, 0, 0, (long)&m, 8);
    return m;
}
int main(void) {
    print("hello431: sigsetsize must be 8 (rt_sigpending accepts up to 8)\n");
    unsigned long usr1 = 1UL << 9, all = ~0UL, before = mask_now(), old;
    long ts0[2] = { 0, 0 };

    memset(&old, 0xee, sizeof old);
    long a4 = sys4(NR_PROCMASK, 0, (long)&all, (long)&old, 4), a0 = sys4(NR_PROCMASK, 0, (long)&all, (long)&old, 0);
    long a16 = sys4(NR_PROCMASK, 0, (long)&all, (long)&old, 16), abad = sys4(NR_PROCMASK, 0, 8, (long)&old, 4);
    long aq = sys4(NR_PROCMASK, 0, 0, (long)&old, 4);
    int untouched = old == 0xeeeeeeeeeeeeeeeeUL && mask_now() == before;
    snprintf(msg, sizeof msg, "A: rt_sigprocmask sizes 4 0 16: %ld %ld %ld; bad set with size 4 %ld; query with size 4 %ld; mask and old set untouched %d "
             "(-22 -22 -22; -22; -22; 1)", a4, a0, a16, abad, aq, untouched);
    check(a4 == -22 && a0 == -22 && a16 == -22 && abad == -22 && aq == -22 && untouched, msg);

    sys4(NR_PROCMASK, 0, (long)&usr1, 0, 8);
    kill(getpid(), 10);
    unsigned char buf[8];
    memset(buf, 0xee, sizeof buf);
    long b4 = sys4(NR_PENDING, (long)buf, 4, 0, 0);
    int w4 = buf[0] == 0 && buf[1] == 2 && buf[2] == 0 && buf[3] == 0 && buf[4] == 0xee;
    memset(buf, 0xee, sizeof buf);
    long b0 = sys4(NR_PENDING, (long)buf, 0, 0, 0);
    int w0 = buf[0] == 0xee && buf[1] == 0xee;
    long bn0 = sys4(NR_PENDING, 0, 0, 0, 0), bn4 = sys4(NR_PENDING, 0, 4, 0, 0), b16 = sys4(NR_PENDING, (long)buf, 16, 0, 0);
    unsigned long p8 = 0;
    long b8 = sys4(NR_PENDING, (long)&p8, 8, 0, 0);
    snprintf(msg, sizeof msg, "B: rt_sigpending size 4 %ld writes 4 bytes %d; size 0 %ld writes nothing %d; NULL size 0 %ld; NULL size 4 %ld; size 16 %ld; "
             "size 8 %ld bit 9 %d (0 1; 0 1; 0; -14; -22; 0 1)", b4, w4, b0, w0, bn0, bn4, b16, b8, (int)((p8 >> 9) & 1));
    check(b4 == 0 && w4 && b0 == 0 && w0 && bn0 == 0 && bn4 == -14 && b16 == -22 && b8 == 0 && ((p8 >> 9) & 1), msg);

    unsigned long none = 0;
    long c4 = sys4(NR_SUSPEND, (long)&none, 4, 0, 0), c16 = sys4(NR_SUSPEND, (long)&none, 16, 0, 0), cbad = sys4(NR_SUSPEND, 8, 4, 0, 0);
    snprintf(msg, sizeof msg, "C: rt_sigsuspend sizes 4 16: %ld %ld; bad pointer with size 4 %ld (-22 -22; -22)", c4, c16, cbad);
    check(c4 == -22 && c16 == -22 && cbad == -22, msg);

    long d4 = sys4(NR_TIMEDWAIT, (long)&usr1, 0, (long)ts0, 4), d16 = sys4(NR_TIMEDWAIT, (long)&usr1, 0, (long)ts0, 16);
    long dbad = sys4(NR_TIMEDWAIT, 8, 0, (long)ts0, 4);
    p8 = 0;
    sys4(NR_PENDING, (long)&p8, 8, 0, 0);
    int still = (p8 >> 9) & 1;
    long d8 = sys4(NR_TIMEDWAIT, (long)&usr1, 0, (long)ts0, 8);
    snprintf(msg, sizeof msg, "D: rt_sigtimedwait sizes 4 16: %ld %ld; bad set with size 4 %ld; SIGUSR1 still pending %d; size 8 takes it %ld "
             "(-22 -22; -22; 1; 10)", d4, d16, dbad, still, d8);
    check(d4 == -22 && d16 == -22 && dbad == -22 && still && d8 == 10, msg);

    sys4(NR_PROCMASK, 2, (long)&before, 0, 8);
    print(failures == 0 ? "hello431: PASS\n" : "hello431: FAIL\n");
    return failures == 0 ? 0 : 1;
}
