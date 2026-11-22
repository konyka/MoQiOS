/* hello493: /proc/sys/net/ipv4/ip_local_port_range controls UDP/TCP automatic ports.
 * A saves the original value; B installs 52000..52010 and checks an unconfigured UDP socket;
 * C checks that a socket IP_LOCAL_PORT_RANGE narrows it to 52004..52006; D does the system-range
 * check for a TCP client; E rejects inverted, privileged and out-of-range writes without changing
 * the value; F restores the original text. Measured with -DHOST in a new netns with lo up. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long name_(long s, void *a) { socklen_t l = 16; return rc(getsockname((int)s, a, &l)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long read_(long fd, void *b, int n) { return rc(read((int)fd, b, (size_t)n)); }
static long write_(long fd, const void *b, int n) { return rc(write((int)fd, b, (size_t)n)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long name_(long s, void *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr, 0); }
static long read_(long fd, void *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const void *b, int n) { return syscall3(1, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
static const char path[] = "/proc/sys/net/ipv4/ip_local_port_range";
static int failures;
static char msg[500];
static char saved[64];
static void check(int ok, const char *w) {
    print(ok ? "hello493:   ok   " : "hello493:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long write_text(const char *s) {
    long fd = open_(path, 1);
    if (fd < 0) return fd;
    long r = write_(fd, s, (int)strlen(s));
    close_(fd);
    return r;
}
static long read_text(char *out, int cap) {
    long fd = open_(path, 0);
    if (fd < 0) return fd;
    long n = read_(fd, out, cap - 1);
    close_(fd);
    if (n >= 0) out[n] = 0;
    return n;
}
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127; a[7] = 1;
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
static long range(long s, int lo, int hi) {
    unsigned int r = (unsigned int)lo | ((unsigned int)hi << 16);
    return setopt_(s, 0, 51, &r, 4);
}
int main(void) {
    print("hello493: ip_local_port_range sysctl\n");
    long ar = read_text(saved, sizeof saved);
#ifdef HOST
    int default_ok = ar > 0;
#else
    int default_ok = ar > 0 && strcmp(saved, "49152\t65535\n") == 0;
#endif
    snprintf(msg, sizeof msg, "A: read %ld, original '%s'", ar, saved);
    check(default_ok, msg);
    long wr = write_text("52000 52010\n");
    char now[64];
    long rr = read_text(now, sizeof now);
    snprintf(msg, sizeof msg, "B: write %ld, read %ld '%s' (12, '52000 52010')", wr, rr, now);
    check(wr == 12 && rr > 0 && strcmp(now, "52000\t52010\n") == 0, msg);

    unsigned char dst[16], local[16];
    mk4(dst, 52120);
    long ur = sock(2, 2, 0);
    long ub = bind_(ur, dst, 16);
    long us = sock(2, 2, 0);
    long sent = sendto_(us, "x", 1, dst, 16);
    long un = name_(us, local);
    int up = port_of(local);
    snprintf(msg, sizeof msg, "B: UDP bind peer %ld, send %ld, name %ld, port %d (0 1 0 52000..52010)", ub, sent, un, up);
    check(ub == 0 && sent == 1 && un == 0 && up >= 52000 && up <= 52010, msg);
    close_(us);

    long unarrow = sock(2, 2, 0);
    long urs = range(unarrow, 52004, 52006);
    long nsent = sendto_(unarrow, "x", 1, dst, 16);
    long nn = name_(unarrow, local);
    int np = port_of(local);
    snprintf(msg, sizeof msg, "C: socket range %ld, send %ld, name %ld, port %d (0 1 0 52004..52006)", urs, nsent, nn, np);
    check(urs == 0 && nsent == 1 && nn == 0 && np >= 52004 && np <= 52006, msg);
    close_(unarrow);
    close_(ur);

    mk4(dst, 52121);
    long tl = sock(2, 1, 0);
    long tb = bind_(tl, dst, 16), tli = listen_(tl, 4);
    long tc = sock(2, 1, 0);
    long cr = connect_(tc, dst, 16);
    long tn = name_(tc, local);
    int tp = port_of(local);
    long ta = cr == 0 ? accept_(tl) : -1000;
    snprintf(msg, sizeof msg, "D: TCP bind %ld listen %ld connect %ld name %ld port %d accept %ld (0 0 0 0 52000..52010 >=0)", tb, tli, cr, tn, tp, ta);
    check(tb == 0 && tli == 0 && cr == 0 && tn == 0 && tp >= 52000 && tp <= 52010 && ta >= 0, msg);
    close_(ta); close_(tc); close_(tl);

    long inv1 = write_text("52010 52000\n");
    long inv2 = write_text("1023 2000\n");
    long inv3 = write_text("65536 65535\n");
    rr = read_text(now, sizeof now);
    snprintf(msg, sizeof msg, "E: invalid %ld %ld %ld, read %ld '%s' (-22 -22 -22, unchanged)", inv1, inv2, inv3, rr, now);
    check(inv1 == -22 && inv2 == -22 && inv3 == -22 && rr > 0 && strcmp(now, "52000\t52010\n") == 0, msg);
    long restored = write_text(saved);
    snprintf(msg, sizeof msg, "F: restore %ld (%d)", restored, (int)strlen(saved));
    check(ar > 0 && restored == ar, msg);
    print(failures ? "hello493: FAIL\n" : "hello493: PASS\n");
    return failures ? 1 : 0;
}
