/* hello357: an IPv6 UDP socket's bound address takes part in port conflicts and in choosing the receiver (Linux
 * udp_lib_lport_inuse compares sk_v6_rcv_saddr, udp6_lib_lookup2 scores an exact local address above the wildcard). Measured on
 * the host (build with -DHOST; every socket IPV6_V6ONLY):
 *   A. [::1]:18971 and [ff0e::1]:18971 both bind; [::]:18971 and a second [::1]:18971 are EADDRINUSE;
 *   B. with SO_REUSEADDR, [::1]:18972 bound first and [::]:18972 second: 5 datagrams to [::1]:18972 all reach the ::1 socket;
 *   C. the same with [::]:18973 bound first and [::1]:18973 second: all 5 reach the ::1 socket;
 *   D. a datagram to [::1]:18974 is not taken by the only socket on that port, bound to [ff0e::1]:18974. */
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
static long sock(void) {
    long s = rc(socket(AF_INET6, SOCK_DGRAM, 0));
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long reuse(long s) { int one = 1; return rc(setsockopt((int)s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) {
    socklen_t l = 28;
    return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l));
}
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
static long sock(void) { return syscall3(117, AF_INET6, 2, 0); }
static long reuse(long s) { int one = 1; return syscall5(132, s, 1, 2, (long)&one, 4); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 28; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello357:   ok   " : "hello357:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* sockaddr_in6 on `port` for :: (kind 0), ::1 (kind 1) or ff0e::1 (kind 2). */
static void mk(unsigned char *s, int kind, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (kind == 2) { s[8] = 0xff; s[9] = 0x0e; }
    if (kind != 0) s[23] = 1;
}
static long bindk(long s, int kind, int port) { unsigned char a[28]; mk(a, kind, port); return bind_(s, a); }
static int drain(long s) {
    char b[8];
    unsigned char from[28];
    int n = 0;
    while (recvfrom_(s, b, sizeof b, from) == 1) n++;
    return n;
}
/* Send 5 one-byte datagrams to [::1]:port from `tx`, give them time to arrive. */
static void send5(long tx, int port) {
    unsigned char to[28];
    mk(to, 1, port);
    for (int i = 0; i < 5; i++) sendto_(tx, "x", 1, to);
    for (int i = 0; i < 5; i++) pump();
}

int main(void) {
    print("hello357: an IPv6 UDP socket's bound address takes part in port conflicts and receiver choice\n");
    long a = sock(), b = sock(), c = sock(), d = sock();
    long ra = bindk(a, 1, 18971), rb = bindk(b, 2, 18971), rc_ = bindk(c, 0, 18971), rd = bindk(d, 1, 18971);
    snprintf(msg, sizeof msg, "A: [::1] and [ff0e::1] share port 18971 (%ld, %ld); [::] and a second [::1] are EADDRINUSE (%ld, %ld)",
             ra, rb, rc_, rd);
    check(ra == 0 && rb == 0 && rc_ == -98 && rd == -98, msg);
    close_(a); close_(b); close_(c); close_(d);

    long tx = sock();
    long e = sock(), f = sock();
    reuse(e); reuse(f);
    long re = bindk(e, 1, 18972), rf = bindk(f, 0, 18972);
    send5(tx, 18972);
    int ne = drain(e), nf = drain(f);
    snprintf(msg, sizeof msg, "B: [::1] bound before [::]: the ::1 socket takes all 5 datagrams to ::1 (bind %ld %ld, ::1 got %d, :: got %d)",
             re, rf, ne, nf);
    check(re == 0 && rf == 0 && ne == 5 && nf == 0, msg);
    close_(e); close_(f);

    long g = sock(), h = sock();
    reuse(g); reuse(h);
    long rg = bindk(g, 0, 18973), rh = bindk(h, 1, 18973);
    send5(tx, 18973);
    int ng = drain(g), nh = drain(h);
    snprintf(msg, sizeof msg, "C: [::] bound before [::1]: the ::1 socket takes all 5 (bind %ld %ld, :: got %d, ::1 got %d)", rg, rh, ng, nh);
    check(rg == 0 && rh == 0 && ng == 0 && nh == 5, msg);
    close_(g); close_(h);

    long m = sock();
    long rm = bindk(m, 2, 18974);
    send5(tx, 18974);
    int nm = drain(m);
    snprintf(msg, sizeof msg, "D: a socket bound to [ff0e::1] does not take datagrams to ::1 (bind %ld, got %d)", rm, nm);
    check(rm == 0 && nm == 0, msg);
    close_(m);
    close_(tx);

    print(failures ? "hello357: FAIL\n" : "hello357: PASS\n");
    return failures ? 1 : 0;
}
