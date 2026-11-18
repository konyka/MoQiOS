/* hello415: TCP_DEFER_ACCEPT (Linux do_tcp_setsockopt secs_to_retrans, do_tcp_getsockopt retrans_to_secs, tcp_check_req,
 * syn_ack_recalc). The value in seconds becomes a count of SYN-ACK retransmissions (1 s doubling); while fewer timeouts than that
 * have passed, a bare ACK finishing the handshake is dropped and the connection is not offered to accept(); the first segment with
 * data (or FIN) completes it at once and its data is readable. Once the count of timeouts is reached the server resends its SYN-ACK
 * and the client's ACK to it completes the connection without data. Measured on the host (build with -DHOST, run in
 * `unshare --map-auto --map-root-user -n` with lo up):
 *   V. TCP_DEFER_ACCEPT reads 0 by default; 1 reads 1, 3 reads 3, 5 reads 7, 100 reads 127, -5 is accepted and reads 0;
 *   I. a listener with TCP_DEFER_ACCEPT 5: a client that connects and sends nothing is not accepted within 1.5 s (EAGAIN); once it
 *      sends "ping", accept returns the connection within 1 s and the data reads back;
 *   D. a listener with TCP_DEFER_ACCEPT 1: a client that sends nothing is accepted after 0.7 to 2.5 s, with no data to read. */
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
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void close_(long s) { close((int)s); }
static long sendto_(long s, const void *b, long n) { return rc(send((int)s, b, (size_t)n, MSG_NOSIGNAL)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
#define NONBLOCK SOCK_NONBLOCK
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
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
static long sendto_(long s, const void *b, long n) { return syscall6(44, s, (long)b, n, 0x4000, 0, 0); }
static long recv_(long s, void *b, long n) { return syscall6(45, s, (long)b, n, 0x40, 0, 0); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello415:   ok   " : "hello415:   FAIL ");
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
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static long listener(int port, int dfr) {
    long l = sock(2, 1 | NONBLOCK, 0);
    seti(l, 6, 9, dfr);
    unsigned char a[16];
    mk4(a, port);
    bind_(l, a, 16);
    listen_(l, 4);
    return l;
}
static long client(int port) {
    long c = sock(2, 1, 0);
    unsigned char a[16];
    mk4(a, port);
    long r = connect_(c, a, 16);
    return r < 0 ? r : c;
}
/* Poll accept() on `l` for up to `limit` ms: the socket, or the last error; `*ms` gets the time it took. */
static long accept_within(long l, long limit, long *ms) {
    long t0 = now_ms(), a = -11;
    while (now_ms() - t0 < limit) {
        a = accept_(l);
        if (a >= 0) break;
        nap();
    }
    *ms = now_ms() - t0;
    return a;
}
int main(void) {
    print("hello415: TCP_DEFER_ACCEPT\n");
    long s = sock(2, 1, 0);
    int v0 = geti(s, 6, 9);
    long e1 = seti(s, 6, 9, 1); int v1 = geti(s, 6, 9);
    long e3 = seti(s, 6, 9, 3); int v3 = geti(s, 6, 9);
    long e5 = seti(s, 6, 9, 5); int v5 = geti(s, 6, 9);
    long e100 = seti(s, 6, 9, 100); int v100 = geti(s, 6, 9);
    long en = seti(s, 6, 9, -5); int vn = geti(s, 6, 9);
    snprintf(msg, sizeof msg, "V: default %d; 1 %ld reads %d, 3 %ld reads %d, 5 %ld reads %d, 100 %ld reads %d, -5 %ld reads %d (0; 1 3 7 127 0, all 0)", v0, e1, v1, e3, v3, e5, v5, e100, v100, en, vn);
    check(v0 == 0 && v1 == 1 && v3 == 3 && v5 == 7 && v100 == 127 && vn == 0 && e1 == 0 && e3 == 0 && e5 == 0 && e100 == 0 && en == 0, msg);
    close_(s);

    long l = listener(40431, 5);
    long c = client(40431);
    long ms = 0;
    long a = accept_within(l, 1500, &ms);
    long w = c >= 0 ? sendto_(c, "ping", 4) : c;
    long ms2 = 0;
    long a2 = a >= 0 ? a : accept_within(l, 1000, &ms2);
    char b[8] = { 0 };
    long n = -1;
    for (int i = 0; i < 50 && a2 >= 0; i++) { n = recv_(a2, b, sizeof b); if (n > 0) break; nap(); }
    snprintf(msg, sizeof msg, "I: TCP_DEFER_ACCEPT 5, client %ld silent: accept %ld after %ld ms; send %ld, then accept %ld after %ld ms, recv %ld \"%.4s\" (-11, 4, >= 0 < 1000, 4 ping)", c, a, ms, w, a2, ms2, n, b);
    check(c >= 0 && a == -11 && w == 4 && a2 >= 0 && ms2 < 1000 && n == 4 && memcmp(b, "ping", 4) == 0, msg);
    if (a2 >= 0) close_(a2);
    if (c >= 0) close_(c);
    close_(l);

    l = listener(40432, 1);
    c = client(40432);
    long d = accept_within(l, 4000, &ms);
    long dn = d >= 0 ? recv_(d, b, sizeof b) : -1;
    snprintf(msg, sizeof msg, "D: TCP_DEFER_ACCEPT 1, client %ld silent: accept %ld after %ld ms, recv %ld (>= 0, 700..2500, -11)", c, d, ms, dn);
    check(c >= 0 && d >= 0 && ms >= 700 && ms <= 2500 && dn == -11, msg);
    if (d >= 0) close_(d);
    if (c >= 0) close_(c);
    close_(l);

    print(failures == 0 ? "hello415: PASS\n" : "hello415: FAIL\n");
    return failures == 0 ? 0 : 1;
}
