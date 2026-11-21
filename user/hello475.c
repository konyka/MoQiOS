/* hello475: how many datagrams a raw socket queues is its SO_RCVBUF's business, not a fixed count (Linux __sock_queue_rcv_skb takes
 * a datagram while sk_rmem_alloc is below sk_rcvbuf). Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with lo up), sending 400 datagrams of protocol 253 to a raw socket that does not read:
 *   A. 1-byte and 100-byte payloads with the default SO_RCVBUF (212992): 222 queued, in order;
 *   B. 1000-byte and 1480-byte ones: 93;
 *   C. with SO_RCVBUF 16384 (reads back 32768): 1000-byte ones: 15. */
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n, int f) { return rc(recv((int)s, b, (size_t)n, f)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void nap(void) { usleep(20000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n, int f) { return syscall6(122, s, (long)b, n, f, 0, 0); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello475:   ok   " : "hello475:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char a[16];
static long r, s;
static int in_order;
static char b[2000];
/* Send 400 datagrams of `size` bytes numbered in their first two bytes, then count what is queued (and whether it is in order). */
static int run(int size) {
    for (int i = 0; i < 400; i++) {
        if (size == 1) {
            b[0] = (char)i;
        } else {
            b[0] = (char)(i >> 8);
            b[1] = (char)i;
        }
        sendto_(s, b, size, a, 16);
    }
    nap();
    int n = 0, prev = -1;
    in_order = 1;
    while (recv_(r, b, sizeof b, 0x40) > 0) {
        int v = (unsigned char)b[20] << 8 | (unsigned char)b[21];
        if (size == 1) v = (unsigned char)b[20];
        if (prev >= 0 && v != ((prev + 1) & (size == 1 ? 0xff : 0xffff))) in_order = 0;
        prev = v;
        n++;
    }
    return n;
}
int main(void) {
    print("hello475: SO_RCVBUF, not a fixed count, bounds a raw socket's queue\n");
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4740 >> 8; a[3] = 4740 & 0xff; a[4] = 127; a[7] = 1;
    r = sock(2, 3, 253);
    s = sock(2, 3, 253);
    long bd = r >= 0 && s >= 0 ? 0 : -1;
    int n1 = run(1), o1 = in_order, n100 = run(100), o100 = in_order;
    snprintf(msg, sizeof msg, "A: raw sockets %ld; 1-byte %d in order %d, 100-byte %d in order %d (0 222 1 222 1)", bd, n1, o1, n100, o100);
    check(bd == 0 && n1 == 222 && o1 && n100 == 222 && o100, msg);
    int n1000 = run(1000), n1480 = run(1480), o1480 = in_order;
    snprintf(msg, sizeof msg, "B: 1000-byte %d, 1480-byte %d in order %d (93 93 1)", n1000, n1480, o1480);
    check(n1000 == 93 && n1480 == 93 && o1480, msg);
    int v = 16384;
    long sv = setopt_(r, 1, 8, &v, 4);
    int nc = run(1000);
    snprintf(msg, sizeof msg, "C: SO_RCVBUF 16384 %ld; 1000-byte %d (0 15)", sv, nc);
    check(sv == 0 && nc == 15, msg);
    print(failures ? "hello475: FAIL\n" : "hello475: PASS\n");
    return failures ? 1 : 0;
}
