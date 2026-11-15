/* hello348: UDP sockets on one port are told apart by their bound IPv4 address (Linux udp_lib_lport_inuse compares inet_rcv_saddr, and
 * udp4_lib_lookup prefers the socket bound to the destination address over a wildcard one, compute_score). Measured on the host (build
 * with -DHOST):
 *   A. bind 127.0.0.1:18903 and 127.0.0.2:18903 both succeed; a third socket binding 0.0.0.0:18903 or 127.0.0.2:18903 is EADDRINUSE;
 *   B. a datagram to 127.0.0.2:18903 reaches only the socket bound to 127.0.0.2, one to 127.0.0.1 only the other;
 *   C. a connected socket sending to 127.0.0.3:18903, where nobody is bound, gets ECONNREFUSED (111) on its next recv;
 *   D. with SO_REUSEADDR, 0.0.0.0:18904 and 127.0.0.2:18904 share the port: a datagram to 127.0.0.2 goes to the specific socket and one
 *      to 127.0.0.1 to the wildcard one. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long reuse(long s) { int one = 1; return rc(setsockopt((int)s, SOL_SOCKET, SO_REUSEADDR, &one, 4)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 16)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
static long sock(void) { return syscall3(117, AF_INET, 2, 0); }
static long reuse(long s) { int one = 1; return syscall5(132, s, 1, 2, (long)&one, 4); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET; (a)[1] = 0; } while (0)
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello348:   ok   " : "hello348:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk(unsigned char *s, int a, int d, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[4] = (unsigned char)a; s[7] = (unsigned char)d;
}
/* Datagrams that reach `s` within `ms` (each one a single byte); returns them as a bitmask of 'a'..'h'. */
static int collect(long s, int ms) {
    int mask = 0;
    char b[4];
    for (int t = 0; t < ms; t += 10) {
        long r;
        while ((r = recv_(s, b, sizeof b)) == 1) if (b[0] >= 'a' && b[0] <= 'h') mask |= 1 << (b[0] - 'a');
        pump();
    }
    return mask;
}

int main(void) {
    print("hello348: UDP sockets on one port are told apart by their bound IPv4 address\n");
    unsigned char a1[16], a2[16], a3[16], any[16], w4[16], s4[16], t1[16], t2[16];
    mk(a1, 127, 1, 18903); mk(a2, 127, 2, 18903); mk(a3, 127, 3, 18903); mk(any, 0, 0, 18903);
    mk(w4, 0, 0, 18904); mk(s4, 127, 2, 18904); mk(t1, 127, 1, 18904); mk(t2, 127, 2, 18904);

    long u1 = sock(), u2 = sock(), x = sock(), y = sock();
    long b1 = bind_(u1, a1), b2 = bind_(u2, a2), bx = bind_(x, any), by = bind_(y, a2);
    snprintf(msg, sizeof msg, "A: bind 127.0.0.1:18903 %ld, 127.0.0.2:18903 %ld; then 0.0.0.0:18903 %ld and 127.0.0.2:18903 %ld", b1, b2, bx, by);
    check(b1 == 0 && b2 == 0 && bx == -98 && by == -98, msg);
    close_(x);
    close_(y);

    long tx = sock();
    sendto_(tx, "a", 1, a2);
    sendto_(tx, "b", 1, a1);
    int m2 = collect(u2, 300), m1 = collect(u1, 100);
    snprintf(msg, sizeof msg, "B: the socket on 127.0.0.2 got mask %d (want 1 = a), the one on 127.0.0.1 got %d (want 2 = b)", m2, m1);
    check(m2 == 1 && m1 == 2, msg);

    long c = sock();
    long cr = connect_(c, a3);
    long cs = sendto_(c, "c", 1, 0);
    long crv = -11;
    char b[4];
    for (int t = 0; t < 2000 && crv == -11; t += 10) {
        crv = recv_(c, b, sizeof b);
        if (crv == -11) pump();
    }
    int stray = collect(u1, 50) | collect(u2, 50);
#ifdef HOST
    (void)cs;
#endif
    snprintf(msg, sizeof msg, "C: a connected socket to 127.0.0.3:18903 (connect %ld) gets recv %ld (want -111); the bound sockets got %d", cr, crv, stray);
    check(cr == 0 && crv == -111 && stray == 0, msg);
    close_(c);

    long w = sock(), s = sock();
    reuse(w);
    reuse(s);
    long bw = bind_(w, w4), bs = bind_(s, s4);
    sendto_(tx, "d", 1, t2);
    sendto_(tx, "e", 1, t1);
    int ms = collect(s, 300), mw = collect(w, 100);
    snprintf(msg, sizeof msg, "D: SO_REUSEADDR binds 0.0.0.0:18904 %ld and 127.0.0.2:18904 %ld; the specific socket got %d (want 8 = d), the wildcard %d (want 16 = e)",
             bw, bs, ms, mw);
    check(bw == 0 && bs == 0 && ms == 8 && mw == 16, msg);

    close_(w);
    close_(s);
    close_(tx);
    close_(u1);
    close_(u2);
    print(failures ? "hello348: FAIL\n" : "hello348: PASS\n");
    return failures ? 1 : 0;
}
