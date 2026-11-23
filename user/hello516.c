/* hello516: a system call may read stack memory the process has not touched yet (Linux: the kernel's read faults the page in, and
 * a fresh stack page reads as zeros). A write() from a stack page 32 KiB below the frame, which nothing has written, sends 64 zero
 * bytes; B a write() whose source starts on a touched page and runs into an untouched one sends the touched bytes and then zeros;
 * C a write() from an unmapped address and from a PROT_NONE mapping is EFAULT (not 0); D a source that runs from a mapped page into a
 * hole is a short write to a file (write and pwrite) and EFAULT to a pipe. Measured with -DHOST. */
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
static void *anon(long n, int prot) { void *p = mmap(0, (size_t)n, prot, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); return p == MAP_FAILED ? 0 : p; }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello516:   ok   " : "hello516:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* The page 32 KiB below the current frame: nothing in this program has used that much stack, so it has never been written. */
__attribute__((noinline)) static char *deep_stack_page(void) {
    volatile char here = 0;
    unsigned long a = (unsigned long)&here;
    return (char *)((a - 32 * 1024) & ~4095UL);
}
/* write() `n` bytes from `src` into a fresh pipe and read them back into `back`; the write's result. */
static long write_through_pipe(const char *src, long n, unsigned char *back) {
    int p[2];
    if (pipe(p) != 0) return -1000;
    long w = wr(p[1], src, n);
    if (w > 0) {
        long r = rd(p[0], back, w);
        if (r != w) w = -2000;
    }
    close(p[0]);
    close(p[1]);
    return w;
}
/* A 64 KiB frame reserves the room that deep_stack_page() points into; only its top is written. */
__attribute__((noinline)) static long with_room(long (*f)(void)) {
    volatile char room[64 * 1024];
    room[sizeof room - 1] = 0;
    return f();
}
static long case_a(void) {
    unsigned char back[64];
    memset(back, 0xAA, sizeof back);
    long w = write_through_pipe(deep_stack_page(), 64, back);
    if (w != 64) return w;
    for (int i = 0; i < 64; i++) if (back[i] != 0) return -3000 - i;
    return w;
}
static long case_b(void) {
    /* 8 bytes at the end of a page this frame writes, then 24 bytes on the untouched page below it */
    char *page = deep_stack_page() - 2 * 4096;
    char *src = page + 2 * 4096 - 8;
    memcpy(src, "abcdefgh", 8);
    unsigned char back[32];
    memset(back, 0xAA, sizeof back);
    long w = write_through_pipe(src, 32, back);
    if (w != 32) return w;
    if (memcmp(back, "abcdefgh", 8) != 0) return -4000;
    for (int i = 8; i < 32; i++) if (back[i] != 0) return -4000 - i;
    return w;
}
int main(void) {
    print("hello516: system calls reading untouched stack memory\n");
    long a = with_room(case_a);
    snprintf(msg, sizeof msg, "A: write() from an untouched stack page %ld, all zeros (64)", a);
    check(a == 64, msg);
    long b = with_room(case_b);
    snprintf(msg, sizeof msg, "B: write() from a touched page into an untouched one %ld, data then zeros (32)", b);
    check(b == 32, msg);
    unsigned char back[8];
    char *none = (char *)anon(4096, PROT_NONE);
    long c1 = write_through_pipe((const char *)0x7f0000000000UL, 8, back);
    long c2 = none ? write_through_pipe(none, 8, back) : -1;
    snprintf(msg, sizeof msg, "C: write() from an unmapped address %ld, from PROT_NONE %ld (-14 -14)", c1, c2);
    check(c1 == -EFAULT && c2 == -EFAULT, msg);

    /* D: a source that starts readable and runs into a hole: a file takes the readable part (a short write), a pipe takes none of
     * it (EFAULT; Linux copies a small pipe write in one piece). pwrite() is the same as write() for the file. */
    char *two = (char *)anon(8192, PROT_READ | PROT_WRITE);
    long d1 = -1, d2 = -1, d3 = -1;
    if (two) {
        memset(two, 'q', 8192);
        munmap(two + 4096, 4096);
        int f = (int)open("/tmp/hello516.tmp", 0x42 /* O_RDWR|O_CREAT */ | 0x200 /* O_TRUNC */, 0600);
        if (f >= 0) {
            d1 = wr(f, two + 4096 - 4, 8);
#ifdef HOST
            d2 = pwrite(f, two + 4096 - 4, 8, 0);
            if (d2 < 0) d2 = -errno;
#else
            d2 = syscall4(SYS_pwrite64, f, (long)(two + 4096 - 4), 8, 0);
#endif
            close(f);
            unlink("/tmp/hello516.tmp");
        }
        d3 = write_through_pipe(two + 4096 - 4, 8, back);
    }
    snprintf(msg, sizeof msg, "D: straddling a hole: file write %ld, pwrite %ld, pipe write %ld (4 4 -14)", d1, d2, d3);
    check(d1 == 4 && d2 == 4 && d3 == -EFAULT, msg);

    /* E: an empty pipe takes a write in whole pages of the source, so 8192 readable bytes before a hole all go in. (How much of a
     * partial page goes in depends on the pipe's last buffer in Linux; only the empty-pipe, whole-page cases are checked.) */
    long e1 = -1, e2 = -1;
    char *three = (char *)anon(4 * 4096, PROT_READ | PROT_WRITE);
    if (three) {
        memset(three, 'r', 4 * 4096);
        munmap(three + 3 * 4096, 4096); /* pages 0-2 readable, page 3 a hole */
        static unsigned char big[12288];
        int p2[2];
        if (pipe(p2) == 0) {
            e1 = wr(p2[1], three + 3 * 4096 - 8192, 12288);
            if (e1 > 0) rd(p2[0], big, e1);
            e2 = wr(p2[1], three + 3 * 4096 - 4096, 8192);
            close(p2[0]);
            close(p2[1]);
        }
    }
    snprintf(msg, sizeof msg, "E: into an empty pipe, 8192 readable bytes before a hole %ld, 4096 %ld (8192 4096)", e1, e2);
    check(e1 == 8192 && e2 == 4096, msg);
    print(failures ? "hello516: FAIL\n" : "hello516: PASS\n");
    return failures ? 1 : 0;
}
