/* hello443: TCP urgent data (Linux net/ipv4/tcp.c tcp_recv_urg / tcp_recvmsg_locked / tcp_poll, tcp_input.c tcp_check_urg /
 * tcp_urg, tcp_output.c snd_up). send(MSG_OOB) marks the last byte it writes urgent; the receiver keeps the byte at the mark:
 * normal reads stop in front of it and step over it, recv(MSG_OOB) returns it once (EINVAL after, and with SO_OOBINLINE), never
 * blocks (EAGAIN); poll reports POLLPRI and select the exceptfds bit while it is unread; SIOCATMARK says whether the next byte read
 * is the urgent one; FIONREAD counts only up to the mark; the F_SETOWN owner gets SIGURG. UDP send(MSG_OOB) is EOPNOTSUPP. The
 * kernel used to ignore MSG_OOB on send, reject it on recvmsg, write a zero urgent pointer and always clear exceptfds.
 * Measured on the host (build with -DHOST, run in `unshare -n` with lo up):
 *   A. send("abc", MSG_OOB) -> 3; the owner got one SIGURG; poll(POLLIN|POLLPRI) -> 0x3; select: read and except set; SIOCATMARK 0;
 *      FIONREAD 2;
 *   B. recv(MSG_OOB|MSG_PEEK) -> 1 'c'; recv(MSG_OOB) -> 1 'c'; again -> EINVAL; recv -> 2 "ab"; SIOCATMARK 1, except clear;
 *   C. "de" sent after the mark: recv -> 2 "de"; nothing more: MSG_DONTWAIT -> EAGAIN; recv(MSG_OOB|MSG_DONTWAIT) -> EINVAL;
 *   D. "ab", "c" MSG_OOB, "de": a read of 16 -> 2 "ab"; FIONREAD 0 and SIOCATMARK 1 at the mark; recv(MSG_OOB) 'c'; then "de";
 *   E. SO_OOBINLINE: "xyz" MSG_OOB -> poll 0x3, recv(MSG_OOB) EINVAL, recv -> "xy" (stops at the mark), SIOCATMARK 1, recv "z";
 *   F. UDP sendto(MSG_OOB) -> EOPNOTSUPP; SIOCATMARK on a pipe -> ENOTTY. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, int fl, const void *a, int al) { return rc(sendto((int)s, b, n, fl, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n, int fl) { return rc(recv((int)s, b, n, fl)); }
static long ioctl_(long fd, unsigned long req, void *arg) { return rc(ioctl((int)fd, req, arg)); }
static long poll1(long fd, int ev) { struct pollfd p = { (int)fd, (short)ev, 0 }; long r = poll(&p, 1, 0); return r < 0 ? -errno : p.revents; }
static long select1(long fd, int *r, int *e) {
    fd_set rs, es;
    FD_ZERO(&rs);
    FD_ZERO(&es);
    FD_SET((int)fd, &rs);
    FD_SET((int)fd, &es);
    struct timeval tv = { 0, 0 };
    long n = select((int)fd + 1, &rs, 0, &es, &tv);
    *r = FD_ISSET((int)fd, &rs) != 0;
    *e = FD_ISSET((int)fd, &es) != 0;
    return n < 0 ? -errno : n;
}
static long setown(long fd, long pid) { return rc(fcntl((int)fd, F_SETOWN, (int)pid)); }
static long me(void) { return getpid(); }
static void pause_ms(long ms) { struct timespec t = { 0, ms * 1000000 }; nanosleep(&t, 0); }
static void on_sig(int s, void (*h)(int)) { signal(s, h); }
static long pipe_(int *p) { return pipe(p); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long sendto_(long s, const void *b, long n, int fl, const void *a, int al) { return syscall6(44, s, (long)b, n, fl, (long)a, al); }
static long recv_(long s, void *b, long n, int fl) { return syscall6(45, s, (long)b, n, fl, 0, 0); }
static long ioctl_(long fd, unsigned long req, void *arg) { return syscall3(SYS_ioctl, fd, (long)req, (long)arg); }
static long poll1(long fd, int ev) { struct { int fd; short ev, rev; } p = { (int)fd, (short)ev, 0 }; long r = syscall3(SYS_poll, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static long select1(long fd, int *r, int *e) {
    unsigned char rs[16], es[16];
    memset(rs, 0, 16);
    memset(es, 0, 16);
    rs[fd / 8] |= (unsigned char)(1 << (fd % 8));
    es[fd / 8] |= (unsigned char)(1 << (fd % 8));
    long tv[2] = { 0, 0 };
    long n = syscall5(SYS_select, fd + 1, (long)rs, 0, (long)es, (long)tv);
    *r = (rs[fd / 8] >> (fd % 8)) & 1;
    *e = (es[fd / 8] >> (fd % 8)) & 1;
    return n;
}
static long setown(long fd, long pid) { return syscall3(SYS_fcntl, fd, 8, pid); }
static long me(void) { return getpid(); }
static void pause_ms(long ms) { long t[2] = { 0, ms * 1000000 }; syscall2(SYS_nanosleep, (long)t, 0); }
static void on_sig(int s, void (*h)(int)) { signal(s, h); }
static long pipe_(int *p) { return pipe(p); }
static void close_(long s) { syscall1(SYS_close, s); }
#endif
static int failures;
static char msg[600];
static volatile int urg_count;
static void on_urg(int s) { (void)s; urg_count++; }
static void check(int ok, const char *w) {
    print(ok ? "hello443:   ok   " : "hello443:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static int pair(int port, long *c, long *s) {
    unsigned char a[16];
    mk4(a, port);
    int one = 1;
    long l = sock(2, 1, 0);
    setopt(l, 1, 2, &one, 4);
    if (bind_(l, a, 16) != 0 || listen_(l, 4) != 0) return -1;
    *c = sock(2, 1, 0);
    if (connect_(*c, a, 16) != 0) return -1;
    *s = accept_(l);
    close_(l);
    setopt(*c, 6, 1, &one, 4); /* TCP_NODELAY: each send is its own segment */
    return *s >= 0 ? 0 : -1;
}
int main(void) {
    print("hello443: TCP urgent data (MSG_OOB, POLLPRI, exceptfds, SIOCATMARK, SIGURG)\n");
    long c, s;
    if (pair(47431, &c, &s) != 0) {
        check(0, "setup: connected pair");
        print("hello443: FAIL\n");
        return 1;
    }
    on_sig(23, on_urg);
    long so = setown(s, me());
    long r = sendto_(c, "abc", 3, 1, 0, 0);
    pause_ms(50);
    int rd = 0, ex = 0, at = -1, nread = -1;
    long ev = poll1(s, 1 | 2);
    long sel = select1(s, &rd, &ex);
    long am = ioctl_(s, 0x8905, &at);
    long fr = ioctl_(s, 0x541B, &nread);
    snprintf(msg, sizeof msg, "A: setown %ld, send oob %ld, sigurg %d, poll 0x%lx, select %ld r %d e %d, atmark %ld/%d, fionread %ld/%d "
             "(0, 3, 1, 0x3, 2 1 1, 0/0, 0/2)", so, r, urg_count, ev, sel, rd, ex, am, at, fr, nread);
    check(so == 0 && r == 3 && urg_count == 1 && ev == 3 && sel == 2 && rd == 1 && ex == 1 && am == 0 && at == 0 && fr == 0 && nread == 2, msg);

    char b[16];
    memset(b, 0, sizeof b);
    long pk = recv_(s, b, 1, 1 | 2);
    char pc = b[0];
    memset(b, 0, sizeof b);
    long o1 = recv_(s, b, 8, 1);
    char oc = b[0];
    long o2 = recv_(s, b, 8, 1);
    memset(b, 0, sizeof b);
    long n1 = recv_(s, b, 16, 0x40);
    int ab = memcmp(b, "ab", 2) == 0;
    ioctl_(s, 0x8905, &at);
    sel = select1(s, &rd, &ex);
    snprintf(msg, sizeof msg, "B: peek oob %ld '%c', oob %ld '%c', again %ld, recv %ld ab %d, atmark %d, except %d (1 c, 1 c, -22, 2 1, 1, 0)",
             pk, pc, o1, oc, o2, n1, ab, at, ex);
    check(pk == 1 && pc == 'c' && o1 == 1 && oc == 'c' && o2 == -22 && n1 == 2 && ab && at == 1 && ex == 0, msg);

    sendto_(c, "de", 2, 0, 0, 0);
    pause_ms(50);
    memset(b, 0, sizeof b);
    long n2 = recv_(s, b, 16, 0x40);
    int de = memcmp(b, "de", 2) == 0;
    long n3 = recv_(s, b, 16, 0x40);
    long o3 = recv_(s, b, 1, 1 | 0x40);
    snprintf(msg, sizeof msg, "C: recv %ld de %d, empty %ld, oob %ld (2 1, -11, -22)", n2, de, n3, o3);
    check(n2 == 2 && de && n3 == -11 && o3 == -22, msg);

    sendto_(c, "ab", 2, 0, 0, 0);
    sendto_(c, "c", 1, 1, 0, 0);
    sendto_(c, "de", 2, 0, 0, 0);
    pause_ms(50);
    memset(b, 0, sizeof b);
    long d1 = recv_(s, b, 16, 0x40);
    int dab = memcmp(b, "ab", 2) == 0;
    nread = -1;
    at = -1;
    ioctl_(s, 0x541B, &nread);
    ioctl_(s, 0x8905, &at);
    memset(b, 0, sizeof b);
    long d2 = recv_(s, b, 1, 1);
    char dc = b[0];
    memset(b, 0, sizeof b);
    long d3 = recv_(s, b, 16, 0x40);
    int dde = memcmp(b, "de", 2) == 0;
    snprintf(msg, sizeof msg, "D: recv %ld ab %d, fionread %d, atmark %d, oob %ld '%c', recv %ld de %d (2 1, 0, 1, 1 c, 2 1)", d1, dab, nread, at, d2,
             dc, d3, dde);
    check(d1 == 2 && dab && nread == 0 && at == 1 && d2 == 1 && dc == 'c' && d3 == 2 && dde, msg);

    long c2, s2;
    int one = 1;
    if (pair(47432, &c2, &s2) != 0) {
        check(0, "E: second pair");
    } else {
        long si = setopt(s2, 1, 10, &one, 4);
        sendto_(c2, "xyz", 3, 1, 0, 0);
        pause_ms(50);
        long iev = poll1(s2, 1 | 2);
        long io = recv_(s2, b, 1, 1);
        memset(b, 0, sizeof b);
        long i1 = recv_(s2, b, 16, 0x40);
        int xy = memcmp(b, "xy", 2) == 0;
        at = -1;
        ioctl_(s2, 0x8905, &at);
        memset(b, 0, sizeof b);
        long i2 = recv_(s2, b, 16, 0x40);
        snprintf(msg, sizeof msg, "E: oobinline %ld, poll 0x%lx, oob %ld, recv %ld xy %d, atmark %d, recv %ld '%c' (0, 0x3, -22, 2 1, 1, 1 z)", si, iev,
                 io, i1, xy, at, i2, b[0]);
        check(si == 0 && iev == 3 && io == -22 && i1 == 2 && xy && at == 1 && i2 == 1 && b[0] == 'z', msg);
    }

    unsigned char ua[16];
    mk4(ua, 47433);
    long u = sock(2, 2, 0);
    long uo = sendto_(u, "x", 1, 1, ua, 16);
    int pf[2];
    pipe_(pf);
    long pa = ioctl_(pf[0], 0x8905, &at);
    snprintf(msg, sizeof msg, "F: udp send oob %ld, pipe atmark %ld (-95, -25)", uo, pa);
    check(uo == -95 && pa == -25, msg);

    print(failures ? "hello443: FAIL\n" : "hello443: PASS\n");
    return failures ? 1 : 0;
}
