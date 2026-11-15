/* hello340: TCP bind() with SO_REUSEADDR follows Linux inet_csk_bind_conflict: a port another socket holds is shareable only when
 * both sockets set SO_REUSEADDR and the holder is not listening. An accepted connection inherits SO_REUSEADDR from its listener.
 * Measured on the host (build with -DHOST):
 *   A. both reuse, holder ESTABLISHED: bind 0;
 *   B. the holder set reuse but the new socket did not: EADDRINUSE;
 *   C. both reuse, holder only bound: bind 0, and the holder can still listen afterwards;
 *   D. holder listening, new reuse: EADDRINUSE;
 *   E. holder bound without reuse, new reuse: EADDRINUSE;
 *   F. an accepted connection reports SO_REUSEADDR 1 when its listener set it, and after the listener closes a reuse socket can
 *      bind the port while that accepted connection is still ESTABLISHED;
 *   G. two SO_REUSEADDR sockets bound to one port: once one listens, listen() on the other is EADDRINUSE;
 *   H. a socket sharing a connected socket's port cannot connect to the same peer (EADDRNOTAVAIL): the 4-tuple is taken. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock4(void) { return rc(socket(AF_INET, SOCK_STREAM, 0)); }
static void mk(struct sockaddr_in *a, int port) { memset(a, 0, sizeof *a); a->sin_family = AF_INET; a->sin_port = htons(port); a->sin_addr.s_addr = htonl(0x7f000001); }
static long bind4(long s, int port) { struct sockaddr_in a; mk(&a, port); return rc(bind((int)s, (void *)&a, sizeof a)); }
static long connect4(long s, int port) { struct sockaddr_in a; mk(&a, port); return rc(connect((int)s, (void *)&a, sizeof a)); }
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt(long s, int v) { return rc(setsockopt((int)s, SOL_SOCKET, SO_REUSEADDR, &v, 4)); }
static long getopt_(long s) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, SO_REUSEADDR, &v, &l)); return r < 0 ? r : v; }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static void mk(unsigned char *a, int port) { for (int i = 0; i < 16; i++) a[i] = 0; a[0] = 2; a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port; a[4] = 127; a[7] = 1; }
static void nap(void) { long t[2] = { 0, 5000000 }; syscall2(35, (long)t, 0); }
static long sock4(void) { return syscall3(117, 2, 1, 0); }
static long bind4(long s, int port) { unsigned char a[16]; mk(a, port); return syscall3(118, s, (long)a, 16); }
static long connect4(long s, int port) {
    unsigned char a[16];
    mk(a, port);
    long r = syscall3(124, s, (long)a, 16);
    for (int i = 0; i < 200 && (r == -115 || r == -114); i++) { syscall1(104, 0); nap(); r = syscall3(124, s, (long)a, 16); }
    return r == -106 ? 0 : r;
}
static long listen_(long s) { return syscall2(119, s, 4); }
static long accept_(long s) { long r = -11; for (int i = 0; i < 200 && r < 0; i++) { syscall1(104, 0); r = syscall4(131, s, 0, 0, 0x800); if (r < 0) nap(); } return r; }
static long setopt(long s, int v) { return syscall5(132, s, 1, 2, (long)&v, 4); }
static long getopt_(long s) { int v = -1; int l = 4; long r = syscall5(133, s, 1, 2, (long)&v, (long)&l); return r < 0 ? r : v; }
static void close_(long s) { syscall1(11, s); }
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello340:   ok   " : "hello340:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rsock(void) { long s = sock4(); setopt(s, 1); return s; }

int main(void) {
    print("hello340: TCP bind with SO_REUSEADDR (Linux inet_csk_bind_conflict)\n");

    long l = rsock();
    long l0 = bind4(l, 18850), l1 = listen_(l);
    long h = rsock();
    long h0 = bind4(h, 18851), h1 = connect4(h, 18850);
    long a = accept_(l);
    snprintf(msg, sizeof msg, "setup: listener bind %ld listen %ld, client bind %ld connect %ld, accept %ld", l0, l1, h0, h1, a);
    check(l0 == 0 && l1 == 0 && h0 == 0 && h1 == 0 && a >= 0, msg);

    long n = rsock();
    long na = bind4(n, 18851);
    snprintf(msg, sizeof msg, "A: both SO_REUSEADDR, holder ESTABLISHED: bind %ld", na);
    check(na == 0, msg);
    close_(n);

    long m = sock4();
    long mb = bind4(m, 18851);
    snprintf(msg, sizeof msg, "B: only the holder set SO_REUSEADDR: bind %ld", mb);
    check(mb == -98, msg);
    close_(m);

    long b1 = rsock();
    long b1b = bind4(b1, 18853);
    long b2 = rsock();
    long b2b = bind4(b2, 18853);
    long b1l = listen_(b1);
    snprintf(msg, sizeof msg, "C: both SO_REUSEADDR, holder only bound: bind %ld %ld, the holder listens afterwards %ld", b1b, b2b, b1l);
    check(b1b == 0 && b2b == 0 && b1l == 0, msg);

    long b3 = rsock();
    long b3b = bind4(b3, 18853);
    snprintf(msg, sizeof msg, "D: holder listening, new socket SO_REUSEADDR: bind %ld", b3b);
    check(b3b == -98, msg);
    close_(b3);
    long b2l = listen_(b2);
    snprintf(msg, sizeof msg, "G: the second socket bound with SO_REUSEADDR cannot listen while the first does: %ld", b2l);
    check(b2l == -98, msg);
    close_(b2);
    close_(b1);

    long t = rsock();
    long tb = bind4(t, 18851);
    long tc = connect4(t, 18850);
    snprintf(msg, sizeof msg, "H: bind %ld, then connect to the peer an ESTABLISHED socket on the port already talks to: %ld", tb, tc);
    check(tb == 0 && tc == -99, msg);
    close_(t);

    long e1 = sock4();
    long e1b = bind4(e1, 18854);
    long e2 = rsock();
    long e2b = bind4(e2, 18854);
    snprintf(msg, sizeof msg, "E: holder bound without SO_REUSEADDR, new socket with it: bind %ld %ld", e1b, e2b);
    check(e1b == 0 && e2b == -98, msg);
    close_(e2);
    close_(e1);

    long fo = getopt_(a);
    close_(l);
    long f = rsock();
    long fb = bind4(f, 18850);
    snprintf(msg, sizeof msg, "F: the accepted connection reports SO_REUSEADDR %ld; with it ESTABLISHED a reuse socket binds the old listener port: %ld", fo, fb);
    check(fo == 1 && fb == 0, msg);
    close_(f);

    close_(a);
    close_(h);
    print(failures ? "hello340: FAIL\n" : "hello340: PASS\n");
    return failures ? 1 : 0;
}
