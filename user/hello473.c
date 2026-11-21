/* hello473: a UDP socket's receive queue is a FIFO (Linux sk_receive_queue): datagrams come out in the order they arrived, also
 * after reads have freed slots in the middle and when IPv4 and IPv6 ones are mixed on a dual-stack socket. Measured on the host
 * (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   A. send 1 2 3, read one (1), send 4: the next three reads are 2 3 4;
 *   B. send a b c d e, read two (a b), send f g: then c d e f g;
 *   C. on an IPv6 socket bound to [::1] (IPV6_V6ONLY, as every AF_INET6 socket of this kernel is), datagrams from two senders: 1 and 3
 *      from one, 2 and 4 from the other, read one (1) before 4 is sent: then 2 3 4. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n, int f) { return rc(recv((int)s, b, (size_t)n, f)); }
static void nap(void) { usleep(10000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n, int f) { return syscall6(122, s, (long)b, n, f, 0, 0); }
static void nap(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello473:   ok   " : "hello473:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long r;
static void snd(long s, char c, const void *to, int tl) {
    sendto_(s, &c, 1, to, tl);
}
/* The next `n` datagrams' first bytes, in `out` (a '-' for none). */
static void rd(int n, char *out) {
    nap();
    for (int i = 0; i < n; i++) {
        char c = '-';
        if (recv_(r, &c, 1, 0x40) != 1) c = '-';
        out[i] = c;
    }
    out[n] = 0;
}
int main(void) {
    print("hello473: UDP datagrams come out in arrival order\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4730 >> 8; a[3] = 4730 & 0xff; a[4] = 127; a[7] = 1;
    r = sock(2, 2, 0);
    long s = sock(2, 2, 0);
    long b = bind_(r, a, 16);
    char got[16];
    snd(s, '1', a, 16); snd(s, '2', a, 16); snd(s, '3', a, 16);
    rd(1, got);
    char first = got[0];
    snd(s, '4', a, 16);
    rd(3, got);
    snprintf(msg, sizeof msg, "A: bind %ld; first %c, then %s (0 1 234)", b, first, got);
    check(b == 0 && first == '1' && !strcmp(got, "234"), msg);

    for (char c = 'a'; c <= 'e'; c++) snd(s, c, a, 16);
    rd(2, got);
    char ab[3] = { got[0], got[1], 0 };
    snd(s, 'f', a, 16); snd(s, 'g', a, 16);
    rd(5, got);
    snprintf(msg, sizeof msg, "B: first %s, then %s (ab cdefg)", ab, got);
    check(!strcmp(ab, "ab") && !strcmp(got, "cdefg"), msg);

    unsigned char a6[28];
    memset(a6, 0, 28);
    a6[0] = 10; a6[2] = 4731 >> 8; a6[3] = 4731 & 0xff;
    a6[23] = 1;
    long r6 = sock(10, 2, 0);
    long b6 = bind_(r6, a6, 28);
    long s6 = sock(10, 2, 0), t6 = sock(10, 2, 0);
    snd(s6, '1', a6, 28); snd(t6, '2', a6, 28); snd(s6, '3', a6, 28);
    r = r6;
    rd(1, got);
    first = got[0];
    snd(t6, '4', a6, 28);
    rd(3, got);
    snprintf(msg, sizeof msg, "C: IPv6 socket %ld bind %ld; first %c, then %s (>=0 0 1 234)", r6, b6, first, got);
    check(r6 >= 0 && b6 == 0 && first == '1' && !strcmp(got, "234"), msg);

    print(failures ? "hello473: FAIL\n" : "hello473: PASS\n");
    return failures ? 1 : 0;
}
