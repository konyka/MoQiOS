/* hello459: the kernel generator takes fresh keys from its interrupt-timing pool (Linux add_interrupt_randomness and crng_reseed,
 * every 5 s here during the first two minutes of uptime, then every 60 s). There is no Linux file for this; /proc/randstats is this
 * kernel's own ("reseeds=N pool_samples=N"), so the test has no host build.
 *   A. /proc/randstats reads "reseeds=" and "pool_samples=";
 *   B. interrupts keep feeding the pool: within 8 s of getrandom calls and sleeps, pool_samples or reseeds moves;
 *   C. the key has been replaced from the pool: in the first two minutes of uptime the count goes up within 8 s (5 s interval); later
 *      (60 s interval, as in the full boot run) it has already gone up at least once since boot;
 *   D. two 32-byte getrandom results differ. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello459:   ok   " : "hello459:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long number_after(const char *s, const char *key) {
    const char *p = strstr(s, key);
    if (!p) return -1;
    p += strlen(key);
    long v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    return v;
}
static long read_stats(long *reseeds, long *samples) {
    char b[128];
    long fd = syscall3(9, (long)"/proc/randstats", 0, 0);
    if (fd < 0) return fd;
    long n = syscall3(SYS_read, fd, (long)b, sizeof b - 1);
    syscall1(11, fd);
    if (n <= 0) return -1;
    b[n] = 0;
    *reseeds = number_after(b, "reseeds=");
    *samples = number_after(b, "pool_samples=");
    return n;
}
static void nap(int ms) { long t[2] = { 0, ms * 1000000L }; syscall2(35, (long)t, 0); }
int main(void) {
    print("hello459: the random generator reseeds from interrupt timing\n");
    long r0 = -1, s0 = -1;
    long n = read_stats(&r0, &s0);
    snprintf(msg, sizeof msg, "A: /proc/randstats %ld bytes, reseeds %ld, pool_samples %ld (>0 >=0 >=0)", n, r0, s0);
    check(n > 0 && r0 >= 0 && s0 >= 0, msg);

    long r1 = r0, s1 = s0;
    int moved = 0, reseeded = 0;
    unsigned char buf[32];
    for (int i = 0; i < 80 && !reseeded; i++) {
        syscall3(SYS_getrandom, (long)buf, sizeof buf, 0);
        nap(100);
        read_stats(&r1, &s1);
        if (s1 != s0 || r1 != r0) moved = 1;
        if (r1 > r0) reseeded = 1;
    }
    snprintf(msg, sizeof msg, "B: the pool moved %d (pool_samples %ld -> %ld, reseeds %ld -> %ld) (1)", moved, s0, s1, r0, r1);
    check(moved, msg);
    snprintf(msg, sizeof msg, "C: reseeded within 8 s %d, or before this test %d (reseeds %ld -> %ld) (one of them 1)", reseeded, r0 > 0, r0, r1);
    check(reseeded || r0 > 0, msg);

    unsigned char x[32], y[32];
    long g1 = syscall3(SYS_getrandom, (long)x, 32, 0), g2 = syscall3(SYS_getrandom, (long)y, 32, 0);
    snprintf(msg, sizeof msg, "D: getrandom %ld %ld, different %d (32 32 1)", g1, g2, memcmp(x, y, 32) != 0);
    check(g1 == 32 && g2 == 32 && memcmp(x, y, 32) != 0, msg);

    print(failures ? "hello459: FAIL\n" : "hello459: PASS\n");
    return failures ? 1 : 0;
}
