/* hello292: a POSIX timer's signal carries SI_TIMER, the timer id, the overrun count and the sigev_value.
 * Measured on the host (build with -DHOST): a one-shot timer's SIGUSR1 has si_code SI_TIMER (-2), si_timerid equal to the id
 * timer_create returned, si_overrun 0 and si_value the sigev_value it was created with, and timer_getoverrun is 0. A 20 ms
 * periodic timer whose signal stays blocked for 210 ms queues one signal, not ten; its si_overrun counts the other expiries (9)
 * and timer_getoverrun reports the same number. With a NULL sigevent the timer sends SIGALRM whose si_value is the timer id. */
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
static long sc_ret(long r) { return r < 0 ? -errno : r; }
static long t_create(long clk, void *sev, int *id) {
    long raw = 0;
    long r = sc_ret(syscall(SYS_timer_create, clk, sev, &raw));
    *id = (int)raw;
    return r;
}
static long t_settime(int id, void *its) { return sc_ret(syscall(SYS_timer_settime, (long)id, 0, its, 0)); }
static long t_overrun(int id) { return sc_ret(syscall(SYS_timer_getoverrun, (long)id)); }
static void t_delete(int id) { syscall(SYS_timer_delete, (long)id); }
static long stw(void *set, void *info, void *ts) { return sc_ret(syscall(SYS_rt_sigtimedwait, set, info, ts, 8)); }
static long mask(int how, unsigned long *set) { return sc_ret(syscall(SYS_rt_sigprocmask, how, set, 0, 8)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/signal.h"
static long t_create(long clk, void *sev, int *id) { return syscall3(192, clk, (long)sev, (long)id); }
static long t_settime(int id, void *its) { return syscall4(193, id, 0, (long)its, 0); }
static long t_overrun(int id) { return syscall1(195, id); }
static void t_delete(int id) { syscall1(196, id); }
static long stw(void *set, void *info, void *ts) { return syscall4(221, (long)set, (long)info, (long)ts, 8); }
static long mask(int how, unsigned long *set) { return syscall4(SYS_sigprocmask, how, (long)set, 0, 8); }
#endif

#define S_USR1 10
#define S_ALRM 14
#define BLOCK 0
#define UNBLOCK 1
#define SI_TIMER_CODE (-2)

/* x86_64 sigevent: sigev_value@0, sigev_signo@8, sigev_notify@12 (SIGEV_SIGNAL is 0), padded to 64 bytes. */
struct ksigev { long value; int signo, notify; char pad[48]; };
struct its { long isec, insec, vsec, vnsec; };
/* siginfo_t: signo@0 errno@4 code@8, 4 bytes of padding, then si_timerid@16 si_overrun@20 si_value@24. */
struct sinfo { int signo, err, code, pad; int timerid, overrun; long value; char rest[96]; };

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello292:   ok   " : "hello292:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long wait_for(int sig, struct sinfo *si, long ns) {
    unsigned long set = 1UL << (sig - 1);
    struct timespec ts = { ns / 1000000000L, ns % 1000000000L };
    memset(si, 0, sizeof *si);
    return stw(&set, si, &ts);
}

int main(void) {
    print("hello292: POSIX timer signals carry SI_TIMER, the timer id, the overrun and the value\n");
    unsigned long both = (1UL << (S_USR1 - 1)) | (1UL << (S_ALRM - 1));
    mask(BLOCK, &both);

    /* A: one-shot timer. */
    struct ksigev sev;
    memset(&sev, 0, sizeof sev);
    sev.signo = S_USR1;
    sev.value = 0x1234abcdL;
    int id = -1;
    long r = t_create(1 /* CLOCK_MONOTONIC */, &sev, &id);
    check(r == 0 && id >= 0, "timer_create(CLOCK_MONOTONIC, SIGEV_SIGNAL SIGUSR1) succeeds");
    struct its one = { 0, 0, 0, 20000000L };
    t_settime(id, &one);
    struct sinfo si;
    r = wait_for(S_USR1, &si, 1000000000L);
    snprintf(msg, sizeof msg, "A: a one-shot timer's signal has SI_TIMER, the timer id, overrun 0 and the sigev_value (%ld, code %d, id %d/%d, overrun %d, value 0x%lx)",
             r, si.code, si.timerid, id, si.overrun, si.value);
    check(r == S_USR1 && si.code == SI_TIMER_CODE && si.timerid == id && si.overrun == 0 && si.value == 0x1234abcdL, msg);
    r = t_overrun(id);
    snprintf(msg, sizeof msg, "A: and timer_getoverrun is 0 (%ld)", r);
    check(r == 0, msg);

    /* B: periodic timer, signal blocked for 210 ms: one signal, the rest counted as overruns. */
    struct its per = { 0, 20000000L, 0, 20000000L };
    t_settime(id, &per);
    nap(210);
    r = wait_for(S_USR1, &si, 1000000000L);
    /* Read before disarming: timer_settime starts the overrun count over. */
    long ov = t_overrun(id);
    struct its off = { 0, 0, 0, 0 };
    t_settime(id, &off);
    snprintf(msg, sizeof msg, "B: a 20 ms periodic timer blocked for 210 ms delivers one signal with 7..11 overruns (%ld, code %d, overrun %d)",
             r, si.code, si.overrun);
    check(r == S_USR1 && si.code == SI_TIMER_CODE && si.overrun >= 7 && si.overrun <= 11, msg);
    snprintf(msg, sizeof msg, "B: timer_getoverrun reports the overrun of that delivery (%ld, %d)", ov, si.overrun);
    check(ov == si.overrun, msg);
    /* An interval may elapse between the delivery above and the disarm while the timer is still armed, so one more signal may
     * already be queued. Drain it, then confirm the disarmed timer produces nothing more. */
    r = wait_for(S_USR1, &si, 0);
    nap(50);
    r = wait_for(S_USR1, &si, 0);
    snprintf(msg, sizeof msg, "B: once disarmed the timer queues nothing more (%ld)", r);
    check(r == -11, msg);
    t_delete(id);

    /* C: a NULL sigevent means SIGALRM with the timer id as its value. */
    int id2 = -1;
    r = t_create(1, 0, &id2);
    check(r == 0 && id2 >= 0, "C: timer_create with a NULL sigevent succeeds");
    t_settime(id2, &one);
    r = wait_for(S_ALRM, &si, 1000000000L);
    snprintf(msg, sizeof msg, "C: it sends SIGALRM with SI_TIMER and the timer id as si_value (%ld, code %d, value %ld, id %d)", r, si.code, si.value, id2);
    check(r == S_ALRM && si.code == SI_TIMER_CODE && si.value == id2 && si.timerid == id2, msg);
    t_delete(id2);

    /* D: a periodic timer whose signal is ignored keeps running; once the signal is no longer ignored it is delivered, and the
     * expiries that came while it was ignored are counted as overruns. */
    int id3 = -1;
    t_create(1, &sev, &id3);
    mask(UNBLOCK, &both);
    signal(S_USR1, SIG_IGN);
    t_settime(id3, &per);
    nap(100);
    mask(BLOCK, &both);
    signal(S_USR1, SIG_DFL);
    r = wait_for(S_USR1, &si, 300000000L);
    t_settime(id3, &off);
    snprintf(msg, sizeof msg, "D: a periodic timer ignored for 100 ms is delivered once it is not ignored, overruns counted (%ld, code %d, overrun %d)",
             r, si.code, si.overrun);
    check(r == S_USR1 && si.code == SI_TIMER_CODE && si.overrun >= 2, msg);
    t_delete(id3);

    mask(UNBLOCK, &both);
    print(failures ? "hello292: FAIL\n" : "hello292: PASS\n");
    return failures ? 1 : 0;
}
