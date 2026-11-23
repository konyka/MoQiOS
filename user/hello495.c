/* hello495: /proc/sys/net/ipv4/ip_local_reserved_ports excludes ports from automatic UDP/TCP
 * allocation without changing explicit bind. Cover a mixed list/range, readback, invalid writes,
 * clearing, and restoration of both sysctls. Measured with -DHOST in a new netns with lo up. */
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
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr, 0); }
static long read_(long fd, void *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const void *b, int n) { return syscall3(1, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
static const char reserved_path[] = "/proc/sys/net/ipv4/ip_local_reserved_ports";
static const char range_path[] = "/proc/sys/net/ipv4/ip_local_port_range";
static int failures;
static char msg[500], saved_reserved[128], saved_range[64];
static void check(int ok, const char *w) {
    print(ok ? "hello495:   ok   " : "hello495:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long write_text(const char *path, const char *s) {
    long fd = open_(path, 1);
    if (fd < 0) return fd;
    long r = write_(fd, s, (int)strlen(s));
    close_(fd);
    return r;
}
static long read_text(const char *path, char *out, int cap) {
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
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[4] = 127; a[7] = 1;
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
static int available(int p) {
    return p >= 52000 && p <= 52010 && p != 52000 && (p < 52002 || p > 52004);
}
static long bind_port(int type, int port) {
    long s = sock(2, type, 0);
    if (s < 0) return s;
    unsigned char a[16];
    mk4(a, port);
    long r = bind_(s, a, 16);
    close_(s);
    return r;
}
int main(void) {
    print("hello495: ip_local_reserved_ports sysctl\n");
    long sr = read_text(reserved_path, saved_reserved, sizeof saved_reserved);
    long rg = read_text(range_path, saved_range, sizeof saved_range);
    snprintf(msg, sizeof msg, "A: saved reserved %ld '%s', range %ld '%s'", sr, saved_reserved, rg, saved_range);
    check(sr >= 0 && rg > 0, msg);
    long wr = write_text(reserved_path, "52000,52002-52004\n");
    char now[128] = { 0 };
    long rr = read_text(reserved_path, now, sizeof now);
    long explicit_bind = bind_port(2, 52000);
    snprintf(msg, sizeof msg, "B: write %ld read %ld '%s'; explicit bind %ld (18, same, 0)", wr, rr, now, explicit_bind);
    check(wr == 18 && rr > 0 && strcmp(now, "52000,52002-52004\n") == 0 && explicit_bind == 0, msg);
    long sw = write_text(range_path, "52000 52010\n");

    unsigned char dst[16], local[16];
    mk4(dst, 52120);
    long ur = sock(2, 2, 0);
    long ub = bind_(ur, dst, 16);
    long us = sock(2, 2, 0);
    long sent = sendto_(us, "x", 1, dst, 16);
    long un = name_(us, local);
    int up = port_of(local);
    snprintf(msg, sizeof msg, "C: range %ld; UDP bind peer %ld send %ld name %ld port %d (0 0 1 0, unreserved)", sw, ub, sent, un, up);
    check(sw == 12 && ub == 0 && sent == 1 && un == 0 && available(up), msg);
    close_(us); close_(ur);

    mk4(dst, 52122);
    long tl = sock(2, 1, 0);
    long tb = bind_(tl, dst, 16), tli = listen_(tl, 4);
    long tc = sock(2, 1, 0);
    long cr = connect_(tc, dst, 16);
    long tn = name_(tc, local);
    int tp = port_of(local);
    long ta = cr == 0 ? accept_(tl) : -1000;
    snprintf(msg, sizeof msg, "D: TCP bind %ld listen %ld connect %ld name %ld port %d accept %ld (0 0 0 0, unreserved >=0)", tb, tli, cr, tn, tp, ta);
    check(tb == 0 && tli == 0 && cr == 0 && tn == 0 && available(tp) && ta >= 0, msg);
    close_(ta); close_(tc); close_(tl);

    long bad1 = write_text(reserved_path, "52004-52002\n");
    long bad2 = write_text(reserved_path, "65536\n");
    rr = read_text(reserved_path, now, sizeof now);
    snprintf(msg, sizeof msg, "E: invalid %ld / %ld, read %ld '%s' (-22 -22, unchanged)", bad1, bad2, rr, now);
    check(bad1 == -22 && bad2 == -22 && rr > 0 && strcmp(now, "52000,52002-52004\n") == 0, msg);
    long cleared = write_text(reserved_path, "\n");
    rr = read_text(reserved_path, now, sizeof now);
    snprintf(msg, sizeof msg, "F: clear %ld, read %ld '%s' (1, empty)", cleared, rr, now);
    check(cleared == 1 && rr == 1 && strcmp(now, "\n") == 0, msg);
    long restored_reserved = write_text(reserved_path, saved_reserved);
    long restored_range = write_text(range_path, saved_range);
    snprintf(msg, sizeof msg, "G: restore %ld / %ld (%ld / %ld)", restored_reserved, restored_range, sr, rg);
    check(sr >= 0 && rg > 0 && restored_reserved == sr && restored_range == rg, msg);
    print(failures ? "hello495: FAIL\n" : "hello495: PASS\n");
    return failures ? 1 : 0;
}
