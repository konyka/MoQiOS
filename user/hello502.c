/* hello502: net.ipv4.tcp_notsent_lowat (proc_douintvec, default UINT_MAX) is the TCP_NOTSENT_LOWAT of a socket that left its own at 0.
 * A reads the default; B rejects -1, 2^32 and text without changing it; C writes 1024; D a TCP client that never set the option stops
 * queueing at the sysctl limit (no POLLOUT, EAGAIN); E a socket value overrides it; F restores. Measured with -DHOST in a new netns. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
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
static long send_(long s, const void *b, long n, int fl) { return rc(send((int)s, b, (size_t)n, fl | MSG_NOSIGNAL)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long ioctl_(long s, unsigned long r, void *v) { return rc(ioctl((int)s, r, v)); }
static long poll_out(long s) { struct pollfd p = { (int)s, POLLOUT, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : (p.revents & POLLOUT) != 0; }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long read_(long fd, void *b, int n) { return rc(read((int)fd, b, (size_t)n)); }
static long write_(long fd, const void *b, int n) { return rc(write((int)fd, b, (size_t)n)); }
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
static long send_(long s, const void *b, long n, int fl) { return syscall6(44, s, (long)b, n, fl | 0x4000, 0, 0); }
static long recv_(long s, void *b, long n) { return syscall6(45, s, (long)b, n, 0x40, 0, 0); }
static long ioctl_(long s, unsigned long r, void *v) { return syscall3(165, s, (long)r, (long)v); }
static long poll_out(long s) { struct { int fd; short ev, rev; } p = { (int)s, 4, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (p.rev & 4) != 0; }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr, 0); }
static long read_(long fd, void *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const void *b, int n) { return syscall3(1, fd, (long)b, n); }
#endif
#define LOWAT 25
#define DONTWAIT 0x40
static const char path[] = "/proc/sys/net/ipv4/tcp_notsent_lowat";
static int failures;
static char msg[900];
static char buf[20000];
static char saved[32];
static void check(int ok, const char *w) {
    print(ok ? "hello502:   ok   " : "hello502:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static int unsent(long s) { int v = -1; long r = ioctl_(s, 0x894B, &v); return r < 0 ? (int)r : v; }
static long write_text(const char *t) { long fd = open_(path, 1); if (fd < 0) return fd; long r = write_(fd, t, (int)strlen(t)); close_(fd); return r; }
static long read_text(char *out, int cap) { long fd = open_(path, 0); if (fd < 0) return fd; long n = read_(fd, out, cap - 1); close_(fd); if (n >= 0) out[n] = 0; return n; }
int main(void) {
    print("hello502: net.ipv4.tcp_notsent_lowat\n");
    (void)now_ms; (void)recv_;
    long sr = read_text(saved, sizeof saved);
    snprintf(msg, sizeof msg, "A: default %ld '%s' (11 4294967295)", sr, saved);
    check(sr == 11 && strcmp(saved, "4294967295\n") == 0, msg);
    long b1 = write_text("-1\n"), b2 = write_text("4294967296\n"), b3 = write_text("abc\n");
    char now[32] = { 0 };
    long nr = read_text(now, sizeof now);
    snprintf(msg, sizeof msg, "B: invalid %ld %ld %ld, still %ld '%s' (-22 -22 -22, 4294967295)", b1, b2, b3, nr, now);
    check(b1 == -22 && b2 == -22 && b3 == -22 && nr == 11 && strcmp(now, "4294967295\n") == 0, msg);
    long w = write_text("1024\n");
    nr = read_text(now, sizeof now);
    snprintf(msg, sizeof msg, "C: write 1024 %ld, reads %ld '%s' (5 5 1024)", w, nr, now);
    check(w == 5 && nr == 5 && strcmp(now, "1024\n") == 0, msg);

    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 40502 >> 8; a[3] = 40502 & 0xff; a[4] = 127; a[7] = 1;
    long l = sock(2, 1, 0);
    seti(l, 1, 8, 4096);
    bind_(l, a, 16);
    listen_(l, 4);
    long c = sock(2, 1, 0);
    seti(c, 6, 1, 1);
    long cr = connect_(c, a, 16);
    long p = -11;
    for (int i = 0; i < 100 && p < 0; i++) { p = accept_(l); if (p < 0) nap(); }
    int own = geti(c, 6, LOWAT);
    long total = 0;
    for (int i = 0; i < 40 && total < 12000; i++) { long r = send_(c, buf, 1000, DONTWAIT); if (r > 0) total += r; else break; }
    for (int i = 0; i < 5; i++) nap();
    int u = unsent(c);
    long po = poll_out(c), more = send_(c, buf, 100, DONTWAIT);
    snprintf(msg, sizeof msg, "D: connect %ld accept %ld, own TCP_NOTSENT_LOWAT %d; queued %ld before the sysctl limit, unsent %d: POLLOUT %ld, send %ld (0 >=0 0; <12000, >=1024: 0 -11)", cr, p, own, total, u, po, more);
    check(cr == 0 && p >= 0 && own == 0 && total < 12000 && u >= 1024 && po == 0 && more == -11, msg);
    seti(c, 6, LOWAT, 4 * u + 4);
    long po_own = poll_out(c);
    snprintf(msg, sizeof msg, "E: a socket value 4u+4 overrides the sysctl: POLLOUT %ld (1)", po_own);
    check(po_own == 1, msg);
    if (p >= 0) close_(p);
    close_(c); close_(l);
    long rs = write_text(saved);
    nr = read_text(now, sizeof now);
    snprintf(msg, sizeof msg, "F: restore %ld, reads '%s' (11 4294967295)", rs, now);
    check(rs == 11 && strcmp(now, "4294967295\n") == 0, msg);
    print(failures ? "hello502: FAIL\n" : "hello502: PASS\n");
    return failures ? 1 : 0;
}
