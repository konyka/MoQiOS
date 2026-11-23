/* hello515: a system call may write into stack and anonymous memory the process has not touched yet (Linux: the kernel's own
 * access faults the page in, as a user access would). The stack grows by demand faults, so the pages below what the process has
 * used have no page-table entry until something writes them. A a pipe read whose destination starts on such a stack page, 32 KiB
 * below the frame; B getcwd into such a page; C a pipe read into page 5 of a fresh MAP_ANONYMOUS mapping; D a pipe read whose
 * destination crosses from a touched stack page into an untouched one gets all of it; E read() into a PROT_READ mapping and into
 * an address nothing is mapped at is still EFAULT, and a PROT_NONE mapping too. Measured with -DHOST. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long gcwd(char *b, long n) { return getcwd(b, (size_t)n) ? (long)strlen(b) : -errno; }
static void *anon(long n, int prot) { void *p = mmap(0, (size_t)n, prot, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); return p == MAP_FAILED ? 0 : p; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/mman.h"
static long rd(int fd, void *b, long n) { return syscall3(SYS_read, fd, (long)b, n); }
static long wr(int fd, const void *b, long n) { return syscall3(SYS_write, fd, (long)b, n); }
static long gcwd(char *b, long n) { long r = syscall2(SYS_getcwd, (long)b, n); return r < 0 ? r : (long)strlen(b); }
static void *anon(long n, int prot) { void *p = mmap(0, (size_t)n, prot, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); return p == MAP_FAILED ? 0 : p; }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello515:   ok   " : "hello515:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char text[] = "0123456789abcdef0123456789abcdef"; /* written to a pipe and read back */

/* The address 32 KiB below the current frame, rounded to a page: nothing in this program has used that much stack yet, so the page
 * has never been written. Taking the address of a local and doing arithmetic on it keeps the compiler from touching the memory. */
__attribute__((noinline)) static char *deep_stack_page(void) {
    volatile char here = 0;
    unsigned long a = (unsigned long)&here;
    return (char *)((a - 32 * 1024) & ~4095UL);
}
/* Read `n` bytes through a fresh pipe into `dst`. */
static long pipe_read_into(char *dst, long n) {
    int p[2];
    if (pipe(p) != 0) return -1000;
    wr(p[1], text, n);
    long r = rd(p[0], dst, n);
    close(p[0]);
    close(p[1]);
    return r;
}
/* Run `f` on a stack frame large enough that `deep_stack_page()` from inside it is still within the stack (the frame itself is
 * what reserves the room; it is never written). */
__attribute__((noinline)) static long with_room(long (*f)(void)) {
    volatile char room[64 * 1024];
    room[sizeof room - 1] = 0; /* touch only the top, next to the caller */
    return f();
}
static long case_a(void) {
    char *dst = deep_stack_page();
    long r = pipe_read_into(dst, (long)sizeof text - 1);
    return r == (long)sizeof text - 1 && memcmp(dst, text, sizeof text - 1) == 0 ? r : (r < 0 ? r : -2000);
}
static long case_b(void) {
    char *dst = deep_stack_page() - 4096;
    return gcwd(dst, 64);
}
static long case_d(void) {
    /* the last 8 bytes of a page this frame has written, then 24 bytes on the page below that nobody has */
    char *page = deep_stack_page() - 2 * 4096;
    page[4095 + 4096] = 1; /* write the upper page */
    char *dst = page + 4096 - 8;
    long r = pipe_read_into(dst, (long)sizeof text - 1);
    return r == (long)sizeof text - 1 && memcmp(dst, text, sizeof text - 1) == 0 ? r : (r < 0 ? r : -2000);
}
int main(void) {
    print("hello515: system calls writing into untouched stack and anonymous memory\n");
    long a = with_room(case_a);
    snprintf(msg, sizeof msg, "A: pipe read into an untouched stack page %ld (%d)", a, (int)sizeof text - 1);
    check(a == (long)sizeof text - 1, msg);

    long b = with_room(case_b);
    snprintf(msg, sizeof msg, "B: getcwd into an untouched stack page %ld (> 0)", b);
    check(b > 0, msg);

    char *m = (char *)anon(8 * 4096, PROT_READ | PROT_WRITE);
    long c = m ? pipe_read_into(m + 5 * 4096, (long)sizeof text - 1) : -1;
    int c_ok = c == (long)sizeof text - 1 && m && memcmp(m + 5 * 4096, text, sizeof text - 1) == 0;
    snprintf(msg, sizeof msg, "C: pipe read into page 5 of a fresh MAP_ANONYMOUS mapping %ld, data %d (%d 1)", c, c_ok, (int)sizeof text - 1);
    check(c_ok, msg);

    long d = with_room(case_d);
    snprintf(msg, sizeof msg, "D: pipe read crossing into an untouched stack page %ld (%d)", d, (int)sizeof text - 1);
    check(d == (long)sizeof text - 1, msg);

    char *ro = (char *)anon(4096, PROT_READ);
    char *none = (char *)anon(4096, PROT_NONE);
    long e1 = ro ? pipe_read_into(ro, 8) : -1;
    long e2 = pipe_read_into((char *)0x7f0000000000UL, 8); /* nothing is mapped there */
    long e3 = none ? pipe_read_into(none, 8) : -1;
    snprintf(msg, sizeof msg, "E: read into PROT_READ %ld, unmapped %ld, PROT_NONE %ld (-14 -14 -14)", e1, e2, e3);
    check(e1 == -EFAULT && e2 == -EFAULT && e3 == -EFAULT, msg);
    print(failures ? "hello515: FAIL\n" : "hello515: PASS\n");
    return failures ? 1 : 0;
}
