/* hello393: an ICMPv6 error whose quoted packet carries extension headers still reaches the socket that sent it (Linux icmpv6_notify
 * skips them with ipv6_skip_exthdr before handing the inner header to __udp6_lib_err or ping_err). Errors are written through a raw
 * ICMPv6 socket to ::1, quoting a packet ::1 -> ::1. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with only lo up):
 *   H. port unreachable quoting hop-by-hop (8 bytes) then UDP sets ECONNREFUSED (111) on the UDP socket connected to [::1]:9;
 *   D. destination options (16 bytes) then routing (8 bytes) then UDP: 111;
 *   F. a first fragment (offset 0, more fragments) then UDP: 111;
 *   L. a later fragment (offset 8) has no UDP header to read: 0;
 *   N. "no next header" (59) after hop-by-hop: 0;
 *   T. a destination options header that claims more bytes than the quote holds: 0;
 *   P. AH (12 bytes) then an echo request on a connected IPv6 ping socket: 111;
 *   E. ESP (50) is not skipped, so a UDP header behind it is not found: 0.
 * The test sets net.ipv4.ping_group_range to "0 0" and puts the old value back at the end. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long rsock(void) { return rc(socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)); }
static long usock(void) { return rc(socket(AF_INET6, SOCK_DGRAM, 0)); }
static long psock(void) { return rc(socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recv_(long s, void *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long soerr(long s) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, SO_ERROR, &v, &l)); return r < 0 ? r : v; }
static long open_(const char *p, int fl) { return rc(open(p, fl)); }
static long read_(long fd, char *b, int n) { return rc(read((int)fd, b, n)); }
static long write_(long fd, const char *b, int n) { return rc(write((int)fd, b, n)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM6(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#define O_WR O_WRONLY
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock(void) { return syscall3(117, 10, 3, 58); }
static long usock(void) { return syscall3(117, 10, 2, 0); }
static long psock(void) { return syscall3(117, 10, 2, 58); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recv_(long s, void *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long soerr(long s) { int v = -1; int l = 4; long r = syscall5(133, s, 1, 4, (long)&v, (long)&l); return r < 0 ? r : v; }
static long open_(const char *p, int fl) { return syscall3(9, (long)p, fl, 0); }
static long read_(long fd, char *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const char *b, int n) { return syscall3(1, fd, (long)b, n); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM6(a) do { (a)[0] = 10; (a)[1] = 0; } while (0)
#define O_WR 1
#endif
static int failures;
static char msg[700];
static void check(int ok, const char *w) {
    print(ok ? "hello393:   ok   " : "hello393:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
#define RANGE "/proc/sys/net/ipv4/ping_group_range"
static long set_range(const char *text) {
    long fd = open_(RANGE, O_WR);
    if (fd < 0) return fd;
    long n = write_(fd, text, (int)strlen(text));
    close_(fd);
    return n;
}
static long raw;
static unsigned char lo[28];
static unsigned char sink[2048];
/* An ICMPv6 error of `type`/`code` sent to ::1 through the raw socket, quoting an IPv6 packet ::1 -> ::1 whose next header is `nh`,
   followed by `ext` (`n` bytes of extension headers) and the 8 bytes `l4`. */
static void inject(int type, int code, int nh, const unsigned char *ext, int n, const unsigned char *l4) {
    unsigned char m[128];
    for (int i = 0; i < 128; i++) m[i] = 0;
    m[0] = (unsigned char)type; m[1] = (unsigned char)code;
    unsigned char *ip = m + 8;
    ip[0] = 0x60; ip[5] = (unsigned char)(n + 8); ip[6] = (unsigned char)nh; ip[7] = 64;
    ip[23] = 1; ip[39] = 1;
    for (int i = 0; i < n; i++) m[48 + i] = ext[i];
    for (int i = 0; i < 8; i++) m[48 + n + i] = l4[i];
    sendto_(raw, m, 56 + n, lo);
    nap();
    while (recv_(raw, sink, sizeof sink) >= 0) {}
}
static void mk6(unsigned char *a, int port, int last) {
    for (int i = 0; i < 28; i++) a[i] = 0;
    FAM6(a);
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[23] = (unsigned char)last;
}
int main(void) {
    print("hello393: an ICMPv6 error quoting a packet with extension headers reaches the socket behind them\n");
    char saved[48];
    long sfd = open_(RANGE, 0);
    long sn = sfd >= 0 ? read_(sfd, saved, sizeof saved - 1) : -1;
    if (sfd >= 0) close_(sfd);
    if (sn < 0) sn = 0;
    saved[sn] = 0;
    long sr = set_range("0 0");
    mk6(lo, 0, 1);
    raw = rsock();
    unsigned char a[28], p9[28];
    mk6(p9, 9, 1);

    long u = usock();
    long uc = connect_(u, p9);
    name_(u, a);
    unsigned char uh[8] = { a[2], a[3], 0, 9, 0, 8, 0, 0 };

    unsigned char hop[8] = { 17, 0, 1, 4, 0, 0, 0, 0 };
    inject(1, 4, 0, hop, 8, uh);
    long h = soerr(u);
    snprintf(msg, sizeof msg, "H: raw %ld, range %ld, connect %ld; hop-by-hop then UDP leaves %ld (111)", raw, sr, uc, h);
    check(raw >= 0 && uc == 0 && h == 111, msg);

    unsigned char dr[24] = { 43, 1, 1, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 17, 0, 0, 0, 0, 0, 0, 0 };
    inject(1, 4, 60, dr, 24, uh);
    long d = soerr(u);
    snprintf(msg, sizeof msg, "D: destination options then routing then UDP leaves %ld (111)", d);
    check(d == 111, msg);

    unsigned char ff[8] = { 17, 0, 0, 1, 0, 0, 0, 7 };
    inject(1, 4, 44, ff, 8, uh);
    long f = soerr(u);
    snprintf(msg, sizeof msg, "F: a first fragment then UDP leaves %ld (111)", f);
    check(f == 111, msg);

    unsigned char lf[8] = { 17, 0, 0, 64, 0, 0, 0, 7 };
    inject(1, 4, 44, lf, 8, uh);
    long l = soerr(u);
    snprintf(msg, sizeof msg, "L: a later fragment leaves %ld (0)", l);
    check(l == 0, msg);

    unsigned char none[8] = { 59, 0, 1, 4, 0, 0, 0, 0 };
    inject(1, 4, 0, none, 8, uh);
    long nn = soerr(u);
    snprintf(msg, sizeof msg, "N: no next header leaves %ld (0)", nn);
    check(nn == 0, msg);

    unsigned char big[8] = { 17, 4, 1, 4, 0, 0, 0, 0 };
    inject(1, 4, 60, big, 8, uh);
    long t = soerr(u);
    snprintf(msg, sizeof msg, "T: an extension header longer than the quote leaves %ld (0)", t);
    check(t == 0, msg);

    unsigned char esp[8] = { 0, 0, 1, 0, 0, 0, 0, 1 };
    inject(1, 4, 50, esp, 8, uh);
    long es = soerr(u);
    snprintf(msg, sizeof msg, "E: UDP behind ESP leaves %ld (0)", es);
    check(es == 0, msg);
    close_(u);

    long pc = psock();
    long pcc = connect_(pc, lo);
    unsigned char rq[8] = { 128, 0, 0, 0, 0, 0, 0, 1 };
    long ps = send_(pc, rq, 8);
    nap();
    while (recv_(pc, sink, sizeof sink) >= 0) {}
    name_(pc, a);
    unsigned char eq[8] = { 128, 0, 0, 0, a[2], a[3], 0, 1 };
    unsigned char ah[12] = { 58, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1 };
    inject(1, 4, 51, ah, 12, eq);
    long p = soerr(pc);
    snprintf(msg, sizeof msg, "P: ping socket %ld connect %ld send %ld; AH then an echo request leaves %ld (111)", pc, pcc, ps, p);
    check(pc >= 0 && pcc == 0 && ps == 8 && p == 111, msg);
    close_(pc);
    close_(raw);

    long back = set_range(saved);
    snprintf(msg, sizeof msg, "restored ping_group_range (%ld)", back);
    print("hello393:   info ");
    print(msg);
    print("\n");
    print(failures ? "hello393: FAIL\n" : "hello393: PASS\n");
    return failures ? 1 : 0;
}
