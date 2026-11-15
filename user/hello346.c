/* hello346: TCP connections that differ only in a local address are different connections (Linux matches the full 4-tuple including the
 * local address, __inet_lookup_established and __inet_check_established). Measured on the host (build with -DHOST):
 *   A. listeners on 127.0.0.1:18898 and 127.0.0.2:18898;
 *   B. two SO_REUSEADDR clients both bound to 127.0.0.5:18899 connect to 127.0.0.1 and to 127.0.0.2; both are accepted by the right
 *      listener, and each server socket gets the bytes its own client sent;
 *   C. a client bound to 127.0.0.6:18899 connects to 127.0.0.1:18898 (same port pair and peer as the first client of B, other local
 *      address): the connect succeeds and the data reaches its own server socket;
 *   D. a SO_REUSEADDR client bound to 127.0.0.5:18899 connecting to 127.0.0.1:18898 again (the exact 4-tuple of B's first client) is
 *      EADDRNOTAVAIL (99). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(void) { return rc(socket(AF_INET, SOCK_STREAM, 0)); }
static long reuse(long s) { int one = 1; return rc(setsockopt((int)s, SOL_SOCKET, SO_REUSEADDR, &one, 4)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 16)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long listen_(long s) { return rc(listen((int)s, 8)); }
static long accept_(long s) { return rc(accept4((int)s, 0, 0, SOCK_NONBLOCK)); }
static long send_(long s, const char *b, int n) { return rc(write((int)s, b, n)); }
static long recv_(long s, char *b, int n) { return rc(read((int)s, b, n)); }
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
static long sock(void) { return syscall3(117, AF_INET, 1, 0); }
static long reuse(long s) { int one = 1; return syscall5(132, s, 1, 2, (long)&one, 4); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long listen_(long s) { return syscall2(119, s, 8); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0x800); }
static long send_(long s, const char *b, int n) { return write((int)s, b, n); }
static long recv_(long s, char *b, int n) { return read((int)s, b, n); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET; (a)[1] = 0; } while (0)
#endif

#define PORT 18898
#define CPORT 18899
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello346:   ok   " : "hello346:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk(unsigned char *s, int d, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[4] = 127; s[7] = (unsigned char)d;
}
/* Accept from `l` for up to 10 s (a handshake frame lost on the loopback queue waits a 2 s RTO). */
static long accept_wait(long l) {
    long a = -11;
    for (int t = 0; t < 10000 && a < 0; t += 10) {
        a = accept_(l);
        if (a < 0) pump();
    }
    return a;
}
/* Read up to 3 bytes from the non-blocking accepted socket `s` within 10 s; returns 1 when they equal `want`. */
static int got(long s, const char *want) {
    char b[4] = { 0, 0, 0, 0 };
    int n = 0;
    for (int t = 0; t < 10000 && n < 3 && s >= 0; t += 10) {
        long r = recv_(s, b + n, 3 - n);
        if (r > 0) n += (int)r;
        else if (r == 0) break;
        else pump();
    }
    return n == 3 && memcmp(b, want, 3) == 0;
}
/* A client bound to 127.0.0.<d>:CPORT (SO_REUSEADDR) connected to `to`; *conn gets the connect result. */
static long client(int d, const unsigned char *to, long *conn) {
    unsigned char me[16];
    mk(me, d, CPORT);
    long c = sock();
    reuse(c);
    long b = bind_(c, me);
    *conn = b == 0 ? connect_(c, to) : b;
    return c;
}
int main(void) {
    print("hello346: TCP connections that differ only in a local address are different connections\n");
    signal(SIGPIPE, SIG_IGN); /* a send on a connection the kernel mixed up fails as EPIPE instead of killing the test */
    unsigned char s1[16], s2[16];
    mk(s1, 1, PORT); mk(s2, 2, PORT);

    long l1 = sock(), l2 = sock();
    long b1 = bind_(l1, s1), b2 = bind_(l2, s2);
    long li1 = listen_(l1), li2 = listen_(l2);
    snprintf(msg, sizeof msg, "A: listeners on 127.0.0.1:%d and 127.0.0.2:%d: bind %ld %ld, listen %ld %ld", PORT, PORT, b1, b2, li1, li2);
    check(b1 == 0 && b2 == 0 && li1 == 0 && li2 == 0, msg);

    long r1 = -1, r2 = -1;
    long c1 = client(5, s1, &r1);
    long c2 = client(5, s2, &r2);
    long a1 = accept_wait(l1), a2 = accept_wait(l2);
    long w1 = send_(c1, "one", 3), w2 = send_(c2, "two", 3);
    int g1 = got(a1, "one"), g2 = got(a2, "two");
    snprintf(msg, sizeof msg, "B: two clients bound to 127.0.0.5:%d connect %ld %ld, accepted %ld %ld, send %ld %ld, each server got its own bytes %d %d",
             CPORT, r1, r2, a1, a2, w1, w2, g1, g2);
    check(r1 == 0 && r2 == 0 && a1 >= 0 && a2 >= 0 && w1 == 3 && w2 == 3 && g1 && g2, msg);

    long r3 = -1;
    long c3 = client(6, s1, &r3);
    long a3 = accept_wait(l1);
    long w3 = send_(c3, "six", 3);
    int g3 = got(a3, "six");
    int g1b = 0;
    long w1b = send_(c1, "uno", 3);
    g1b = got(a1, "uno");
    snprintf(msg, sizeof msg, "C: a client bound to 127.0.0.6:%d connects to 127.0.0.1 (%ld), accepted %ld, its bytes arrive (%d); the first connection still works (%ld, %d)",
             CPORT, r3, a3, g3, w1b, g1b);
    check(r3 == 0 && a3 >= 0 && w3 == 3 && g3 && w1b == 3 && g1b, msg);

    long r4 = -1;
    long c4 = client(5, s1, &r4);
    snprintf(msg, sizeof msg, "D: a fourth client with the exact 4-tuple of the first (127.0.0.5:%d -> 127.0.0.1:%d) connects %ld", CPORT, PORT, r4);
    check(r4 == -99, msg);

    close_(c4);
    if (a3 >= 0) close_(a3);
    close_(c3);
    if (a1 >= 0) close_(a1);
    if (a2 >= 0) close_(a2);
    close_(c1);
    close_(c2);
    close_(l1);
    close_(l2);
    print(failures ? "hello346: FAIL\n" : "hello346: PASS\n");
    return failures ? 1 : 0;
}
