/* hello388: UDP sockets have no small system-wide limit (Linux allocates them on demand). Measured on the host (build with -DHOST,
 * run as root in `unshare --map-auto --map-root-user -n` after `ip link set lo up`):
 *   S. one process opens 100 IPv4 UDP sockets: every socket() succeeds, every sendto 127.0.0.1:9 succeeds and names a port, and the
 *      100 ports differ;
 *   B. right after that burst (every send drew an ICMP port unreachable on lo), a datagram one socket sends another is received:
 *      a loopback send is delivered at once (loopback_xmit -> netif_rx), it does not wait in a queue a burst can fill;
 *   R. after closing them, 100 new sockets with SO_REUSEADDR all bind 127.0.0.1:40388; a datagram sent there is received by exactly
 *      one of them;
 *   V. 100 IPv6 UDP sockets: every socket() and every sendto [::1]:9 succeeds;
 *   C. after closing everything, a fresh socket still sends and receives. */
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
static long sock4(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long sock6(void) {
    long s = rc(socket(AF_INET6, SOCK_DGRAM, 0));
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long bind_(long s, const unsigned char *a, int l) { return rc(bind((int)s, (const void *)a, l)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to, int l) { return rc(sendto((int)s, b, n, 0, (const void *)to, l)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long reuse(long s) { int one = 1; return rc(setsockopt((int)s, SOL_SOCKET, SO_REUSEADDR, &one, 4)); }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam = (f); memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define AF_INET6 10
static long sock4(void) { return syscall3(117, AF_INET, 2, 0); }
static long sock6(void) { return syscall3(117, AF_INET6, 2, 0); }
static long bind_(long s, const unsigned char *a, int l) { return syscall3(118, s, (long)a, l); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to, int l) { return syscall6(121, s, (long)b, n, 0, (long)to, l); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long reuse(long s) { int one = 1; return syscall5(132, s, 1, 2, (long)&one, 4); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
#define N 100
static int failures;
static char msg[480];
static long s[N];
static void check(int ok, const char *w) {
    print(ok ? "hello388:   ok   " : "hello388:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    FAM(a, AF_INET);
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[4] = 127; a[7] = 1;
}
static void mk6(unsigned char *a, int port) {
    for (int i = 0; i < 28; i++) a[i] = 0;
    FAM(a, AF_INET6);
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[23] = 1;
}
static long port_of(long x) {
    unsigned char a[28];
    long r = name_(x, a);
    return r < 0 ? r : ((a[2] << 8) | a[3]);
}
static void close_all(void) { for (int i = 0; i < N; i++) if (s[i] >= 0) close_(s[i]); }
static void pair_check(const char *tag) {
    unsigned char to9[16], bk[16];
    char b[8];
    mk4(to9, 9);
    long a0 = sock4(), c0 = sock4();
    long z1 = sendto_(a0, "x", 1, to9, 16);
    mk4(bk, (int)port_of(a0));
    long z2 = sendto_(c0, "hi", 2, bk, 16), z3 = -11;
    for (int k = 0; k < 25 && z3 == -11; k++) { z3 = recv_(a0, b, sizeof b); if (z3 == -11) pump(); }
    snprintf(msg, sizeof msg, "%s: a socket (port %d) sends %ld, another sends it %ld, it receives %ld (1 2 2)", tag, (bk[2] << 8) | bk[3], z1, z2, z3);
    check(z1 == 1 && z2 == 2 && z3 == 2, msg);
    close_(a0);
    close_(c0);
}
int main(void) {
    print("hello388: UDP sockets have no small system-wide limit\n");
    unsigned char to9[16], to96[28], at[16];
    char b[8];
    mk4(to9, 9);
    mk6(to96, 9);
    mk4(at, 40388);

    int opened = 0, sent = 0, distinct = 1;
    long first_err = 0;
    long ports[N];
    for (int i = 0; i < N; i++) {
        s[i] = sock4();
        if (s[i] < 0) { if (!first_err) first_err = s[i]; continue; }
        opened++;
        if (sendto_(s[i], "x", 1, to9, 16) == 1) sent++;
        ports[i] = port_of(s[i]);
        for (int j = 0; j < i; j++) if (s[j] >= 0 && ports[j] == ports[i]) distinct = 0;
    }
    snprintf(msg, sizeof msg, "S: %d of %d sockets opened (first error %ld), %d sent, ports distinct %d (100 0 100 1)", opened, N, first_err, sent, distinct);
    check(opened == N && sent == N && distinct, msg);
    close_all();
    pair_check("B");

    int bound = 0, reused = 0;
    long reuse_err = 0;
    first_err = 0;
    for (int i = 0; i < N; i++) {
        s[i] = sock4();
        if (s[i] < 0) { if (!first_err) first_err = s[i]; continue; }
        long ru = reuse(s[i]);
        if (ru == 0) reused++; else if (!reuse_err) reuse_err = ru;
        long r = bind_(s[i], at, 16);
        if (r == 0) bound++; else if (!first_err) first_err = r;
    }
    long sender = sock4();
    long r1 = sendto_(sender, "hi", 2, at, 16);
    int got = 0;
    for (int k = 0; k < 25 && got == 0; k++) {
        for (int i = 0; i < N; i++) if (s[i] >= 0 && recv_(s[i], b, sizeof b) == 2) got++;
        if (got == 0) pump();
    }
    for (int i = 0; i < N; i++) if (s[i] >= 0 && recv_(s[i], b, sizeof b) == 2) got++;
    snprintf(msg, sizeof msg, "R: %d of %d SO_REUSEADDR sockets (%d set, error %ld) bound 127.0.0.1:40388 (first error %ld); sendto %ld, received by %d (100 100 0 0 2 1)", bound, N, reused, reuse_err, first_err, r1, got);
    check(bound == N && reused == N && r1 == 2 && got == 1, msg);
    close_all();
    close_(sender);

    opened = 0, sent = 0;
    first_err = 0;
    for (int i = 0; i < N; i++) {
        s[i] = sock6();
        if (s[i] < 0) { if (!first_err) first_err = s[i]; continue; }
        opened++;
        if (sendto_(s[i], "x", 1, to96, 28) == 1) sent++;
    }
    snprintf(msg, sizeof msg, "V: %d of %d IPv6 sockets opened (first error %ld), %d sent (100 0 100)", opened, N, first_err, sent);
    check(opened == N && sent == N, msg);
    close_all();

    long a = sock4(), c = sock4();
    unsigned char back[16];
    long c1 = sendto_(a, "x", 1, to9, 16);
    mk4(back, (int)port_of(a));
    long c2 = sendto_(c, "hi", 2, back, 16), c3 = -11;
    for (int k = 0; k < 25 && c3 == -11; k++) { c3 = recv_(a, b, sizeof b); if (c3 == -11) pump(); }
    snprintf(msg, sizeof msg, "C: after closing everything a fresh socket (port %d) sends %ld, another sends it %ld, it receives %ld (1 2 2)", (back[2] << 8) | back[3], c1, c2, c3);
    check(a >= 0 && c >= 0 && c1 == 1 && c2 == 2 && c3 == 2, msg);
    close_(a);
    close_(c);

    print(failures ? "hello388: FAIL\n" : "hello388: PASS\n");
    return failures ? 1 : 0;
}
