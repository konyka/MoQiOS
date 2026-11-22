/* hello491: IP_TRANSPARENT / IPV6_TRANSPARENT allow bind() to a nonlocal address
 * (inet_addr_valid_or_nonlocal / ipv6_can_nonlocal_bind), like FREEBIND. Cover UDP,
 * TCP, raw and ping sockets over both families. Without the option the target rejects
 * the address with EADDRNOTAVAIL; with it bind succeeds and getsockname preserves it.
 * The current host accepts IPv4 nonlocal bind even with the option off, except for ping,
 * whose TRANSPARENT bind it still rejects; both host differences have separate expectations.
 * Ping setup writes ping_group_range and restores it. Measured with -DHOST in a new netns. */
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
static long name_(long s, void *a) { socklen_t l = 28; return rc(getsockname((int)s, a, &l)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void close_(long s) { close((int)s); }
static long range_fd(int wr) { return rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY)); }
static long range_io(long fd, char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long name_(long s, void *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void close_(long s) { syscall1(11, s); }
static long range_fd(int wr) { return syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0); }
static long range_io(long fd, char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
#endif
static char range_saved[48];
static long open_ping_range(void) {
    long fd = range_fd(0);
    if (fd < 0) return fd;
    long n = range_io(fd, range_saved, sizeof range_saved - 1, 0);
    close_(fd);
    if (n <= 0) return -1;
    range_saved[n] = 0;
    fd = range_fd(1);
    if (fd < 0) return fd;
    char zero[] = "0 0";
    long w = range_io(fd, zero, 3, 1);
    close_(fd);
    return w;
}
static void restore_ping_range(void) {
    long fd = range_fd(1);
    if (fd < 0) return;
    int n = 0;
    while (range_saved[n] && range_saved[n] != '\n') n++;
    range_io(fd, range_saved, n, 1);
    close_(fd);
}
#ifdef HOST
#define OFF4_RESULT 0
#define PING4_ON_RESULT -99
#define PING4_ADDRESS_OK 0
#else
#define OFF4_RESULT -99
#define PING4_ON_RESULT 0
#define PING4_ADDRESS_OK 1
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello491:   ok   " : "hello491:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *a) {
    memset(a, 0, 16);
    a[0] = 2;
    a[4] = 192; a[5] = 0; a[6] = 2; a[7] = 1;
}
static void mk6(unsigned char *a) {
    memset(a, 0, 28);
    a[0] = 10;
    a[8] = 0x20; a[9] = 0x01; a[10] = 0x0d; a[11] = 0xb8; a[23] = 1;
}
static int one_kind(int v6, int kind) {
    static const char *const names[] = { "UDP", "TCP", "raw", "ping" };
    int type = kind == 2 ? 3 : kind == 1 ? 1 : 2;
    int protocol = kind >= 2 ? (v6 ? 58 : 1) : 0;
    long s = sock(v6 ? 10 : 2, type, protocol);
    unsigned char a[28], got[28];
    if (v6) mk6(a); else mk4(a);
    long off = bind_(s, a, v6 ? 28 : 16);
    if (off == 0) {
        close_(s);
        s = sock(v6 ? 10 : 2, type, protocol);
    }
    int one = 1;
    long sr = setopt_(s, v6 ? 41 : 0, v6 ? 75 : 19, &one, 4);
    long on = bind_(s, a, v6 ? 28 : 16);
    memset(got, 0, sizeof got);
    long nr = name_(s, got);
    int address_ok = nr == 0 && (v6 ? memcmp(got + 8, a + 8, 16) == 0 : memcmp(got + 4, a + 4, 4) == 0);
    long want_off = v6 || kind == 3 ? -99 : OFF4_RESULT;
    long want_on = !v6 && kind == 3 ? PING4_ON_RESULT : 0;
    int want_address = !v6 && kind == 3 ? PING4_ADDRESS_OK : 1;
    snprintf(msg, sizeof msg, "%c %s: off %ld, set %ld, on %ld, name %ld address %d (want off %ld, on %ld, address %d)", v6 ? 'B' : 'A', names[kind], off, sr, on, nr, address_ok, want_off, want_on, want_address);
    check(off == want_off && sr == 0 && on == want_on && address_ok == want_address, msg);
    close_(s);
    return off == want_off && sr == 0 && on == want_on && address_ok == want_address;
}
int main(void) {
    print("hello491: IP_TRANSPARENT / IPV6_TRANSPARENT allow nonlocal bind\n");
    long range = open_ping_range();
    snprintf(msg, sizeof msg, "setup: ping_group_range write %ld (3)", range);
    check(range == 3, msg);
    int ok = 1;
    for (int kind = 0; kind < 4; kind++) ok &= one_kind(0, kind);
    for (int kind = 0; kind < 4; kind++) ok &= one_kind(1, kind);
    (void)ok;
    restore_ping_range();
    print(failures ? "hello491: FAIL\n" : "hello491: PASS\n");
    return failures ? 1 : 0;
}
