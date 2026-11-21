/* hello479: MADV_DONTFORK and MADV_WIPEONFORK on the brk heap and the stack (Linux: those are vmas like any mmap, so the marks
 * work there; the program image is file-backed, so MADV_WIPEONFORK on it is EINVAL). Measured on the host (build with -DHOST):
 *   A. four heap pages from brk filled with 'H': MADV_WIPEONFORK on pages 1-2 and MADV_DONTFORK on page 3 return 0;
 *   B. a stack page with 'S' in it: MADV_WIPEONFORK returns 0;
 *   C. a fork child reads 'H' from heap page 0, zeros from pages 1 and 2 and from the stack page; touching page 3 (not copied)
 *      would fault, so the child does not; the parent still reads 'H' from page 1;
 *   D. MADV_WIPEONFORK on a page of the program text is EINVAL; MADV_DONTFORK there is 0 (and is undone with MADV_DOFORK). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long brk_(long a) { return a ? (long)(brk((void *)a) == 0 ? a : (long)sbrk(0)) : (long)sbrk(0); }
static long madv(void *a, long n, int adv) { return rc(madvise(a, (size_t)n, adv)); }
static long fork_(void) { return rc(fork()); }
static long wait_(long p, int *st) { return rc(waitpid((int)p, st, 0)); }
static void exit_(int c) { _exit(c); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
typedef unsigned long uintptr_t;
static long brk_(long a) { return syscall1(SYS_brk, a); }
static long madv(void *a, long n, int adv) { return syscall3(SYS_madvise, (long)a, n, adv); }
static long fork_(void) { return syscall0(SYS_fork); }
static long wait_(long p, int *st) { return syscall3(SYS_waitpid, p, (long)st, 0); }
static void exit_(int c) { syscall1(2, c); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello479:   ok   " : "hello479:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello479: MADV_DONTFORK / MADV_WIPEONFORK on the brk heap and the stack\n");
    const long pg = 4096;
    long cur = brk_(0);
    char *h = (char *)((cur + pg - 1) & ~(pg - 1));
    long nb = brk_((long)h + 4 * pg);
    memset(h, 'H', 4 * pg);
    long a1 = madv(h + pg, 2 * pg, 18), a2 = madv(h + 3 * pg, pg, 10);
    snprintf(msg, sizeof msg, "A: brk %d; heap MADV_WIPEONFORK %ld, MADV_DONTFORK %ld (1 0 0)", nb == (long)h + 4 * pg, a1, a2);
    check(nb == (long)h + 4 * pg && a1 == 0 && a2 == 0, msg);

    char st[3 * 4096];
    char *s = (char *)(((uintptr_t)st + pg - 1) & ~(uintptr_t)(pg - 1));
    s[0] = 'S';
    long b1 = madv(s, pg, 18);
    snprintf(msg, sizeof msg, "B: stack MADV_WIPEONFORK %ld (0)", b1);
    check(b1 == 0, msg);

    long c = fork_();
    if (c == 0) {
        int ok = h[0] == 'H' && h[pg] == 0 && h[2 * pg] == 0 && s[0] == 0;
        exit_(ok ? 0 : 1);
    }
    int stv = -1;
    long w = wait_(c, &stv);
    int child_ok = w == c && (stv & 0xffff) == 0;
    snprintf(msg, sizeof msg, "C: child sees H 0 0 and a zero stack page %d; parent still H %d (1 1)", child_ok, h[pg] == 'H');
    check(child_ok && h[pg] == 'H' && s[0] == 'S', msg);

    char *text = (char *)((uintptr_t)&main & ~(uintptr_t)(pg - 1));
    long d1 = madv(text, pg, 18), d2 = madv(text, pg, 10), d3 = madv(text, pg, 11);
    snprintf(msg, sizeof msg, "D: text MADV_WIPEONFORK %ld, MADV_DONTFORK %ld, MADV_DOFORK %ld (-22 0 0)", d1, d2, d3);
    check(d1 == -22 && d2 == 0 && d3 == 0, msg);

    print(failures ? "hello479: FAIL\n" : "hello479: PASS\n");
    return failures ? 1 : 0;
}
