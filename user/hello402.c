/* hello402: the IPv4 id of an IP_HDRINCL send (Linux raw_send_hdrinc: an id of 0 is chosen by ip_select_ident, which leaves 0 when
 * the header has DF set and otherwise takes the next value of an id generator). Measured on the host (build with -DHOST, run as
 * root in `unshare --map-auto --map-root-user -n` with only lo up), an IPPROTO_RAW socket sending to 127.0.0.1 and a protocol-253
 * socket reading the copies:
 *   Z. three datagrams with id 0 and no DF get nonzero ids, all different, the checksum still valid;
 *   D. three with id 0 and DF set keep id 0;
 *   G. one with id 0x1234 and no DF keeps it. */
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
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello402:   ok   " : "hello402:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const unsigned char lo[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
static unsigned char buf[200];
static long r, c;
/* Send a 24-byte protocol-253 datagram with `id` and the DF bit `df` through the IPPROTO_RAW socket; the copy's id, or -1. Whether
 * the copy's header checksum holds goes to *sum_ok. */
static long round_trip(int id, int df, int *sum_ok) {
    unsigned char h[24] = { 0x45, 0, 0, 24, (unsigned char)(id >> 8), (unsigned char)id, (unsigned char)(df ? 0x40 : 0), 0, 64, 253, 0, 0,
                            127, 0, 0, 1, 127, 0, 0, 1, 'a', 'b', 'c', 'd' };
    while (recv_(c, buf, sizeof buf) >= 0) {}
    if (sendto_(r, h, 24, lo, 16) != 24) return -1;
    nap();
    if (recv_(c, buf, sizeof buf) != 24) return -1;
    unsigned int s = 0;
    for (int i = 0; i < 20; i += 2) s += (unsigned int)(buf[i] << 8 | buf[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    *sum_ok = s == 0xffff;
    return buf[4] << 8 | buf[5];
}
int main(void) {
    print("hello402: the IPv4 id of an IP_HDRINCL send\n");
    r = sock(2, 3, 255);
    c = sock(2, 3, 253);
    int k1 = 0, k2 = 0, k3 = 0;
    long z1 = round_trip(0, 0, &k1), z2 = round_trip(0, 0, &k2), z3 = round_trip(0, 0, &k3);
    snprintf(msg, sizeof msg, "Z: sockets %ld %ld; id 0 without DF became 0x%lx 0x%lx 0x%lx (nonzero, all different), checksums %d %d %d (1 1 1)", r, c, z1, z2, z3, k1, k2, k3);
    check(r >= 0 && c >= 0 && z1 > 0 && z2 > 0 && z3 > 0 && z1 != z2 && z2 != z3 && z1 != z3 && k1 && k2 && k3, msg);
    long d1 = round_trip(0, 1, &k1), d2 = round_trip(0, 1, &k2), d3 = round_trip(0, 1, &k3);
    snprintf(msg, sizeof msg, "D: id 0 with DF stays 0x%lx 0x%lx 0x%lx (0 0 0), checksums %d %d %d", d1, d2, d3, k1, k2, k3);
    check(d1 == 0 && d2 == 0 && d3 == 0 && k1 && k2 && k3, msg);
    long g = round_trip(0x1234, 0, &k1);
    snprintf(msg, sizeof msg, "G: id 0x1234 without DF stays 0x%lx (0x1234), checksum %d", g, k1);
    check(g == 0x1234 && k1, msg);
    close_(r);
    close_(c);
    print(failures == 0 ? "hello402: PASS\n" : "hello402: FAIL\n");
    return failures == 0 ? 0 : 1;
}
