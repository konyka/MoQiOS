/* hello494: net.ipv4.ip_unprivileged_port_start controls privileged UDP/TCP bind.
 * The test keeps only CAP_NET_ADMIN (for the sysctl), drops CAP_NET_BIND_SERVICE, and checks
 * the default 1024, 0 (all ports unprivileged), a custom boundary 100, invalid/overlapping
 * writes and restoration. Measured with -DHOST in a new network namespace. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long read_(long fd, void *b, int n) { return rc(read((int)fd, b, (size_t)n)); }
static long write_(long fd, const void *b, int n) { return rc(write((int)fd, b, (size_t)n)); }
static long capset_(const void *h, const void *d) { return rc(syscall(SYS_capset, h, d)); }
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
static long capset_(const void *h, const void *d) { return syscall2(307, (long)h, (long)d); }
static void close_(long s) { syscall1(11, s); }
#endif
static const char path[] = "/proc/sys/net/ipv4/ip_unprivileged_port_start";
static int failures;
static char msg[400], saved[64];
static void check(int ok, const char *w) {
    print(ok ? "hello494:   ok   " : "hello494:   FAIL ");
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
static long keep_only_net_admin(void) {
    struct { unsigned int version; int pid; } h = { 0x20080522u, 0 };
    struct { unsigned int eff, perm, inh; } d[2] = { 0 };
    d[0].eff = d[0].perm = 1u << 12;
    return capset_(&h, &d);
}
static long bind_port(int type, int port) {
    long s = sock(2, type, 0);
    if (s < 0) return s;
    unsigned char a[16];
    memset(a, 0, sizeof a);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[4] = 127; a[7] = 1;
    long r = bind_(s, a, 16);
    close_(s);
    return r;
}
int main(void) {
    print("hello494: ip_unprivileged_port_start sysctl\n");
    long ar = read_text(saved, sizeof saved);
    long cap = keep_only_net_admin();
    snprintf(msg, sizeof msg, "A: read %ld '%s', capset %ld (1024, 0)", ar, saved, cap);
    check(ar > 0 && strcmp(saved, "1024\n") == 0 && cap == 0, msg);
    long u80 = bind_port(2, 80), t80 = bind_port(1, 80);
    snprintf(msg, sizeof msg, "A: default UDP/TCP 80 %ld / %ld (-13 -13)", u80, t80);
    check(u80 == -13 && t80 == -13, msg);
    long w0 = write_text("0\n");
    u80 = bind_port(2, 80); t80 = bind_port(1, 80);
    snprintf(msg, sizeof msg, "B: zero write %ld, UDP/TCP 80 %ld / %ld (2 0 0)", w0, u80, t80);
    check(w0 == 2 && u80 == 0 && t80 == 0, msg);
    long w100 = write_text("100\n");
    long u99 = bind_port(2, 99), u100 = bind_port(2, 100), t100 = bind_port(1, 100);
    snprintf(msg, sizeof msg, "C: write 100 %ld; UDP 99 %ld, UDP/TCP 100 %ld / %ld (4 -13 0 0)", w100, u99, u100, t100);
    check(w100 == 4 && u99 == -13 && u100 == 0 && t100 == 0, msg);
    long bad1 = write_text("-1\n"), bad2 = write_text("65536\n"), bad3 = write_text("50000\n");
    char now[64] = { 0 };
    long nr = read_text(now, sizeof now);
    snprintf(msg, sizeof msg, "D: invalid %ld %ld %ld, read %ld '%s' (-22 -22 -22, 100)", bad1, bad2, bad3, nr, now);
    check(bad1 == -22 && bad2 == -22 && bad3 == -22 && nr > 0 && strcmp(now, "100\n") == 0, msg);
    long restored = write_text(saved);
    u80 = bind_port(2, 80); t80 = bind_port(1, 80);
    snprintf(msg, sizeof msg, "E: restore %ld, UDP/TCP 80 %ld / %ld (%ld -13 -13)", restored, u80, t80, ar);
    check(ar > 0 && restored == ar && u80 == -13 && t80 == -13, msg);
    print(failures ? "hello494: FAIL\n" : "hello494: PASS\n");
    return failures ? 1 : 0;
}
