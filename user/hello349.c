/* hello349: an IPv6 UDP socket keeps the address it was bound to (Linux inet6_bind sets sk_v6_rcv_saddr). Measured on the host
 * (build with -DHOST):
 *   A. getsockname on a socket bound to [::1]:18905 gives ::1 port 18905;
 *   B. getsockname on a socket bound to [::]:18906 gives :: port 18906;
 *   C. an unbound socket that has not sent anything names ::;
 *   D. a datagram from the socket on [::1]:18905 to [::1]:18906 arrives with source [::1]:18905. */
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
static long sock(void) { return rc(socket(AF_INET6, SOCK_DGRAM, 0)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
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
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 28; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello349:   ok   " : "hello349:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* sockaddr_in6 for :: (loop 0) or ::1 (loop 1) on `port`. */
static void mk(unsigned char *s, int loop, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[23] = (unsigned char)loop;
}
static int port_of(const unsigned char *s) { return (s[2] << 8) | s[3]; }
/* 1 for ::1, 0 for ::, -1 for anything else. */
static int addr_kind(const unsigned char *s) {
    for (int i = 8; i < 23; i++) if (s[i]) return -1;
    return s[23] == 1 ? 1 : s[23] == 0 ? 0 : -1;
}
static long recv_wait(long s, char *b, int n, unsigned char *from) {
    long r = -11;
    for (int t = 0; t < 5000 && r == -11; t += 10) {
        r = recvfrom_(s, b, n, from);
        if (r == -11) pump();
    }
    return r;
}

int main(void) {
    print("hello349: an IPv6 UDP socket keeps the address it was bound to\n");
    unsigned char l5[28], any6[28], to6[28], nm[28], from[28];
    mk(l5, 1, 18905); mk(any6, 0, 18906); mk(to6, 1, 18906);

    long u5 = sock(), u6 = sock();
    long b5 = bind_(u5, l5), b6 = bind_(u6, any6);
    for (int i = 0; i < 28; i++) nm[i] = 0xEE;
    long g5 = name_(u5, nm);
    int k5 = addr_kind(nm), p5 = port_of(nm);
    snprintf(msg, sizeof msg, "A: bind [::1]:18905 %ld; getsockname %ld names %s port %d (want ::1 port 18905)", b5, g5,
             k5 == 1 ? "::1" : k5 == 0 ? "::" : "another address", p5);
    check(b5 == 0 && g5 == 0 && k5 == 1 && p5 == 18905, msg);

    for (int i = 0; i < 28; i++) nm[i] = 0xEE;
    long g6 = name_(u6, nm);
    int k6 = addr_kind(nm), p6 = port_of(nm);
    snprintf(msg, sizeof msg, "B: bind [::]:18906 %ld; getsockname %ld names %s port %d (want :: port 18906)", b6, g6,
             k6 == 1 ? "::1" : k6 == 0 ? "::" : "another address", p6);
    check(b6 == 0 && g6 == 0 && k6 == 0 && p6 == 18906, msg);

    long un = sock();
    for (int i = 0; i < 28; i++) nm[i] = 0xEE;
    long gn = name_(un, nm);
    int kn = addr_kind(nm);
    snprintf(msg, sizeof msg, "C: an unbound socket (getsockname %ld) names %s (want ::)", gn, kn == 1 ? "::1" : kn == 0 ? "::" : "another address");
    check(gn == 0 && kn == 0, msg);

    long s5 = sendto_(u5, "six", 3, to6);
    char buf[8];
    long r5 = recv_wait(u6, buf, sizeof buf, from);
    int kf = addr_kind(from), pf = port_of(from);
    snprintf(msg, sizeof msg, "D: from [::1]:18905 (send %ld) the datagram arrives (%ld) with source %s port %d (want ::1 port 18905)", s5, r5,
             kf == 1 ? "::1" : kf == 0 ? "::" : "another address", pf);
    check(s5 == 3 && r5 == 3 && kf == 1 && pf == 18905, msg);

    close_(un);
    close_(u6);
    close_(u5);
    print(failures ? "hello349: FAIL\n" : "hello349: PASS\n");
    return failures ? 1 : 0;
}
