/* hello347: a UDP socket keeps the IPv4 address it was bound to (Linux inet_bind sets inet_rcv_saddr and inet_saddr). Measured on the
 * host (build with -DHOST):
 *   A. getsockname on a socket bound to 127.0.0.2:18900 gives 127.0.0.2, and on one bound to 0.0.0.0:18901 gives 0.0.0.0;
 *   B. a datagram from a socket bound to 127.0.0.5:18902 to 127.0.0.1:18901 arrives with source 127.0.0.5:18902;
 *   C. a datagram from an unbound socket to 127.0.0.2:18900 arrives with source 127.0.0.1 (the loopback route's source address);
 *   D. an unbound socket that has not sent anything names 0.0.0.0. */
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
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 16)); }
static long name_(long s, unsigned char *a) { socklen_t l = 16; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) {
    socklen_t l = 16;
    return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l));
}
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
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long name_(long s, unsigned char *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 16; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET; (a)[1] = 0; } while (0)
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello347:   ok   " : "hello347:   FAIL ");
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
static int port_of(const unsigned char *s) { return (s[2] << 8) | s[3]; }
static int host_is(const unsigned char *s, int a, int d) { return s[4] == a && s[5] == 0 && s[6] == 0 && s[7] == d; }
/* One datagram from `s` within 5 s; returns its length or a negative errno, with the source in `from`. */
static long recv_wait(long s, char *b, int n, unsigned char *from) {
    long r = -11;
    for (int t = 0; t < 5000 && r == -11; t += 10) {
        r = recvfrom_(s, b, n, from);
        if (r == -11) pump();
    }
    return r;
}

int main(void) {
    print("hello347: a UDP socket keeps the IPv4 address it was bound to\n");
    unsigned char a2[16], any1[16], a5[16], to1[16], nm[16], from[16];
    mk(a2, 127, 2, 18900); mk(any1, 0, 0, 18901); mk(a5, 127, 5, 18902); mk(to1, 127, 1, 18901);

    long u2 = sock(), u1 = sock();
    long b2 = bind_(u2, a2), b1 = bind_(u1, any1);
    int n2 = name_(u2, nm) == 0 && host_is(nm, 127, 2) && port_of(nm) == 18900;
    int n1 = name_(u1, nm) == 0 && host_is(nm, 0, 0) && port_of(nm) == 18901;
    snprintf(msg, sizeof msg, "A: bind 127.0.0.2:18900 %ld names 127.0.0.2 (%d); bind 0.0.0.0:18901 %ld names 0.0.0.0 (%d, %d.%d.%d.%d)", b2, n2, b1, n1,
             nm[4], nm[5], nm[6], nm[7]);
    check(b2 == 0 && b1 == 0 && n2 && n1, msg);

    long u5 = sock();
    long b5 = bind_(u5, a5);
    long s5 = sendto_(u5, "five", 4, to1);
    char buf[8];
    long r5 = recv_wait(u1, buf, sizeof buf, from);
    int src5 = r5 == 4 && host_is(from, 127, 5) && port_of(from) == 18902;
    snprintf(msg, sizeof msg, "B: from 127.0.0.5:18902 (bind %ld, send %ld) the datagram arrives (%ld) with source %d.%d.%d.%d:%d", b5, s5, r5, from[4], from[5],
             from[6], from[7], port_of(from));
    check(b5 == 0 && s5 == 4 && src5, msg);

    long un = sock();
    int unnamed = name_(un, nm) == 0 && host_is(nm, 0, 0);
    long sn = sendto_(un, "anon", 4, a2);
    long rn = recv_wait(u2, buf, sizeof buf, from);
    int srcn = rn == 4 && host_is(from, 127, 1);
    snprintf(msg, sizeof msg, "C: from an unbound socket (send %ld) the datagram to 127.0.0.2 arrives (%ld) with source %d.%d.%d.%d", sn, rn, from[4], from[5],
             from[6], from[7]);
    check(sn == 4 && srcn, msg);
    snprintf(msg, sizeof msg, "D: before sending, the unbound socket names 0.0.0.0 (%d)", unnamed);
    check(unnamed, msg);

    close_(un);
    close_(u5);
    close_(u1);
    close_(u2);
    print(failures ? "hello347: FAIL\n" : "hello347: PASS\n");
    return failures ? 1 : 0;
}
