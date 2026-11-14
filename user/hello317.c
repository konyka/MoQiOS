/* hello317: adjtimex (native 502) and clock_adjtime (native 503) with CLOCK_REALTIME: the kernel's NTP variables, the TAI offset
 * (CLOCK_TAI = REALTIME + tai) and ADJ_SETOFFSET (Linux kernel/time/ntp.c ntp_adjtimex, timekeeping.c timekeeping_validate_timex,
 * posix-timers.c do_clock_adjtime). struct timex is 208 bytes: modes 0, offset 8, freq 16, maxerror 24, esterror 32, status 40,
 * constant 48, precision 56, tolerance 64, time 72/80, tick 88, tai 160.
 * Measured on the host as an unprivileged user (build with -DHOST; the privileged steps B, C, D and H need CAP_SYS_TIME and are
 * skipped there, they follow the Linux source):
 *   A. a read-only call returns the clock state (0 synchronised, 5 TIME_ERROR while STA_UNSYNC), tick 10000, precision 1,
 *      tolerance 32768000, constant 2 on a fresh kernel (the host's ntpd may have changed it);
 *   E. unprivileged: ADJ_TAI, ADJ_NANO, ADJ_OFFSET, ADJ_TICK (also with an out-of-range tick: EPERM comes first) are EPERM;
 *      ADJ_OFFSET_SS_READ (0xa001) is allowed (it returns the clock state like a read) and reports offset 0; ADJ_ADJTIME without ADJ_OFFSET_SINGLESHOT (0x8000) is
 *      EINVAL; ADJ_OFFSET_SINGLESHOT (0x8001) is EPERM; a read-only call still works;
 *   F. clock_adjtime: CLOCK_REALTIME 0; clocks 1..9 and 11 EOPNOTSUPP; 10, 12..15, 24, 99 EINVAL; 16..23 ENODEV; negative ids
 *      EOPNOTSUPP except those whose low three bits are 3 (CLOCKFD, -5 -13 -21: EINVAL); the struct is copied in first, so a
 *      NULL pointer is EFAULT for every clock id;
 *   G. adjtimex(NULL) is EFAULT.
 * Privileged (Linux source): B. ADJ_TAI 37 sets the offset, TAI - REALTIME is then 37 s; C. clock_nanosleep(CLOCK_TAI,
 * TIMER_ABSTIME) to TAI + 20 ms wakes after about 20 ms; D. a TAI offset below 0 or above 100000 is ignored; H. ADJ_SETOFFSET
 * steps REALTIME forward and back. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long adj(long *tx) { long r = syscall(SYS_adjtimex, tx); return r < 0 ? -errno : r; }
static long cadj(long clk, long *tx) { long r = syscall(SYS_clock_adjtime, clk, tx); return r < 0 ? -errno : r; }
static long gettime(long clk, long *ts) { long r = syscall(SYS_clock_gettime, clk, ts); return r < 0 ? -errno : r; }
static long csleep(long clk, long flags, long *ts) { long r = syscall(SYS_clock_nanosleep, clk, flags, ts, 0); return r < 0 ? -errno : r; }
static void drop_privilege(void) {}
#define PRIVILEGED 0
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long adj(long *tx) { return syscall1(SYS_adjtimex, (long)tx); }
static long cadj(long clk, long *tx) { return syscall2(SYS_clock_adjtime, clk, (long)tx); }
static long gettime(long clk, long *ts) { return syscall2(SYS_clock_gettime, clk, (long)ts); }
static long csleep(long clk, long flags, long *ts) { return syscall4(SYS_clock_nanosleep, clk, flags, (long)ts, 0); }
static void drop_privilege(void) { syscall1(174 /* native setuid */, 1000); }
#define PRIVILEGED 1
#endif

#define REALTIME 0
#define MONOTONIC 1
#define TAI 11
#define ABSTIME 1
#define A_TAI 0x80
#define A_SETOFFSET 0x100
#define A_NANO 0x2000
#define A_TICK 0x4000

static int failures;
static char msg[240];
static void check(int ok, const char *w) {
    print(ok ? "hello317:   ok   " : "hello317:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* struct timex as 26 longs; the int fields (modes, status, tai) are the low halves of their slots on little-endian x86_64. */
static long tx[26];
static void clear(void) { memset(tx, 0, sizeof tx); }
static int modes_of(void) { return ((int *)tx)[0]; }
static void set_modes(int m) { ((int *)tx)[0] = m; }
static int status_of(void) { return ((int *)&tx[5])[0]; }
static int tai_of(void) { return ((int *)&tx[20])[0]; }
static long ns_of(long *ts) { return ts[0] * 1000000000L + ts[1]; }
static long now_ns(long clk) { long ts[2] = { 0, 0 }; gettime(clk, ts); return ns_of(ts); }
static long with_modes(int m, long tick) { clear(); set_modes(m); tx[11] = tick; return adj(tx); }
static long read_tai(void) { clear(); adj(tx); return tai_of(); }
static long set_tai(long v) { clear(); set_modes(A_TAI); tx[6] = v; return adj(tx); }

/* The unprivileged checks (E); returns the number of failures. */
static int unprivileged(void) {
    int before = failures;
    long e0 = with_modes(A_TAI, 0), e1 = with_modes(A_NANO, 0), e2 = with_modes(0x1, 0), e3 = with_modes(A_TICK, 10000);
    long e4 = with_modes(A_TICK, 8999);
    long e5 = with_modes(0xa001, 0), e5off = tx[1];
    long e6 = with_modes(0x8000, 0), e7 = with_modes(0x8001, 0), e8 = with_modes(0, 0);
    snprintf(msg, sizeof msg, "E: unprivileged changes are EPERM, reads work (%ld %ld %ld %ld %ld; ss-read %ld off %ld; %ld %ld; read %ld)", e0, e1, e2,
             e3, e4, e5, e5off, e6, e7, e8);
    check(e0 == -1 && e1 == -1 && e2 == -1 && e3 == -1 && e4 == -1 && (e5 == 0 || e5 == 5) && e5off == 0 && e6 == -22 && e7 == -1 && (e8 == 0 || e8 == 5), msg);
    return failures - before;
}
int main(void) {
    print("hello317: adjtimex / clock_adjtime\n");
    clear();
    long a0 = adj(tx);
    snprintf(msg, sizeof msg, "A: a read-only call reports the clock state (%ld status 0x%x tick %ld precision %ld tolerance %ld constant %ld modes %d)", a0,
             status_of(), tx[11], tx[7], tx[8], tx[6], modes_of());
    int a_state = PRIVILEGED ? (a0 == 5 && status_of() == 0x40 && tai_of() == 0) : (a0 == 0 || a0 == 5);
    check(a_state && tx[11] == 10000 && tx[7] == 1 && tx[8] == 32768000 && tx[6] == 2 && modes_of() == 0, msg);

    if (PRIVILEGED) {
        long b0 = set_tai(37), b1 = read_tai();
        long rt[2] = { 0, 0 }, ta[2] = { 0, 0 };
        gettime(REALTIME, rt);
        gettime(TAI, ta);
        long diff = ns_of(ta) - ns_of(rt) - 37000000000L;
        snprintf(msg, sizeof msg, "B: ADJ_TAI 37 sets the TAI offset (%ld, read %ld, TAI - REALTIME - 37 s = %ld us)", b0, b1, diff / 1000);
        check(b0 == 5 && b1 == 37 && diff >= 0 && diff < 50000000L, msg);

        long dl = now_ns(TAI) + 20000000L;
        long ts[2] = { dl / 1000000000L, dl % 1000000000L };
        long t0 = now_ns(MONOTONIC);
        long c0 = csleep(TAI, ABSTIME, ts);
        long slept = (now_ns(MONOTONIC) - t0) / 1000000;
        snprintf(msg, sizeof msg, "C: clock_nanosleep(CLOCK_TAI, TIMER_ABSTIME) to TAI + 20 ms (%ld, slept %ld ms)", c0, slept);
        check(c0 == 0 && slept >= 15 && slept < 1000, msg);

        long d0 = set_tai(-1), d1 = read_tai(), d2 = set_tai(100001), d3 = read_tai();
        snprintf(msg, sizeof msg, "D: a TAI offset outside 0..100000 is ignored (%ld -> %ld, %ld -> %ld)", d0, d1, d2, d3);
        check(d0 == 5 && d1 == 37 && d2 == 5 && d3 == 37, msg);

        long m0 = now_ns(MONOTONIC), r0 = now_ns(REALTIME);
        clear();
        set_modes(A_SETOFFSET);
        tx[9] = 2;
        long h0 = adj(tx);
        long jump = (now_ns(REALTIME) - r0) - (now_ns(MONOTONIC) - m0);
        clear();
        set_modes(A_SETOFFSET);
        tx[9] = -2;
        long h1 = adj(tx);
        long back = (now_ns(REALTIME) - r0) - (now_ns(MONOTONIC) - m0);
        clear();
        set_modes(A_SETOFFSET);
        tx[10] = 1000000;
        long h2 = adj(tx);
        snprintf(msg, sizeof msg, "H: ADJ_SETOFFSET steps REALTIME (%ld jump %ld ms, %ld back %ld ms; usec 1000000 %ld)", h0, jump / 1000000, h1,
                 back / 1000000, h2);
        check(h0 == 5 && jump > 1950000000L && jump < 2050000000L && h1 == 5 && back > -50000000L && back < 50000000L && h2 == -22, msg);

        long pid = fork();
        if (pid == 0) {
            drop_privilege();
            _exit(unprivileged());
        }
        int st = -1;
        waitpid(pid, &st, 0);
        check(((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0, "E: the unprivileged child's checks all passed");
    } else {
        unprivileged();
    }

    long f[16];
    clear();
    f[0] = cadj(REALTIME, tx);
    clear(); f[1] = cadj(1, tx);
    clear(); f[2] = cadj(7, tx);
    clear(); f[3] = cadj(TAI, tx);
    clear(); f[4] = cadj(99, tx);
    clear(); f[5] = cadj(10, tx);
    clear(); f[6] = cadj(16, tx);
    clear(); f[7] = cadj(-5, tx);
    clear(); f[8] = cadj(-1, tx);
    f[9] = cadj(REALTIME, 0);
    f[10] = cadj(99, 0);
    snprintf(msg, sizeof msg, "F: clock_adjtime per clock id (%ld; %ld %ld %ld; %ld %ld; %ld; %ld %ld; NULL %ld %ld)", f[0], f[1], f[2], f[3], f[4], f[5],
             f[6], f[7], f[8], f[9], f[10]);
    check((f[0] == 0 || f[0] == 5) && f[1] == -95 && f[2] == -95 && f[3] == -95 && f[4] == -22 && f[5] == -22 && f[6] == -19 && f[7] == -22 &&
              f[8] == -95 && f[9] == -14 && f[10] == -14,
          msg);

    long g0 = adj(0);
    snprintf(msg, sizeof msg, "G: adjtimex(NULL) is EFAULT (%ld)", g0);
    check(g0 == -14, msg);

    if (PRIVILEGED) set_tai(0);
    print(failures == 0 ? "hello317: PASS\n" : "hello317: FAIL\n");
    return failures;
}
