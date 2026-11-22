/* hello490: IP_FREEBIND / IPV6_FREEBIND allow bind() to a nonlocal address (inet_addr_valid_or_nonlocal /
 * ipv6_can_nonlocal_bind). A: UDP, TCP and raw IPv4; B: the same over IPv6. Without the option the address is EADDRNOTAVAIL,
 * with it bind succeeds and getsockname keeps the address. The current host accepts IPv4 nonlocal bind even with the option off,
 * so OFF4_RESULT records that host difference; the target checks EADDRNOTAVAIL. The two option names' shared flag is host-policy-tested.
 * Measured on the host (build with -DHOST, run in unshare --map-auto --map-root-user -n). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
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
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long name_(long s, void *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
#endif
#ifdef HOST
#define OFF4_RESULT 0
#else
#define OFF4_RESULT -99
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello490:   ok   " : "hello490:   FAIL ");
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
static int one_kind(int v6, int type) {
    static const char *const names[] = { "UDP", "TCP", "raw" };
    long s = sock(v6 ? 10 : 2, type == 3 ? 3 : type, type == 3 ? (v6 ? 58 : 1) : 0);
    unsigned char a[28], got[28];
    if (v6) mk6(a); else mk4(a);
    long off = bind_(s, a, v6 ? 28 : 16);
    if (off == 0) {
        close_(s);
        s = sock(v6 ? 10 : 2, type == 3 ? 3 : type, type == 3 ? (v6 ? 58 : 1) : 0);
    }
    int one = 1;
    long sr = setopt_(s, v6 ? 41 : 0, v6 ? 78 : 15, &one, 4);
    long on = bind_(s, a, v6 ? 28 : 16);
    memset(got, 0, sizeof got);
    long nr = name_(s, got);
    int address_ok = nr == 0 && (v6 ? memcmp(got + 8, a + 8, 16) == 0 : memcmp(got + 4, a + 4, 4) == 0);
    snprintf(msg, sizeof msg, "%c %s: off %ld, set %ld, on %ld, name %ld address %d (-99 0 0 0 1)", v6 ? 'B' : 'A', names[type == 2 ? 0 : type == 1 ? 1 : 2], off, sr, on, nr, address_ok);
    check(off == (v6 ? -99 : OFF4_RESULT) && sr == 0 && on == 0 && address_ok, msg);
    close_(s);
    return off == (v6 ? -99 : OFF4_RESULT) && sr == 0 && on == 0 && address_ok;
}
int main(void) {
    print("hello490: IP_FREEBIND / IPV6_FREEBIND allow nonlocal bind\n");
    int ok = 1;
    for (int type = 2; type >= 0; type--) ok &= one_kind(0, type == 0 ? 3 : type == 1 ? 1 : 2);
    for (int type = 2; type >= 0; type--) ok &= one_kind(1, type == 0 ? 3 : type == 1 ? 1 : 2);
    (void)ok;
    print(failures ? "hello490: FAIL\n" : "hello490: PASS\n");
    return failures ? 1 : 0;
}
