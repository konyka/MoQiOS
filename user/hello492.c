/* hello492: net.ipv4.ip_nonlocal_bind and net.ipv6.ip_nonlocal_bind independently allow
 * UDP bind() to a nonlocal address. Check the defaults, each family's independent switch,
 * IPv4-mapped IPv6 bind, out-of-range writes and restoring zero. The current host accepts IPv4 nonlocal UDP bind
 * even with the option off, so OFF4_RESULT records that difference. The target follows the
 * normal Linux EADDRNOTAVAIL rule. Measured with -DHOST in a new network namespace. */
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
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr, 0); }
static long read_(long fd, void *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const void *b, int n) { return syscall3(1, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
#ifdef HOST
#define OFF4_RESULT 0
#else
#define OFF4_RESULT -99
#endif
static const char *const paths[] = {
    "/proc/sys/net/ipv4/ip_nonlocal_bind",
    "/proc/sys/net/ipv6/ip_nonlocal_bind",
};
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello492:   ok   " : "hello492:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long write_text(int v6, const char *s) {
    long fd = open_(paths[v6], 1);
    if (fd < 0) return fd;
    long r = write_(fd, s, (int)strlen(s));
    close_(fd);
    return r;
}
static void read_text(int v6, char *out, int cap) {
    long fd = open_(paths[v6], 0);
    if (fd < 0) { snprintf(out, cap, "open %ld", fd); return; }
    long n = read_(fd, out, cap - 1);
    close_(fd);
    if (n < 0) { snprintf(out, cap, "read %ld", n); return; }
    out[n] = 0;
}
static long bind_nonlocal(int v6) {
    long s = sock(v6 ? 10 : 2, 2, 0);
    if (s < 0) return s;
    unsigned char a[28];
    memset(a, 0, sizeof a);
    a[0] = v6 ? 10 : 2;
    if (v6) {
        a[8] = 0x20; a[9] = 0x01; a[10] = 0x0d; a[11] = 0xb8; a[23] = 1;
    } else {
        a[4] = 192; a[5] = 0; a[6] = 2; a[7] = 1;
    }
    long r = bind_(s, a, v6 ? 28 : 16);
    close_(s);
    return r;
}
static long bind_mapped(void) {
    long s = sock(10, 2, 0);
    if (s < 0) return s;
    unsigned char a[28];
    memset(a, 0, sizeof a);
    a[0] = 10;
    a[18] = 0xff; a[19] = 0xff;
    a[20] = 192; a[21] = 0; a[22] = 2; a[23] = 1;
    long r = bind_(s, a, 28);
    close_(s);
    return r;
}
int main(void) {
    print("hello492: ip_nonlocal_bind sysctls\n");
    char a[64], b[64];
    read_text(0, a, sizeof a);
    read_text(1, b, sizeof b);
    snprintf(msg, sizeof msg, "A: defaults '%s' / '%s' (0 / 0)", a, b);
    check(strcmp(a, "0\n") == 0 && strcmp(b, "0\n") == 0, msg);
    long off4 = bind_nonlocal(0), off6 = bind_nonlocal(1);
    snprintf(msg, sizeof msg, "B: disabled bind %ld / %ld (%d / -99)", off4, off6, OFF4_RESULT);
    check(off4 == OFF4_RESULT && off6 == -99, msg);
    long w4 = write_text(0, "1\n");
    long on4 = bind_nonlocal(0), still6 = bind_nonlocal(1), mapped = bind_mapped();
    snprintf(msg, sizeof msg, "C: IPv4 write %ld, bind %ld; IPv6 remains %ld; mapped %ld (2 0 -99 0)", w4, on4, still6, mapped);
    check(w4 == 2 && on4 == 0 && still6 == -99 && mapped == 0, msg);
    long w6 = write_text(1, "1\n");
    long on6 = bind_nonlocal(1);
    snprintf(msg, sizeof msg, "D: IPv6 write %ld, bind %ld (2 0)", w6, on6);
    check(w6 == 2 && on6 == 0, msg);
    long bad4 = write_text(0, "256\n"), bad6 = write_text(1, "-1\n");
    read_text(0, a, sizeof a);
    read_text(1, b, sizeof b);
    snprintf(msg, sizeof msg, "E: bad writes %ld / %ld leave '%s' / '%s' (-22 -22, 1 / 1)", bad4, bad6, a, b);
    check(bad4 == -22 && bad6 == -22 && strcmp(a, "1\n") == 0 && strcmp(b, "1\n") == 0, msg);
    long r4 = write_text(0, "0\n"), r6 = write_text(1, "0\n");
    long end4 = bind_nonlocal(0), end6 = bind_nonlocal(1);
    snprintf(msg, sizeof msg, "F: restore %ld / %ld; disabled bind %ld / %ld (2 2, %d -99)", r4, r6, end4, end6, OFF4_RESULT);
    check(r4 == 2 && r6 == 2 && end4 == OFF4_RESULT && end6 == -99, msg);
    print(failures ? "hello492: FAIL\n" : "hello492: PASS\n");
    return failures ? 1 : 0;
}
