/* hello306: process_vm_readv and process_vm_writev reach memory in a large anonymous mapping of another process (one the kernel backs
 * with 2 MiB pages here: the child makes the mapping after fork, so fork's demotion of huge pages does not apply). Measured on the
 * host (build with -DHOST): the parent reads a marker the child wrote 1 MiB into a 4 MiB mapping (A), reads 8 KiB across a 2 MiB
 * boundary (B), and writes a new marker that the child then sees (C). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long pvr(long pid, void *l, long ln, void *r, long rn) { long x = syscall(SYS_process_vm_readv, pid, l, ln, r, rn, 0); return x < 0 ? -errno : x; }
static long pvw(long pid, void *l, long ln, void *r, long rn) { long x = syscall(SYS_process_vm_writev, pid, l, ln, r, rn, 0); return x < 0 ? -errno : x; }
static void *big_map(unsigned long len) {
    void *p = mmap(0, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? 0 : p;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
static long pvr(long pid, void *l, long ln, void *r, long rn) { return syscall6(283, pid, (long)l, ln, (long)r, rn, 0); }
static long pvw(long pid, void *l, long ln, void *r, long rn) { return syscall6(284, pid, (long)l, ln, (long)r, rn, 0); }
static void *big_map(unsigned long len) {
    long p = syscall6(SYS_mmap, 0, (long)len, 3 /* PROT_READ|PROT_WRITE */, 0x22 /* MAP_PRIVATE|MAP_ANONYMOUS */, -1, 0);
    return p < 0 ? 0 : (void *)p;
}
#endif

#define S_KILL 9
#define MIB (1024UL * 1024UL)
#define LEN (4 * MIB)

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello306:   ok   " : "hello306:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

int main(void) {
    print("hello306: process_vm across a large anonymous mapping\n");
    int sp[2], gp[2];
    pipe(sp);
    pipe(gp);
    long c = fork();
    if (c == 0) {
        /* The child maps its own 4 MiB after fork; the first full 2 MiB block inside it is what the kernel may back with a huge page. */
        char *m = big_map(LEN);
        unsigned long base = m ? (((unsigned long)m + 2 * MIB - 1) & ~(2 * MIB - 1)) : 0;
        char *blk = (char *)base;
        if (blk) {
            memset(blk, 'p', 2 * MIB + 4096);
            memcpy(blk + MIB, "child-marker", 12);
        }
        write(sp[1], &base, sizeof base);
        char go;
        read(gp[0], &go, 1);
        /* Report what the parent wrote, and whether the page the child shares with the parent kept its own content. */
        char out[24];
        memset(out, 0, sizeof out);
        if (blk) memcpy(out, blk + 2 * 4096, 12);
        write(sp[1], out, 24);
        for (;;) nap(1000);
    }
    unsigned long base = 0;
    read(sp[0], &base, sizeof base);
    char *blk = (char *)base;
    if (!blk) {
        print("hello306: FAIL (child mmap)\n");
        kill(c, S_KILL);
        waitpid(c, 0, 0);
        return 1;
    }

    /* A: read the child's marker 1 MiB into the block. */
    char buf[16] = { 0 };
    struct iovec l = { buf, 12 }, rm = { blk + MIB, 12 };
    long n = pvr(c, &l, 1, &rm, 1);
    snprintf(what, sizeof what, "A: process_vm_readv reads the child's marker 1 MiB into a 2 MiB block (%ld, \"%s\")", n, buf);
    check(n == 12 && memcmp(buf, "child-marker", 12) == 0, what);

    /* B: 8 KiB that straddle the end of the block and the start of the next 2 MiB stretch. */
    static char big[8192];
    struct iovec l2 = { big, sizeof big }, r2 = { blk + 2 * MIB - 4096, sizeof big };
    n = pvr(c, &l2, 1, &r2, 1);
    snprintf(what, sizeof what, "B: 8 KiB across the 2 MiB boundary are read whole (%ld, first byte '%c')", n, big[0]);
    check(n == 8192 && big[0] == 'p', what);

    /* C: write into the block: the child sees it, the parent's own copy does not change. */
    struct iovec l3 = { "parent-wrote", 12 }, r3 = { blk + 2 * 4096, 12 };
    n = pvw(c, &l3, 1, &r3, 1);
    write(gp[1], "g", 1);
    char rep[24] = { 0 };
    read(sp[0], rep, 24);
    snprintf(what, sizeof what, "C: process_vm_writev into the block reaches the child (%ld, child sees \"%.12s\")", n, rep);
    check(n == 12 && memcmp(rep, "parent-wrote", 12) == 0, what);

    kill(c, S_KILL);
    waitpid(c, 0, 0);
    print(failures == 0 ? "hello306: PASS\n" : "hello306: FAIL\n");
    return failures;
}
