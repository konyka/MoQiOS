/* hello579: /proc/<pid>/status has voluntary_ctxt_switches and nonvoluntary_ctxt_switches lines (Linux: the task's voluntary and
 * involuntary context-switch counts). The kernel printed neither. A voluntary switch happens when the task blocks of its own
 * accord (sched_yield, sleep). A: both lines exist and parse as non-negative numbers; B: after several sched_yield / nanosleep
 * calls the voluntary count goes up; C: it never goes down. */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sched.h>
#include <time.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static void do_yield(void) { sched_yield(); }
static void nap(void) { struct timespec t = { 0, 1000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
static void do_yield(void) { syscall1(SYS_yield, 0); }
static void nap(void) { long t[2] = { 0, 1000000 }; syscall2(SYS_nanosleep, (long)t, 0); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello579:   ok   " : "hello579:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static long field(const char *key) {
    static char buf[8192];
    int fd = (int)open("/proc/self/status", O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, buf, sizeof buf - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *p = strstr(buf, key);
    if (!p) return -1;
    p += strlen(key);
    while (*p == ' ' || *p == '\t') p++;
    long v = -1;
    while (*p >= '0' && *p <= '9') { if (v < 0) v = 0; v = v * 10 + (*p - '0'); p++; }
    return v;
}
int main(void) {
    print("hello579: /proc/<pid>/status context-switch counts\n");
    long vol0 = field("voluntary_ctxt_switches:");
    long nonvol0 = field("nonvoluntary_ctxt_switches:");
    snprintf(msg, sizeof msg, "A: both lines present (vol %ld, nonvol %ld)", vol0, nonvol0);
    check(vol0 >= 0 && nonvol0 >= 0, msg);

    for (int i = 0; i < 20; i++) { do_yield(); nap(); }
    long vol1 = field("voluntary_ctxt_switches:");
    snprintf(msg, sizeof msg, "B: voluntary count rose after yields/sleeps (%ld -> %ld)", vol0, vol1);
    check(vol1 > vol0, msg);

    for (int i = 0; i < 5; i++) do_yield();
    long vol2 = field("voluntary_ctxt_switches:");
    snprintf(msg, sizeof msg, "C: voluntary count does not go backwards (%ld -> %ld)", vol1, vol2);
    check(vol2 >= vol1, msg);

    print(failures ? "hello579: FAIL\n" : "hello579: PASS\n");
    return failures ? 1 : 0;
}
