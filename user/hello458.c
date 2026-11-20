/* hello458: a recvmmsg batch that fails part-way keeps what it received and leaves the error for later (Linux do_recvmmsg: once
 * datagrams > 0, an error other than EAGAIN is stored in sk_err; the call returns the count, and the next receive or SO_ERROR
 * reports it once). Measured on the host (build with -DHOST, run in `unshare -n` with lo up):
 *   A. three datagrams queued on a UDP socket; recvmmsg of 3 whose second entry's buffer is unmapped (address 8): returns 1, the
 *      first msg_len 3; SO_ERROR then reads EFAULT (14) and a second SO_ERROR 0;
 *   B. the same again: recvmmsg returns 1; the next recv is EFAULT (the pending error, reported once), and the recv after it gets
 *      a datagram (the one the failed entry consumed is gone, the third is still there);
 *   C. a first entry whose buffer is unmapped fails the call with EFAULT and leaves no pending error. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long recvmmsg_(long s, void *v, long n, int f) { return rc(syscall(SYS_recvmmsg, s, v, n, f, 0)); }
static long soerror(long s) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, SO_ERROR, &v, &l)); return r < 0 ? r : v; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long recvmmsg_(long s, void *v, long n, int f) { return syscall5(134, s, (long)v, n, f, 0); }
static long soerror(long s) { int v = -1; int l = 4; long r = syscall5(133, s, 1, 4, (long)&v, (long)&l); return r < 0 ? r : v; }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello458:   ok   " : "hello458:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* struct mmsghdr: a 56-byte msghdr then msg_len, padded to 64. */
static unsigned char mm[3][64];
static long iov[3][2];
static char b0[16], b2[16];
static void setup(int bad_first) {
    memset(mm, 0, sizeof mm);
    iov[0][0] = bad_first ? 8 : (long)b0; iov[0][1] = 16;
    iov[1][0] = bad_first ? (long)b0 : 8; iov[1][1] = 16;
    iov[2][0] = (long)b2; iov[2][1] = 16;
    for (int i = 0; i < 3; i++) {
        long p = (long)iov[i];
        memcpy(mm[i] + 16, &p, 8);
        long one = 1;
        memcpy(mm[i] + 24, &one, 8);
    }
}
static unsigned msg_len(int i) { unsigned v; memcpy(&v, mm[i] + 56, 4); return v; }
int main(void) {
    print("hello458: a recvmmsg batch that fails part-way reports the error later\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4580 >> 8; a[3] = 4580 & 0xff; a[4] = 127; a[7] = 1;
    long s = sock(2, 2, 0);
    long b = bind_(s, a, 16);
    long c = sock(2, 2, 0);
    char in[16];

    for (int i = 0; i < 3; i++) sendto_(c, "abc", 3, a, 16);
    setup(0);
    long r = recvmmsg_(s, mm, 3, 0x40);
    unsigned l0 = msg_len(0);
    long e1 = soerror(s), e2 = soerror(s);
    while (recv_(s, in, sizeof in) >= 0) {}
    snprintf(msg, sizeof msg, "A: bind %ld; recvmmsg %ld, msg_len %u; SO_ERROR %ld then %ld (0; 1 3; 14 0)", b, r, l0, e1, e2);
    check(b == 0 && r == 1 && l0 == 3 && e1 == 14 && e2 == 0, msg);

    for (int i = 0; i < 3; i++) sendto_(c, "abc", 3, a, 16);
    setup(0);
    long rb = recvmmsg_(s, mm, 3, 0x40);
    long n1 = recv_(s, in, sizeof in), n2 = recv_(s, in, sizeof in), n3 = recv_(s, in, sizeof in);
    snprintf(msg, sizeof msg, "B: recvmmsg %ld; then recv %ld, %ld, %ld (1; -14 3 -11)", rb, n1, n2, n3);
    check(rb == 1 && n1 == -14 && n2 == 3 && n3 == -11, msg);

    sendto_(c, "abc", 3, a, 16);
    setup(1);
    long rc1 = recvmmsg_(s, mm, 3, 0x40);
    long ec = soerror(s);
    while (recv_(s, in, sizeof in) >= 0) {}
    snprintf(msg, sizeof msg, "C: a bad first entry: recvmmsg %ld; SO_ERROR %ld (-14 0)", rc1, ec);
    check(rc1 == -14 && ec == 0, msg);

    print(failures ? "hello458: FAIL\n" : "hello458: PASS\n");
    return failures ? 1 : 0;
}
