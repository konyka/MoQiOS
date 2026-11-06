/* hello242: uname, gethostname, getrandom, getentropy, getpagesize and sysconf of moqi_libc on the real kernel. Expected values were
 * measured against glibc on Linux with an equivalent program, except where noted (the kernel is not Linux: sysname is MoQiOS, and
 * _SC_OPEN_MAX is this kernel's descriptor-table size, 64). getrandom is also called as a raw system call to check the kernel's own
 * rules: any length up to the per-call cap is served in full (the old limit of 256 bytes was wrong), flags outside GRND_NONBLOCK,
 * GRND_RANDOM and GRND_INSECURE are EINVAL, RANDOM together with INSECURE is EINVAL, and a bad destination is EFAULT. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/utsname.h"
#include "../lib/moqi_libc/include/sysinfo.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello242:   ok   " : "hello242:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int distinct(const unsigned char *b, int n) {
    int seen[256];
    memset(seen, 0, sizeof seen);
    int d = 0;
    for (int i = 0; i < n; i++) if (!seen[b[i]]++) d++;
    return d;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello242: uname, hostname, random, sysconf\n");
    char what[200];

    /* A: uname */
    struct utsname u;
    memset(&u, '#', sizeof u);
    int r = uname(&u);
    snprintf(what, sizeof what, "A: uname fills the six fields (rc %d sysname \"%s\" nodename \"%s\" machine \"%s\")", r, u.sysname, u.nodename, u.machine);
    check(r == 0 && strcmp(u.sysname, "MoQiOS") == 0 && strcmp(u.machine, "x86_64") == 0 && u.nodename[0] != '#' && u.domainname[0] != '#', what);
    check(sizeof(struct utsname) == 390, "A: sizeof(struct utsname) is 390");

    /* B: gethostname */
    char h[70];
    memset(h, '#', sizeof h);
    r = gethostname(h, sizeof h);
    snprintf(what, sizeof what, "B: gethostname matches uname's nodename (rc %d \"%s\" vs \"%s\")", r, h, u.nodename);
    check(r == 0 && strcmp(h, u.nodename) == 0, what);
    size_t hl = strlen(u.nodename);
    char tight[70];
    memset(tight, '#', sizeof tight);
    check(gethostname(tight, hl + 1) == 0 && strcmp(tight, u.nodename) == 0, "B: a buffer of exactly name + 1 bytes is enough");
    memset(tight, '#', sizeof tight);
    errno = 0;
    check(gethostname(tight, hl) == -1 && errno == ENAMETOOLONG, "B: a buffer one byte short is -1 / ENAMETOOLONG");
    memset(tight, '#', sizeof tight);
    errno = 0;
    check(gethostname(tight, 0) == -1 && errno == ENAMETOOLONG && tight[0] == '#', "B: size 0 is -1 / ENAMETOOLONG and writes nothing");

    /* C: getrandom through libc */
    unsigned char b[300];
    memset(b, 0, sizeof b);
    long g = getrandom(b, 64, 0);
    snprintf(what, sizeof what, "C: getrandom(64) fills 64 bytes that are not all alike (%ld, %d distinct values)", g, distinct(b, 64));
    check(g == 64 && distinct(b, 64) > 20, what);
    memset(b, 0, sizeof b);
    g = getrandom(b, 300, 0);
    snprintf(what, sizeof what, "C: getrandom(300) is served in full (%ld, %d distinct values)", g, distinct(b, 300));
    check(g == 300 && distinct(b, 300) > 100, what);
    check(b[299] != 0 || b[298] != 0 || b[297] != 0, "C: the tail past 256 bytes is written");
    static unsigned char big[70000];
    g = getrandom(big, sizeof big, 0);
    snprintf(what, sizeof what, "C: getrandom(70000) is served in full (%ld)", g);
    check(g == (long)sizeof big, what);
    int zero_blocks = 0;
    for (int blk = 0; blk < 70000 / 4096; blk++) {
        int z = 1;
        for (int i = 0; i < 4096; i++) if (big[blk * 4096 + i]) { z = 0; break; }
        zero_blocks += z;
    }
    check(zero_blocks == 0, "C: no 4096-byte block of the 70000 is left zero");
    g = getrandom(b, 16, GRND_NONBLOCK);
    check(g == 16, "C: GRND_NONBLOCK is accepted");
    g = getrandom(b, 16, GRND_RANDOM);
    check(g == 16, "C: GRND_RANDOM is accepted");
    g = getrandom(b, 16, GRND_INSECURE);
    check(g == 16, "C: GRND_INSECURE is accepted");
    errno = 0;
    check(getrandom(b, 16, 0x8) == -1 && errno == EINVAL, "C: an unknown flag (0x8) is -1 / EINVAL");
    errno = 0;
    check(getrandom(b, 16, 0x1234) == -1 && errno == EINVAL, "C: flags 0x1234 are -1 / EINVAL");
    errno = 0;
    check(getrandom(b, 16, GRND_RANDOM | GRND_INSECURE) == -1 && errno == EINVAL, "C: GRND_RANDOM together with GRND_INSECURE is -1 / EINVAL");
    check(getrandom(b, 0, 0) == 0, "C: a zero-length request is 0");
    check(getrandom((void *)0, 0, 0) == 0, "C: a zero-length request with a NULL buffer is 0");
    errno = 0;
    check(getrandom((void *)0, 16, 0) == -1 && errno == EFAULT, "C: a NULL buffer is -1 / EFAULT");
    errno = 0;
    check(getrandom((void *)1, 16, 0) == -1 && errno == EFAULT, "C: an unmapped buffer is -1 / EFAULT");
    errno = 0;
    check(getrandom((void *)0xffff800000000000UL, 16, 0) == -1 && errno == EFAULT, "C: a kernel address is -1 / EFAULT");

    /* D: getentropy */
    memset(b, 0, sizeof b);
    check(getentropy(b, 256) == 0 && distinct(b, 256) > 80, "D: getentropy(256) fills 256 bytes");
    errno = 0;
    check(getentropy(b, 257) == -1 && errno == EIO, "D: getentropy(257) is -1 / EIO");
    check(getentropy(b, 0) == 0, "D: getentropy(0) is 0");
    errno = 0;
    check(getentropy((void *)0, 8) == -1 && errno == EFAULT, "D: getentropy(NULL, 8) is -1 / EFAULT");

    /* E: getpagesize and sysconf */
    check(getpagesize() == 4096, "E: getpagesize is 4096");
    check(sysconf(_SC_PAGESIZE) == 4096 && sysconf(_SC_PAGE_SIZE) == 4096, "E: _SC_PAGESIZE is 4096");
    check(sysconf(_SC_CLK_TCK) == 100, "E: _SC_CLK_TCK is 100");
    check(sysconf(_SC_HOST_NAME_MAX) == 64 && HOST_NAME_MAX == 64, "E: _SC_HOST_NAME_MAX is 64");
    check(sysconf(_SC_LOGIN_NAME_MAX) == 256 && sysconf(_SC_NGROUPS_MAX) == 65536 && sysconf(_SC_IOV_MAX) == 1024 && sysconf(_SC_LINE_MAX) == 2048, "E: the fixed limits match glibc");
    snprintf(what, sizeof what, "E: _SC_OPEN_MAX is this kernel's descriptor table, 64 (%ld)", sysconf(_SC_OPEN_MAX));
    check(sysconf(_SC_OPEN_MAX) == 64, what);
    check(sysconf(_SC_ARG_MAX) > 0 && sysconf(_SC_CHILD_MAX) > 0, "E: _SC_ARG_MAX and _SC_CHILD_MAX are positive");
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    long cpus_conf = sysconf(_SC_NPROCESSORS_CONF);
    snprintf(what, sizeof what, "E: the processor count is at least 1 (online %ld, configured %ld)", cpus, cpus_conf);
    check(cpus >= 1 && cpus_conf >= 1, what);
    {
        char nb[48];
        snprintf(nb, sizeof nb, "hello242: cpus online=%ld\n", cpus);
        print(nb);
    }
    /* the processor count follows the kernel's CPU count and the affinity mask: ask the kernel directly and compare */
    {
        unsigned long m[2] = {0, 0};
        long ar = syscall3(SYS_sched_getaffinity, 0, sizeof m, (long)m);
        int bits = 0;
        for (int i = 0; i < 64; i++) bits += (int)((m[0] >> i) & 1);
        snprintf(what, sizeof what, "E: sched_getaffinity reports every configured CPU for an unpinned task (rc %ld, %d bits, sysconf says %ld)", ar, bits, cpus);
        check(ar == 8 && bits == (int)cpus && bits >= 1, what);
        errno = 0;
        long bad = syscall3(SYS_sched_getaffinity, 0, 4, (long)m);
        check(bad == -EINVAL, "E: a mask buffer smaller than the kernel's (4 bytes) is -EINVAL");
        errno = 0;
        bad = syscall3(SYS_sched_getaffinity, 0, 0, (long)m);
        check(bad == -EINVAL, "E: a mask buffer of 0 bytes is -EINVAL");
    }
    long phys = sysconf(_SC_PHYS_PAGES);
    long avail = sysconf(_SC_AVPHYS_PAGES);
    snprintf(what, sizeof what, "E: physical pages are counted, and the free ones are fewer (%ld total, %ld free)", phys, avail);
    check(phys > 1000 && avail > 0 && avail <= phys, what);
    errno = 0;
    check(sysconf(99999) == -1 && errno == EINVAL, "E: an unknown name is -1 / EINVAL");
    errno = 0;
    check(sysconf(-1) == -1 && errno == EINVAL, "E: name -1 is -1 / EINVAL");

    print(failures == 0 ? "hello242: PASS\n" : "hello242: FAIL\n");
    return failures;
}
