/* hello447: madvise MADV_WIPEONFORK (18) and MADV_KEEPONFORK (19) (Linux mm/madvise.c: VM_WIPEONFORK on a private anonymous range;
 * dup_mmap gives the child the mapping without its pages, so the child reads zeros there). A shared or file mapping is EINVAL; a hole
 * in the range ENOMEM; KEEPONFORK clears the mark. The kernel used to reject both with EINVAL.
 * Measured on the host (build with -DHOST):
 *   A. madvise(WIPEONFORK) on page 1 of a 3-page private anonymous mapping -> 0; on a MAP_SHARED anonymous page -> -22; on an
 *      unmapped page -> -12; at an unaligned address -> -22;
 *   B. after fork the child reads 'a', 0, 'a' (page 1 is empty); it can write page 1; its own child (a grandchild) reads 0 there
 *      again; the parent still reads 'a' on every page;
 *   C. KEEPONFORK on page 1 -> 0, and the next child reads 'a' there;
 *   D. WIPEONFORK on pages 0-1: the child reads 0, 0, 'a';
 *   E. a child made by clone(SIGCHLD) (no CLONE_VM, the fork path of clone) sees the same: 0, 0, 'a'; a MADV_DONTFORK page is gone
 *      in it (reading it faults, so the child dies of SIGSEGV, 11). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long madvise_(void *a, long n, int adv) { return rc(madvise(a, n, adv)); }
static void *mapn(int pages, int shared) { return mmap(0, pages * 4096, PROT_READ | PROT_WRITE, (shared ? MAP_SHARED : MAP_PRIVATE) | MAP_ANONYMOUS, -1, 0); }
static void unmap(void *p, long n) { munmap(p, n); }
static long fork_(void) { return fork(); }
static long clone_(void) { return syscall(SYS_clone, 17, 0, 0, 0, 0); }
static long wait_(long pid, int *st) { return waitpid((pid_t)pid, st, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long madvise_(void *a, long n, int adv) { return syscall3(28, (long)a, n, adv); }
static void *mapn(int pages, int shared) { return (void *)syscall6(SYS_mmap, 0, pages * 4096, 3, shared ? 0x21 : 0x22, -1, 0); }
static void unmap(void *p, long n) { syscall2(SYS_munmap, (long)p, n); }
static long fork_(void) { return fork(); }
static long clone_(void) { return syscall5(243, 17, 0, 0, 0, 0); }
static long wait_(long pid, int *st) { return waitpid(pid, st, 0); }
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello447:   ok   " : "hello447:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* The child's view of the three pages, as an exit code: one bit per page that reads 0 (bit 3 set when a grandchild read page 1 as 0). */
static int child_view_by(unsigned char *p, int grand, int use_clone) {
    long pid = use_clone ? clone_() : fork_();
    if (pid == 0) {
        int v = 0;
        for (int i = 0; i < 3; i++) {
            if (p[i * 4096] == 0) v |= 1 << i;
            else if (p[i * 4096] != 'a') v |= 0x40;
        }
        if (grand) {
            p[4096] = 'z';
            long g = fork_();
            if (g == 0) _exit(p[4096] == 0 ? 0 : 1);
            int gs = 0;
            wait_(g, &gs);
            if (((gs >> 8) & 0xff) == 0) v |= 8;
        }
        _exit(v);
    }
    int st = 0;
    wait_(pid, &st);
    return (st >> 8) & 0xff;
}
static int child_view(unsigned char *p, int grand) { return child_view_by(p, grand, 0); }
int main(void) {
    print("hello447: madvise MADV_WIPEONFORK / MADV_KEEPONFORK\n");
    unsigned char *p = mapn(3, 0);
    memset(p, 'a', 3 * 4096);
    long a0 = madvise_(p + 4096, 4096, 18);
    unsigned char *sh = mapn(1, 1);
    sh[0] = 1;
    long a1 = madvise_(sh, 4096, 18);
    unsigned char *gap = mapn(1, 0);
    unmap(gap, 4096);
    long a2 = madvise_(gap, 4096, 18);
    long a3 = madvise_(p + 1, 4096, 18);
    snprintf(msg, sizeof msg, "A: wipe page 1 %ld, shared %ld, unmapped %ld, unaligned %ld (0, -22, -12, -22)", a0, a1, a2, a3);
    check(a0 == 0 && a1 == -22 && a2 == -12 && a3 == -22, msg);

    int v = child_view(p, 1);
    int parent_ok = p[0] == 'a' && p[4096] == 'a' && p[8192] == 'a';
    snprintf(msg, sizeof msg, "B: child view 0x%x (page 1 zero, grandchild zero: 0xa), parent keeps 'a' %d (1)", v, parent_ok);
    check(v == 0xa && parent_ok, msg);

    long k = madvise_(p + 4096, 4096, 19);
    v = child_view(p, 0);
    snprintf(msg, sizeof msg, "C: keeponfork %ld, child view 0x%x (0, 0x0)", k, v);
    check(k == 0 && v == 0, msg);

    long w2 = madvise_(p, 2 * 4096, 18);
    v = child_view(p, 0);
    snprintf(msg, sizeof msg, "D: wipe pages 0-1 %ld, child view 0x%x (0, 0x3)", w2, v);
    check(w2 == 0 && v == 3, msg);

    long cr = clone_();
    if (cr == 0) _exit(0);
    if (cr > 0) wait_(cr, 0);
    v = child_view_by(p, 0, 1);
    unsigned char *q = mapn(1, 0);
    q[0] = 'q';
    long dn = madvise_(q, 4096, 10);
    long pid = clone_();
    if (pid == 0) _exit(q[0] == 'q' ? 0 : 1);
    int st = 0;
    wait_(pid, &st);
    int sig = st & 0x7f;
    snprintf(msg, sizeof msg, "E: clone(SIGCHLD) %s, child view 0x%x; DONTFORK %ld, the clone child dies of signal %d (>0, 0x3, 0, 11)", cr > 0 ? "made a child" : "failed", v, dn, sig);
    if (cr <= 0) { snprintf(msg + strlen(msg), sizeof msg - strlen(msg), " clone -> %ld", cr); }
    check(cr > 0 && v == 3 && dn == 0 && sig == 11, msg);

    print(failures ? "hello447: FAIL\n" : "hello447: PASS\n");
    return failures ? 1 : 0;
}
