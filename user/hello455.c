/* hello455: IPv6 ICMPv6 messages longer than the path MTU are fragmented (Linux rawv6_sendmsg / ping_v6_sendmsg →
 * ip6_append_data, ip6_fragment: a Fragment header on every piece) and the echo reply to a reassembled request is sent whole, in
 * fragments too (icmpv6_echo_reply). Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo
 * up and its MTU set to 1500, the MTU this kernel's lo and NIC use):
 *   R. a raw IPPROTO_ICMPV6 socket sends a 3000-byte echo request to ::1: send returns 3000; the socket then reads the request
 *      (3000 bytes, type 128) and the echo reply (3000 bytes, type 129, the same data) whole;
 *   M. 65535 bytes (the largest IPv6 payload) go the same way; 65536 bytes are EMSGSIZE;
 *   D. with IPV6_MTU_DISCOVER DO, PROBE or INTERFACE, 3000 bytes are EMSGSIZE; with DONT and OMIT they go;
 *   P. a ping socket (net.ipv4.ping_group_range opened to group 0 for the test) sends 1453, 3000 and 65535-byte echo requests and
 *      reads each reply whole with the same data; 65536 bytes are EMSGSIZE; with DO, 3000 bytes are EMSGSIZE. */
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
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long setopt_(long s, int lv, int o, int v) { return rc(setsockopt((int)s, lv, o, &v, 4)); }
static void nap(void) { struct timespec t = { 0, 30000000 }; nanosleep(&t, 0); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long io_(long fd, char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long setopt_(long s, int lv, int o, int v) { return syscall5(132, s, lv, o, (long)&v, 4); }
static void nap(void) { long t[2] = { 0, 30000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr ? 1 : 0, 0); }
static long io_(long fd, char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello455:   ok   " : "hello455:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char out[65600];
static unsigned char in[65600];
static const char *range_path = "/proc/sys/net/ipv4/ping_group_range";
static char range_saved[48];
static long open_ping_range(void) {
    long fd = open_(range_path, 0);
    if (fd < 0) return fd;
    long n = io_(fd, range_saved, sizeof range_saved - 1, 0);
    close_(fd);
    if (n <= 0) return -1;
    range_saved[n] = 0;
    fd = open_(range_path, 1);
    if (fd < 0) return fd;
    char zero[] = "0 0";
    long w = io_(fd, zero, 3, 1);
    close_(fd);
    return w;
}
static void restore_ping_range(void) {
    long fd = open_(range_path, 1);
    if (fd < 0) return;
    int n = 0;
    while (range_saved[n] && range_saved[n] != '\n') n++;
    io_(fd, range_saved, n, 1);
    close_(fd);
}
/* An echo request of `n` bytes with sequence `seq` (the kernel computes an ICMPv6 checksum). */
static void echo_req(int n, int seq) {
    for (int i = 8; i < n; i++) out[i] = (unsigned char)(i * 7 + seq);
    out[0] = 128; out[1] = 0; out[2] = 0; out[3] = 0; out[4] = 0x45; out[5] = 0x55; out[6] = 0; out[7] = (unsigned char)seq;
}
/* Wait up to 1 s for a message on `s`. */
static long wait_msg(long s) {
    long r = -11;
    for (int t = 0; t < 33 && r == -11; t++) {
        r = recv_(s, in, sizeof in);
        if (r == -11) nap();
    }
    return r;
}
static int ty(long n) { return n > 0 ? in[0] : -1; }
/* Whether the echo data (after the 8-byte header) is what was sent. */
static int same(long n, int len) { return n == len && memcmp(in + 8, out + 8, (unsigned long)(len - 8)) == 0; }
int main(void) {
    print("hello455: IPv6 ICMPv6 messages over the MTU are fragmented\n");
    unsigned char a[28];
    memset(a, 0, 28);
    a[0] = 10; a[23] = 1;
    long raw = sock(10, 3, 58);

    echo_req(3000, 1);
    long rn = sendto_(raw, out, 3000, a, 28);
    long r1 = wait_msg(raw);
    int r1t = ty(r1), r1s = same(r1, 3000);
    long r2 = wait_msg(raw);
    int r2t = ty(r2), r2s = same(r2, 3000);
    snprintf(msg, sizeof msg, "R: raw socket %d; sent %ld; request %ld type %d same %d; reply %ld type %d same %d (1 3000 3000 128 1 3000 129 1)", raw >= 0, rn, r1, r1t,
             r1s, r2, r2t, r2s);
    check(raw >= 0 && rn == 3000 && r1 == 3000 && r1t == 128 && r1s && r2 == 3000 && r2t == 129 && r2s, msg);

    echo_req(65535, 2);
    long mn = sendto_(raw, out, 65535, a, 28);
    long m1 = wait_msg(raw);
    int m1t = ty(m1);
    long m2 = wait_msg(raw);
    int m2t = ty(m2), m2s = same(m2, 65535);
    long mb = sendto_(raw, out, 65536, a, 28);
    snprintf(msg, sizeof msg, "M: 65535 bytes: sent %ld; request %ld type %d; reply %ld type %d same %d; 65536 bytes %ld (65535 65535 128 65535 129 1 -90)", mn, m1, m1t,
             m2, m2t, m2s, mb);
    check(mn == 65535 && m1 == 65535 && m1t == 128 && m2 == 65535 && m2t == 129 && m2s && mb == -90, msg);

    echo_req(3000, 3);
    long dm[6];
    for (int mode = 0; mode < 6; mode++) {
        setopt_(raw, 41, 23, mode);
        dm[mode] = sendto_(raw, out, 3000, a, 28);
        nap();
        while (recv_(raw, in, sizeof in) >= 0) {}
    }
    setopt_(raw, 41, 23, 1);
    snprintf(msg, sizeof msg, "D: 3000 bytes under DONT %ld, WANT %ld, DO %ld, PROBE %ld, INTERFACE %ld, OMIT %ld (3000 3000 -90 -90 -90 3000)", dm[0], dm[1], dm[2], dm[3],
             dm[4], dm[5]);
    check(dm[0] == 3000 && dm[1] == 3000 && dm[2] == -90 && dm[3] == -90 && dm[4] == -90 && dm[5] == 3000, msg);

    long range_rc = open_ping_range();
    long p = sock(10, 2, 58);
    static const int sizes[3] = { 1453, 3000, 65535 };
    int ok = range_rc == 3 && p >= 0;
    int at = snprintf(msg, sizeof msg, "P: ping socket %d;", p >= 0);
    for (int k = 0; k < 3; k++) {
        echo_req(sizes[k], 10 + k);
        long n = sendto_(p, out, sizes[k], a, 28);
        long m = wait_msg(p);
        int t = ty(m), s = same(m, sizes[k]);
        if (n != sizes[k] || m != sizes[k] || t != 129 || !s) ok = 0;
        at += snprintf(msg + at, sizeof msg - (unsigned long)at, " %d: sent %ld reply %ld type %d same %d;", sizes[k], n, m, t, s);
    }
    long pb = sendto_(p, out, 65536, a, 28);
    setopt_(p, 41, 23, 2);
    long pd = sendto_(p, out, 3000, a, 28);
    snprintf(msg + at, sizeof msg - (unsigned long)at, " 65536 %ld; DO 3000 %ld (-90 -90)", pb, pd);
    check(ok && pb == -90 && pd == -90, msg);
    restore_ping_range();

    print(failures ? "hello455: FAIL\n" : "hello455: PASS\n");
    return failures ? 1 : 0;
}
