/* hello345: a TCP socket keeps the IPv4 address it was bound to (Linux inet_bind sets inet_rcv_saddr). Two sockets may bind different
 * addresses on one port, a SYN goes to the listener bound to its destination address, and getsockname reports the bound address.
 * Measured on the host (build with -DHOST):
 *   A. bind 127.0.0.1:18897 and 127.0.0.2:18897 both succeed;
 *   B. a third socket binding 0.0.0.0:18897 or 127.0.0.2:18897 is EADDRINUSE (98);
 *   C. getsockname on the listeners gives 127.0.0.1 and 127.0.0.2, and on a socket bound to 0.0.0.0:18898 gives 0.0.0.0;
 *   D. a connect to 127.0.0.2 is accepted by that listener and one to 127.0.0.1 by the other; the accepted sockets name the address
 *      that was connected to, the unbound client's own name is 127.0.0.1 (the loopback route's source address) and is the accepted
 *      socket's peer, and neither listener gets a second connection;
 *   E. a connect to 127.0.0.3:18897, where nobody listens, is refused (111);
 *   F. a client bound to 127.0.0.5 that connects to 127.0.0.1 has 127.0.0.5 as its own name and as the accepted socket's peer. */
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
static long sock(int type) { return rc(socket(AF_INET, type, 0)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 16)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long listen_(long s) { return rc(listen((int)s, 8)); }
static long accept_(long s) { return rc(accept4((int)s, 0, 0, SOCK_NONBLOCK)); }
static long name_(long s, unsigned char *a, int peer) {
    socklen_t l = 16;
    return rc(peer ? getpeername((int)s, (void *)a, &l) : getsockname((int)s, (void *)a, &l));
}
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define SOCK_NONBLOCK 0x800
#define SOCK_STREAM 1
#define AF_INET 2
static long sock(int type) { return syscall3(117, AF_INET, type, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long listen_(long s) { return syscall2(119, s, 8); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0x800); }
static long name_(long s, unsigned char *a, int peer) { int l = 16; return syscall3(peer ? 127 : 126, s, (long)a, (long)&l); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET; (a)[1] = 0; } while (0)
#endif

#define PORT 18897
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello345:   ok   " : "hello345:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* sockaddr_in for a.b.c.d:port */
static void mk(unsigned char *s, int a, int b, int c, int d, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[4] = (unsigned char)a; s[5] = (unsigned char)b; s[6] = (unsigned char)c; s[7] = (unsigned char)d;
}
static int port_of(const unsigned char *s) { return (s[2] << 8) | s[3]; }
static int host_is(const unsigned char *s, int a, int b, int c, int d) { return s[4] == a && s[5] == b && s[6] == c && s[7] == d; }
/* Accept from `l` for up to 10 s (a handshake frame lost on the loopback queue waits a 2 s RTO). */
static long accept_wait(long l) {
    long a = -11;
    for (int t = 0; t < 10000 && a < 0; t += 10) {
        a = accept_(l);
        if (a < 0) pump();
    }
    return a;
}
int main(void) {
    print("hello345: a TCP socket keeps the IPv4 address it was bound to\n");
    unsigned char a1[16], a2[16], a3[16], any[16], any2[16], a5[16], nm[16];
    mk(a1, 127, 0, 0, 1, PORT); mk(a2, 127, 0, 0, 2, PORT); mk(a3, 127, 0, 0, 3, PORT);
    mk(any, 0, 0, 0, 0, PORT); mk(any2, 0, 0, 0, 0, PORT + 1); mk(a5, 127, 0, 0, 5, 0);

    long l1 = sock(SOCK_STREAM | SOCK_NONBLOCK), l2 = sock(SOCK_STREAM | SOCK_NONBLOCK);
    long b1 = bind_(l1, a1), b2 = bind_(l2, a2);
    long li1 = listen_(l1), li2 = listen_(l2);
    snprintf(msg, sizeof msg, "A: bind 127.0.0.1:%d returns %ld, bind 127.0.0.2:%d returns %ld; listen %ld %ld", PORT, b1, PORT, b2, li1, li2);
    check(b1 == 0 && b2 == 0 && li1 == 0 && li2 == 0, msg);

    long x = sock(SOCK_STREAM), y = sock(SOCK_STREAM);
    long xb = bind_(x, any), yb = bind_(y, a2);
    snprintf(msg, sizeof msg, "B: a third socket binding 0.0.0.0:%d returns %ld, 127.0.0.2:%d returns %ld", PORT, xb, PORT, yb);
    check(xb == -98 && yb == -98, msg);
    close_(x);
    close_(y);

    long w = sock(SOCK_STREAM);
    bind_(w, any2);
    long n1 = name_(l1, nm, 0);
    int ok1 = n1 == 0 && host_is(nm, 127, 0, 0, 1) && port_of(nm) == PORT;
    long n2 = name_(l2, nm, 0);
    int ok2 = n2 == 0 && host_is(nm, 127, 0, 0, 2) && port_of(nm) == PORT;
    long nw = name_(w, nm, 0);
    int okw = nw == 0 && host_is(nm, 0, 0, 0, 0) && port_of(nm) == PORT + 1;
    snprintf(msg, sizeof msg, "C: getsockname gives 127.0.0.1 (%d), 127.0.0.2 (%d), and 0.0.0.0 for a wildcard bind (%d, %d.%d.%d.%d)", ok1, ok2, okw,
             nm[4], nm[5], nm[6], nm[7]);
    check(ok1 && ok2 && okw, msg);
    close_(w);

    long c2 = sock(SOCK_STREAM), c1 = sock(SOCK_STREAM);
    long r2 = connect_(c2, a2), r1 = connect_(c1, a1);
    long s2 = accept_wait(l2), s1 = accept_wait(l1);
    long extra1 = -11, extra2 = -11;
    for (int t = 0; t < 200; t += 10) {
        if (extra1 < 0) extra1 = accept_(l1);
        if (extra2 < 0) extra2 = accept_(l2);
        pump();
    }
    int named2 = 0, named1 = 0, peer_ok = 0;
    unsigned char cn[16];
    if (s2 >= 0 && name_(s2, nm, 0) == 0) named2 = host_is(nm, 127, 0, 0, 2) && port_of(nm) == PORT;
    if (s1 >= 0 && name_(s1, nm, 0) == 0) named1 = host_is(nm, 127, 0, 0, 1) && port_of(nm) == PORT;
    if (s2 >= 0 && name_(s2, nm, 1) == 0 && name_(c2, cn, 0) == 0) peer_ok = port_of(nm) == port_of(cn) && host_is(cn, 127, 0, 0, 1) && host_is(nm, 127, 0, 0, 1);
    snprintf(msg, sizeof msg, "D: connects %ld %ld; 127.0.0.2 accepted %ld (named %d), 127.0.0.1 accepted %ld (named %d); peer %d; extra %ld %ld", r2, r1, s2,
             named2, s1, named1, peer_ok, extra1, extra2);
    check(r2 == 0 && r1 == 0 && s2 >= 0 && s1 >= 0 && named2 && named1 && peer_ok && extra1 < 0 && extra2 < 0, msg);

    long c3 = sock(SOCK_STREAM);
    long r3 = connect_(c3, a3);
    snprintf(msg, sizeof msg, "E: a connect to 127.0.0.3:%d, where nobody listens, returns %ld", PORT, r3);
    check(r3 == -111, msg);
    close_(c3);

    long c5 = sock(SOCK_STREAM);
    long b5 = bind_(c5, a5);
    long r5 = connect_(c5, a1);
    long s5 = accept_wait(l1);
    int own5 = 0, peer5 = 0;
    if (name_(c5, nm, 0) == 0) own5 = host_is(nm, 127, 0, 0, 5) && port_of(nm) != 0;
    if (s5 >= 0 && name_(s5, cn, 1) == 0) peer5 = host_is(cn, 127, 0, 0, 5) && port_of(cn) == port_of(nm);
    snprintf(msg, sizeof msg, "F: a client bound to 127.0.0.5 (%ld) connects (%ld), accepted %ld; its name is 127.0.0.5 (%d) and so is the peer (%d)", b5, r5,
             s5, own5, peer5);
    check(b5 == 0 && r5 == 0 && s5 >= 0 && own5 && peer5, msg);

    if (s5 >= 0) close_(s5);
    close_(c5);
    if (s1 >= 0) close_(s1);
    if (s2 >= 0) close_(s2);
    if (extra1 >= 0) close_(extra1);
    if (extra2 >= 0) close_(extra2);
    close_(c1);
    close_(c2);
    close_(l1);
    close_(l2);
    print(failures ? "hello345: FAIL\n" : "hello345: PASS\n");
    return failures ? 1 : 0;
}
