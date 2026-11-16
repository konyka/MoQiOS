/* hello376: a datagram to an IPv6 next hop whose MAC is not known yet is queued on the neighbour while Neighbor Solicitations ask
 * for it, and the send succeeds (Linux __neigh_event_send, as for ARP in hello375); once the advertisement comes the frames go
 * out, when nobody answers they are dropped. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n`, with a veth pair whose far end lives in a second namespace holding fec0::2 and fec0::3,
 * the near end fec0::15/64 with a default route via fec0::2; on MoQiOS the QEMU user network's router gives fec0::/64):
 *   A. a UDP socket connected to [fec0::99]:9 names an address of fec0::/64 (MoQiOS waits up to 10 s for it);
 *   R. an echo request to the router fec0::2 from a ping socket is accepted (16) and its reply arrives;
 *   U. a UDP datagram to [fec0::3]:9 is accepted (16);
 *   Q. to fec0::99, which nobody answers: two UDP sendto, a connected send and a ping all return 16; nothing comes back in 4 s. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock_(int d, int t, int p) { return rc(socket(d, t, p)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recv_(long s, void *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long getint(long s, int opt) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, opt, &v, &l)); return r < 0 ? r : v; }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam_v_ = (f); memcpy(a, &fam_v_, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
#define SOCK_DGRAM 2
#define SO_ERROR 4
static long sock_(int d, int t, int p) { return syscall3(117, d, t, p); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recv_(long s, void *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long getint(long s, int opt) { int v = -1; int l = 4; long r = syscall5(133, s, 1, opt, (long)&v, (long)&l); return r < 0 ? r : v; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
static char range_saved[48];
static long range_io(const char *t, int wr) {
#ifdef HOST
    long fd = rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY));
#else
    long fd = syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0);
#endif
    if (fd < 0) return fd;
    int n = 0;
    if (wr) while (t[n] && t[n] != '\n') n++;
#ifdef HOST
    long r = wr ? rc(write((int)fd, t, n)) : rc(read((int)fd, range_saved, sizeof range_saved - 1));
#else
    long r = wr ? syscall3(1, fd, (long)t, n) : syscall3(10, fd, (long)range_saved, sizeof range_saved - 1);
#endif
    close_(fd);
    if (!wr && r > 0) range_saved[r] = 0;
    return r;
}
static int failures;
static char msg[480];
static void check(int ok, const char *w) {
    print(ok ? "hello376:   ok   " : "hello376:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* fec0::<last>, port `port`. */
static void mk6(unsigned char *s, int last, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s, AF_INET6);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[8] = 0xfe; s[9] = 0xc0;
    s[23] = (unsigned char)last;
}
static long ping_wait(long p, int last) {
    unsigned char a[28], req[16] = { 128, 0, 0, 0, 0, 0, 0, 3, 'h', 'e', 'l', 'l', 'o', '3', '7', '6' }, rep[64];
    mk6(a, last, 0);
    long s = sendto_(p, req, 16, a);
    if (s != 16) return s < 0 ? s : -1000;
    long r = -11;
    for (int t = 0; t < 150 && r == -11; t++) { r = recv_(p, rep, sizeof rep); if (r == -11) pump(); }
    return r == 16 && rep[0] == 129 ? 16 : (r < 0 ? r : -1001);
}
int main(void) {
    print("hello376: unresolved IPv6 next hop: frames wait for Neighbor Discovery\n");
    long saved = range_io(0, 0);
    range_io("0 0", 1);
    unsigned char a[28], nm[28], b[16] = "hello376-queued";
    long s = sock_(AF_INET6, SOCK_DGRAM, 0), p = sock_(AF_INET6, SOCK_DGRAM, 58);

    /* A: wait for an address of fec0::/64 (the router advertisement on MoQiOS). */
    long probe = sock_(AF_INET6, SOCK_DGRAM, 0);
    mk6(a, 0x99, 9);
    long ac = -1, an = -1;
    int have = 0;
    for (int t = 0; t < 500 && !have; t++) {
        ac = connect_(probe, a);
        an = name_(probe, nm);
        have = ac == 0 && an == 0 && nm[8] == 0xfe && nm[9] == 0xc0;
        if (!have) pump();
    }
    close_(probe);
    snprintf(msg, sizeof msg, "A: connect to [fec0::99]:9 %ld, getsockname %ld, address in fec0::/64 %d (0 0 1)", ac, an, have);
    check(have, msg);

    long r1 = ping_wait(p, 2);
    snprintf(msg, sizeof msg, "R: echo request to the router fec0::2: %ld (16)", r1);
    check(r1 == 16, msg);

    mk6(a, 3, 9);
    long u1 = sendto_(s, b, 16, a);
    snprintf(msg, sizeof msg, "U: UDP to [fec0::3]:9 %ld (16)", u1);
    check(u1 == 16, msg);

    mk6(a, 0x99, 9);
    long q1 = sendto_(s, b, 16, a), q2 = sendto_(s, b, 16, a);
    long c = sock_(AF_INET6, SOCK_DGRAM, 0);
    long qc = connect_(c, a);
    long q3 = send_(c, b, 16);
    long pc = sock_(AF_INET6, SOCK_DGRAM, 58);
    unsigned char req[16] = { 128, 0, 0, 0, 0, 0, 0, 4 };
    mk6(a, 0x99, 0);
    long q4 = sendto_(pc, req, 16, a);
    long back = 0;
    for (int t = 0; t < 200; t++) {
        unsigned char x[64];
        if (recv_(c, x, sizeof x) != -11 || recv_(pc, x, sizeof x) != -11) back++;
        pump();
    }
    long e = getint(c, SO_ERROR);
    snprintf(msg, sizeof msg, "Q: to fec0::99 (no answer): sendto %ld %ld, connect %ld send %ld, ping %ld; anything back in 4 s %ld, SO_ERROR %ld (16 16 0 16 16 0 0)", q1, q2, qc, q3, q4, back, e);
    check(q1 == 16 && q2 == 16 && qc == 0 && q3 == 16 && q4 == 16 && back == 0 && e == 0, msg);
    close_(c); close_(pc); close_(s); close_(p);

    if (saved > 0) range_io(range_saved, 1);
    else { print("hello376:   FAIL could not read net.ipv4.ping_group_range\n"); failures++; }
    print(failures ? "hello376: FAIL\n" : "hello376: PASS\n");
    return failures ? 1 : 0;
}
