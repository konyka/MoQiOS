/* hello438: madvise MADV_DONTFORK (10) and MADV_DOFORK (11) (Linux mm/madvise.c: VM_DONTCOPY on the range; dup_mmap skips such a
 * mapping, so the child of a fork does not have it at all). The kernel used to reject both with EINVAL.
 * Measured on the host (build with -DHOST):
 *   A. madvise(DONTFORK) on 2 pages of a 4-page anonymous mapping: 0; DOFORK on the second of them: 0; an unknown advice 99: -22;
 *   B. after fork the child finds page 1 (DONTFORK) unmapped: mincore -> -12 (ENOMEM), while pages 0, 2 and 3 keep the parent's
 *      bytes; the parent still reads every page;
 *   C. madvise(DONTFORK) on an unmapped range: -12. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long madvise_(void *a, long n, int adv) { return rc(madvise(a, n, adv)); }
static long mincore_(void *a, long n, unsigned char *v) { return rc(mincore(a, n, v)); }
static void *map4(void) { return mmap(0, 4 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); }
static long fork_(void) { return fork(); }
static long wait_(long pid, int *st) { return waitpid((pid_t)pid, st, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long madvise_(void *a, long n, int adv) { return syscall3(28, (long)a, n, adv); }
static long mincore_(void *a, long n, unsigned char *v) { return syscall3(27, (long)a, n, (long)v); }
static void *map4(void) { return (void *)syscall6(SYS_mmap, 0, 4 * 4096, 3, 0x22, -1, 0); }
static long fork_(void) { return fork(); }
static long wait_(long pid, int *st) { return waitpid(pid, st, 0); }
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello438:   ok   " : "hello438:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello438: madvise MADV_DONTFORK / MADV_DOFORK\n");
    unsigned char *p = map4();
    for (int i = 0; i < 4; i++) memset(p + i * 4096, 'a' + i, 4096);
    long a0 = madvise_(p + 4096, 2 * 4096, 10);
    long a1 = madvise_(p + 2 * 4096, 4096, 11);
    long a2 = madvise_(p, 4096, 99);
    snprintf(msg, sizeof msg, "A: DONTFORK on pages 1-2 %ld; DOFORK on page 2 %ld; advice 99 %ld (0 0 -22)", a0, a1, a2);
    check(a0 == 0 && a1 == 0 && a2 == -22, msg);

    long child = fork_();
    if (child == 0) {
        unsigned char v[1];
        long m1 = mincore_(p + 4096, 4096, v);
        int keep = p[0] == 'a' && p[2 * 4096] == 'c' && p[3 * 4096] == 'd';
        _exit((m1 == -12 ? 1 : 0) | (keep ? 2 : 0));
    }
    int st = -1;
    long w = wait_(child, &st);
    int code = (st >> 8) & 0xff;
    int parent_ok = p[0] == 'a' && p[4096] == 'b' && p[2 * 4096] == 'c' && p[3 * 4096] == 'd';
    snprintf(msg, sizeof msg, "B: fork %ld wait %ld; child: page 1 gone %d, pages 0 2 3 kept %d; parent reads all %d (1 1 1)", child, w, code & 1, (code >> 1) & 1,
             parent_ok);
    check(child > 0 && w == child && code == 3 && parent_ok, msg);

    long c0 = madvise_((void *)0x10000000000UL, 4096, 10);
    snprintf(msg, sizeof msg, "C: DONTFORK on an unmapped range %ld (-12)", c0);
    check(c0 == -12, msg);
    print(failures == 0 ? "hello438: PASS\n" : "hello438: FAIL\n");
    return failures == 0 ? 0 : 1;
}
