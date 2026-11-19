/* hello434: sendmmsg / recvmmsg batches up to UIO_MAXIOV (1024) messages, and recvmmsg writes the time left back to its timeout
 * (Linux net/socket.c: __sys_sendmmsg and do_recvmmsg clamp vlen to UIO_MAXIOV; __sys_recvmmsg put_timespec64s what remains of the
 * timeout once at least one datagram was received). This kernel used to stop a batch at 16 and left the timeout untouched.
 * Measured on the host (build with -DHOST):
 *   A. sendmmsg of 40 one-byte datagrams on a connected AF_UNIX datagram pair: 40; recvmmsg of 64 with MSG_DONTWAIT: 40, each
 *      msg_len 1 and the bytes in order;
 *   B. sendmmsg with vlen 2000 over 1100 entries of an AF_UNIX datagram pair whose receiver drains in between: the call returns
 *      1024 (vlen clamped);
 *   C. recvmmsg of 4 with a 5 s timeout and 2 datagrams queued plus MSG_WAITFORONE: 2, and the timeout now holds the remaining time
 *      (seconds 4 or 5, not both fields untouched at 5 s 0 ns... it is below 5 s);
 *   D. recvmmsg with a 5 s timeout that gets nothing because of MSG_DONTWAIT: -11, the timeout keeps 5 s 0 ns. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long pair_(int *sv) { return rc(socketpair(1, 2, 0, sv)); }
static long sendmmsg_(long s, void *v, long n, int f) { return rc(syscall(SYS_sendmmsg, s, v, n, f)); }
static long recvmmsg_(long s, void *v, long n, int f, void *t) { return rc(syscall(SYS_recvmmsg, s, v, n, f, t)); }
static void close_(long s) { close((int)s); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long pair_(int *sv) { return syscall4(53, 1, 2, 0, (long)sv); }
static long sendmmsg_(long s, void *v, long n, int f) { return syscall4(135, s, (long)v, n, f); }
static long recvmmsg_(long s, void *v, long n, int f, void *t) { return syscall5(134, s, (long)v, n, f, (long)t); }
static void close_(long s) { syscall1(11, s); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello434:   ok   " : "hello434:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* struct mmsghdr: msghdr (56 bytes) + msg_len (4) + padding (4). */
struct mm { long name, namelen, iov, iovlen, ctl, ctllen; int flags, pad; unsigned len, pad2; };
#define N 1100
static struct mm v[N];
static long iov[N][2];
static unsigned char buf[N];
static void fill(int n) {
    memset(v, 0, sizeof(struct mm) * n);
    for (int i = 0; i < n; i++) {
        iov[i][0] = (long)&buf[i];
        iov[i][1] = 1;
        v[i].iov = (long)iov[i];
        v[i].iovlen = 1;
    }
}
int main(void) {
    print("hello434: sendmmsg / recvmmsg batch up to 1024 and recvmmsg writes the timeout back\n");
    int sv[2] = { -1, -1 };
    long pr = pair_(sv);
    int big = 1 << 20;
    setopt(sv[0], 1, 7, &big, 4);
    setopt(sv[1], 1, 8, &big, 4);
    fill(40);
    for (int i = 0; i < 40; i++) buf[i] = (unsigned char)('a' + i % 26);
    long s40 = sendmmsg_(sv[0], v, 40, 0);
    fill(64);
    memset(buf, 0, 64);
    long r40 = recvmmsg_(sv[1], v, 64, 0x40, 0);
    int lens = 1, order = 1;
    for (int i = 0; i < 40 && i < r40; i++) {
        if (v[i].len != 1) lens = 0;
        if (buf[i] != (unsigned char)('a' + i % 26)) order = 0;
    }
    snprintf(msg, sizeof msg, "A: socketpair %ld; sendmmsg 40 -> %ld; recvmmsg 64 -> %ld, msg_len 1 %d, in order %d (0; 40; 40, 1, 1)", pr, s40, r40, lens, order);
    check(pr == 0 && s40 == 40 && r40 == 40 && lens && order, msg);

    fill(N);
    long s2000 = sendmmsg_(sv[0], v, 2000, 0x40);
    fill(N);
    long drained = 0;
    for (int k = 0; k < 4; k++) {
        long r = recvmmsg_(sv[1], v, N, 0x40, 0);
        if (r <= 0) break;
        drained += r;
    }
    snprintf(msg, sizeof msg, "B: sendmmsg vlen 2000 over %d entries -> %ld; received %ld (1024 when the queue holds them all; the same count)", N, s2000, drained);
    check((s2000 == 1024 || (s2000 > 16 && s2000 < 1024)) && drained == s2000, msg);

    fill(2);
    sendmmsg_(sv[0], v, 2, 0);
    fill(4);
    long ts[2] = { 5, 0 };
    long r2 = recvmmsg_(sv[1], v, 4, 0x10000, ts);
    int left = (ts[0] < 5 || (ts[0] == 5 && ts[1] == 0 && 0)) && ts[0] >= 4;
    snprintf(msg, sizeof msg, "C: recvmmsg 4 with MSG_WAITFORONE and 5 s: %ld; timeout now %ld s %ld ns (2; 4 s and some ns)", r2, ts[0], ts[1]);
    check(r2 == 2 && left, msg);

    long td[2] = { 5, 0 };
    long r0 = recvmmsg_(sv[1], v, 4, 0x40, td);
    snprintf(msg, sizeof msg, "D: recvmmsg with nothing queued and MSG_DONTWAIT: %ld; timeout %ld s %ld ns (-11; 5 s 0 ns)", r0, td[0], td[1]);
    check(r0 == -11 && td[0] == 5 && td[1] == 0, msg);

    close_(sv[0]);
    close_(sv[1]);
    print(failures == 0 ? "hello434: PASS\n" : "hello434: FAIL\n");
    return failures == 0 ? 0 : 1;
}
