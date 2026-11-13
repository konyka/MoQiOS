/* hello296: CLOCK_BOOTTIME works for timer_create and timerfd.
 * Measured on the host (build with -DHOST): both accept clock id 7. A relative 30 ms arm fires; an absolute deadline taken from
 * clock_gettime(CLOCK_BOOTTIME) plus 30 ms fires too, and one already in the past fires at once. CLOCK_MONOTONIC_RAW (4) is
 * EOPNOTSUPP (95) for timer_create and EINVAL (22) for timerfd_create. A periodic boot-time timer counts its expiries. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long tcreate(long clk, void *sev, int *id) {
    long r = syscall(SYS_timer_create, clk, sev, id); return r < 0 ? -errno : r;
}
static long tset(int id, long flags, void *nv) {
    long r = syscall(SYS_timer_settime, id, flags, nv, 0); return r < 0 ? -errno : r;
}
static void tdel(int id) { syscall(SYS_timer_delete, id); }
static long stw(void *set, void *info, void *ts) {
    long r = syscall(SYS_rt_sigtimedwait, set, info, ts, 8); return r < 0 ? -errno : r;
}
static long mask(int how, unsigned long *set) {
    long r = syscall(SYS_rt_sigprocmask, how, set, 0, 8); return r < 0 ? -errno : r;
}
static long tfd_create(long clk) { long r = syscall(SYS_timerfd_create, clk, 0); return r < 0 ? -errno : r; }
static long tfd_set(long fd, long flags, void *nv) {
    long r = syscall(SYS_timerfd_settime, fd, flags, nv, 0); return r < 0 ? -errno : r;
}
static long now_of(long clk) { struct timespec t; clock_gettime((clockid_t)clk, &t); return t.tv_sec * 1000000000L + t.tv_nsec; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
static long tcreate(long clk, void *sev, int *id) { return syscall3(192, clk, (long)sev, (long)id); }
static long tset(int id, long flags, void *nv) { return syscall4(193, id, flags, (long)nv, 0); }
static void tdel(int id) { syscall1(196, id); }
static long stw(void *set, void *info, void *ts) { return syscall4(221, (long)set, (long)info, (long)ts, 8); }
static long mask(int how, unsigned long *set) { return syscall4(SYS_sigprocmask, how, (long)set, 0, 8); }
static long tfd_create(long clk) { return syscall2(170, clk, 0); }
static long tfd_set(long fd, long flags, void *nv) { return syscall4(171, fd, flags, (long)nv, 0); }
static long now_of(long clk) {
    long ts[2] = { 0, 0 };
    long r = syscall2(SYS_clock_gettime, clk, (long)ts);
    return r < 0 ? r : ts[0] * 1000000000L + ts[1];
}
#endif

#define BOOT 7
#define RAW 4
#define S_USR1 10
#define ABSTIME 1
#define SI_TIMER_CODE (-2)

/* it_interval then it_value, each a timespec. */
struct its { long isec, insec, vsec, vnsec; };
struct ksigev { long value; int signo, notify; char pad[48]; };
struct sinfo { int signo, err, code, pad, timerid, overrun; long value; char rest[96]; };

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello296:   ok   " : "hello296:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void fill(struct its *v, long interval_ns, long value_ns) {
    memset(v, 0, sizeof *v);
    v->isec = interval_ns / 1000000000L; v->insec = interval_ns % 1000000000L;
    v->vsec = value_ns / 1000000000L; v->vnsec = value_ns % 1000000000L;
}
static long wait_sig(struct sinfo *si, long ns) {
    unsigned long set = 1UL << (S_USR1 - 1);
    struct timespec ts = { ns / 1000000000L, ns % 1000000000L };
    memset(si, 0, sizeof *si);
    return stw(&set, si, &ts);
}

int main(void) {
    print("hello296: CLOCK_BOOTTIME timers and timerfds\n");
    unsigned long usr1 = 1UL << (S_USR1 - 1);
    mask(0, &usr1);
    struct ksigev sev; memset(&sev, 0, sizeof sev); sev.signo = S_USR1; sev.value = 0x55aaL;
    int id = -1;

    /* A: CLOCK_MONOTONIC_RAW is refused, CLOCK_BOOTTIME is accepted. */
    long r = tcreate(RAW, &sev, &id);
    snprintf(msg, sizeof msg, "A: timer_create(CLOCK_MONOTONIC_RAW) is EOPNOTSUPP (%ld)", r);
    check(r == -95, msg);
    r = tcreate(BOOT, &sev, &id);
    snprintf(msg, sizeof msg, "A: timer_create(CLOCK_BOOTTIME) succeeds (%ld)", r);
    check(r == 0, msg);
    long fd = tfd_create(RAW);
    snprintf(msg, sizeof msg, "A: timerfd_create(CLOCK_MONOTONIC_RAW) is EINVAL (%ld)", fd);
    check(fd == -22, msg);
    fd = tfd_create(BOOT);
    snprintf(msg, sizeof msg, "A: timerfd_create(CLOCK_BOOTTIME) succeeds (%ld)", fd);
    check(fd >= 0, msg);

    /* B: a relative boot-time timer fires with SI_TIMER and the value. */
    struct its its;
    fill(&its, 0, 30000000L);
    r = tset(id, 0, &its);
    check(r == 0, "B: timer_settime of 30 ms succeeds");
    struct sinfo si;
    r = wait_sig(&si, 1000000000L);
    snprintf(msg, sizeof msg, "B: it fires with SI_TIMER and the value (%ld, code %d, value 0x%lx)", r, si.code, si.value);
    check(r == S_USR1 && si.code == SI_TIMER_CODE && si.value == 0x55aaL, msg);

    /* C: an absolute deadline is counted on the boot-time clock. */
    long deadline = now_of(BOOT) + 30000000L;
    fill(&its, 0, deadline);
    r = tset(id, ABSTIME, &its);
    check(r == 0, "C: an absolute deadline 30 ms ahead is accepted");
    r = wait_sig(&si, 1000000000L);
    snprintf(msg, sizeof msg, "C: and it fires (%ld)", r);
    check(r == S_USR1, msg);
    deadline = now_of(BOOT) - 1000000000L;
    fill(&its, 0, deadline > 0 ? deadline : 1);
    r = tset(id, ABSTIME, &its);
    check(r == 0, "C: a deadline already past is accepted");
    r = wait_sig(&si, 1000000000L);
    snprintf(msg, sizeof msg, "C: and fires at once (%ld)", r);
    check(r == S_USR1, msg);

    /* D: the timerfd counts a periodic boot-time timer's expiries. */
    fill(&its, 20000000L, 20000000L);
    r = tfd_set(fd, 0, &its);
    check(r == 0, "D: a 20 ms periodic timerfd arms");
    struct timespec w = { 0, 210000000L };
#ifdef HOST
    nanosleep(&w, 0);
#else
    syscall2(SYS_nanosleep, (long)&w, 0);
#endif
    unsigned long long n = 0;
    long got = read((int)fd, &n, sizeof n);
    snprintf(msg, sizeof msg, "D: it has counted about 10 expiries (%ld, %llu)", got, n);
    check(got == (long)sizeof n && n >= 8 && n <= 14, msg);

    tdel(id);
    close((int)fd);
    mask(1, &usr1);
    print(failures ? "hello296: FAIL\n" : "hello296: PASS\n");
    return failures ? 1 : 0;
}
