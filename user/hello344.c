/* hello344: an IPv4 and an IPv6 TCP socket may bind the same port (Linux inet_bind_conflict only compares sockets of the same family once
 * the IPv6 one is IPV6_V6ONLY, which every AF_INET6 socket here is). Each listener then gets the connections of its own family.
 * Measured on the host (build with -DHOST):
 *   A. setsockopt(IPV6_V6ONLY, 1) on the IPv6 socket succeeds;
 *   B. bind 0.0.0.0:18896 and [::]:18896 both succeed;
 *   C. both listen;
 *   D. a second socket of either family on the port is EADDRINUSE (98);
 *   E. a connect to 127.0.0.1:18896 is accepted by the IPv4 listener and one to [::1]:18896 by the IPv6 listener, one each. */
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
static long sock(int fam, int type) { return rc(socket(fam, type, 0)); }
static long v6only(long s) { int one = 1; return rc(setsockopt((int)s, 41, 26, &one, 4)); }
static long bind_(long s, const unsigned char *a, int n) { return rc(bind((int)s, (const void *)a, n)); }
static long connect_(long s, const unsigned char *a, int n) { return rc(connect((int)s, (const void *)a, n)); }
static long listen_(long s) { return rc(listen((int)s, 8)); }
static long accept_(long s) { return rc(accept4((int)s, 0, 0, SOCK_NONBLOCK)); }
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam = (f); memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define SOCK_NONBLOCK 0x800
#define SOCK_STREAM 1
#define AF_INET 2
#define AF_INET6 10
static long sock(int fam, int type) { return syscall3(117, fam, type, 0); }
static long v6only(long s) { int one = 1; return syscall5(132, s, 41, 26, (long)&one, 4); }
static long bind_(long s, const unsigned char *a, int n) { return syscall3(118, s, (long)a, n); }
static long connect_(long s, const unsigned char *a, int n) { return syscall3(124, s, (long)a, n); }
static long listen_(long s) { return syscall2(119, s, 8); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0x800); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif

#define PORT 18896
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello344:   ok   " : "hello344:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* any4 / loop4: sockaddr_in for 0.0.0.0 or 127.0.0.1; any6 / loop6: sockaddr_in6 for :: or ::1. */
static void mk4(unsigned char *a, int loop) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    FAM(a, AF_INET);
    a[2] = (unsigned char)(PORT >> 8); a[3] = (unsigned char)PORT;
    if (loop) { a[4] = 127; a[7] = 1; }
}
static void mk6(unsigned char *a, int loop) {
    for (int i = 0; i < 28; i++) a[i] = 0;
    FAM(a, AF_INET6);
    a[2] = (unsigned char)(PORT >> 8); a[3] = (unsigned char)PORT;
    if (loop) a[8 + 15] = 1;
}
/* /proc/lostats: whether the loopback queue refused frames while the connects were made (printed only when E fails). */
static void print_lostats(int with_tcp) {
#ifndef HOST
    char raw[160];
    long fd = syscall3(9, (long)"/proc/lostats", 0, 0);
    if (fd < 0) return;
    long n = syscall3(10, fd, (long)raw, sizeof raw - 1);
    close_(fd);
    if (n <= 0) return;
    if (raw[n - 1] == '\n') n--;
    raw[n] = 0;
    print("hello344:   .. lostats: ");
    print(raw);
    print("\n");
    if (!with_tcp) return;
    char tr[400];
    long tf = syscall3(9, (long)"/proc/tcpstats", 0, 0);
    if (tf < 0) return;
    long tn = syscall3(10, tf, (long)tr, sizeof tr - 1);
    close_(tf);
    if (tn <= 0) return;
    tr[tn] = 0;
    print("hello344:   .. tcpstats: ");
    print(tr);
#endif
}

int main(void) {
    print("hello344: an IPv4 and an IPv6 TCP socket may bind the same port\n");
    unsigned char any4[16], loop4[16], any6[28], loop6[28];
    mk4(any4, 0); mk4(loop4, 1); mk6(any6, 0); mk6(loop6, 1);

    long l4 = sock(AF_INET, SOCK_STREAM | SOCK_NONBLOCK);
    long l6 = sock(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK);
    long vo = v6only(l6);
    snprintf(msg, sizeof msg, "A: sockets %ld %ld; IPV6_V6ONLY 1 on the IPv6 one returns %ld", l4, l6, vo);
    check(l4 >= 0 && l6 >= 0 && vo == 0, msg);

    long b4 = bind_(l4, any4, 16);
    long b6 = bind_(l6, any6, 28);
    snprintf(msg, sizeof msg, "B: bind 0.0.0.0:%d returns %ld, bind [::]:%d returns %ld", PORT, b4, PORT, b6);
    check(b4 == 0 && b6 == 0, msg);

    long li4 = listen_(l4), li6 = listen_(l6);
    snprintf(msg, sizeof msg, "C: listen returns %ld (IPv4) and %ld (IPv6)", li4, li6);
    check(li4 == 0 && li6 == 0, msg);

    long x4 = sock(AF_INET, SOCK_STREAM), x6 = sock(AF_INET6, SOCK_STREAM);
    v6only(x6);
    long xb4 = bind_(x4, any4, 16), xb6 = bind_(x6, any6, 28);
    snprintf(msg, sizeof msg, "D: a second IPv4 bind returns %ld, a second IPv6 bind returns %ld", xb4, xb6);
    check(xb4 == -98 && xb6 == -98, msg);
    close_(x4);
    close_(x6);

    long c4 = sock(AF_INET, SOCK_STREAM | SOCK_NONBLOCK), c6 = sock(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK);
    long r4 = connect_(c4, loop4, 16), r6 = connect_(c6, loop6, 28);
    /* Accept from both listeners for up to 10 s (a handshake that loses a frame on the loopback queue waits a 2 s RTO), then 200 ms more
     * to see that neither listener gets a second connection. */
    long a4 = -11, a6 = -11, extra4 = -11, extra6 = -11;
    for (int t = 0; t < 10000 && (a4 < 0 || a6 < 0); t += 10) {
        if (a4 < 0) a4 = accept_(l4);
        if (a6 < 0) a6 = accept_(l6);
        if (a4 < 0 || a6 < 0) pump();
    }
    for (int t = 0; t < 200; t += 10) {
        if (extra4 < 0) extra4 = accept_(l4);
        if (extra6 < 0) extra6 = accept_(l6);
        pump();
    }
    snprintf(msg, sizeof msg, "E: connects %ld %ld; the IPv4 listener accepts %ld (then %ld), the IPv6 listener %ld (then %ld)", r4, r6, a4, extra4, a6, extra6);
    check((r4 == -115 || r4 == 0) && (r6 == -115 || r6 == 0) && a4 >= 0 && a6 >= 0 && extra4 < 0 && extra6 < 0, msg);
    if (failures) print_lostats(1);

    if (a4 >= 0) close_(a4);
    if (a6 >= 0) close_(a6);
    if (extra4 >= 0) close_(extra4);
    if (extra6 >= 0) close_(extra6);
    close_(c4);
    close_(c6);
    close_(l4);
    close_(l6);
    print(failures ? "hello344: FAIL\n" : "hello344: PASS\n");
    return failures ? 1 : 0;
}
