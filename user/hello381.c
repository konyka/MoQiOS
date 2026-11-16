/* hello381: one IPv6 UDP socket joins many multicast groups (Linux ipv6_sock_mc_join allocates one ipv6_mc_socklist per group from
 * the socket's optmem; with the default net.core.optmem_max a socket joined 2340 groups on the host before ENOMEM). MoQiOS keeps
 * 64 groups per socket. Measured on the host (build with -DHOST, run in `unshare -rn` after `ip link set lo up`; lo is interface 1
 * there as in MoQiOS):
 *   J. 64 different groups ff02::1:0:1 .. ff02::1:0:40 joined on lo all succeed, joining the first again is EADDRINUSE;
 *   D. dropping each of the 64 succeeds, dropping the first again is EADDRNOTAVAIL. */
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
static long v6only(long s) {
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long usock(void) { return v6only(rc(socket(AF_INET6, SOCK_DGRAM, 0))); }
static long tsock(void) { return v6only(rc(socket(AF_INET6, SOCK_STREAM, 0))); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long setopt(long s, int level, int name, const void *v, int len) { return rc(setsockopt((int)s, level, name, v, len)); }
static long getopt6(long s, int name) { int v = -7; socklen_t l = 4; long r = rc(getsockopt((int)s, IPPROTO_IPV6, name, &v, &l)); return r < 0 ? r : v; }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
#define IPPROTO_IPV6 41
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define IPV6_MULTICAST_IF 17
#define IPV6_MULTICAST_HOPS 18
#define IPV6_MULTICAST_LOOP 19
#define IPV6_ADD_MEMBERSHIP 20
#define IPV6_DROP_MEMBERSHIP 21
#define IPV6_MULTICAST_ALL 29
static long usock(void) { return syscall3(117, AF_INET6, 2, 0); }
static long tsock(void) { return syscall3(117, AF_INET6, 1, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long setopt(long s, int level, int name, const void *v, int len) { return syscall5(132, s, level, name, (long)v, len); }
static long getopt6(long s, int name) { int v = -7; int l = 4; long r = syscall5(133, s, IPPROTO_IPV6, name, (long)&v, (long)&l); return r < 0 ? r : v; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello381:   ok   " : "hello381:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long member(long s, int name, const unsigned char *group, int ifindex) {
    unsigned char m[20];
    for (int i = 0; i < 20; i++) m[i] = 0;
    for (int i = 0; i < 16; i++) m[i] = group[i];
    m[16] = (unsigned char)ifindex; m[17] = (unsigned char)(ifindex >> 8);
    return setopt(s, IPPROTO_IPV6, name, m, 20);
}
static void group(unsigned char *g, int i) {
    for (int k = 0; k < 16; k++) g[k] = 0;
    g[0] = 0xff; g[1] = 0x02; g[11] = 1; g[15] = (unsigned char)(i + 1);
}
#define N 64
int main(void) {
    print("hello381: one IPv6 socket joins 64 multicast groups\n");
    unsigned char g[16];
    long s = usock();
    int joined = 0;
    long first_err = 0;
    for (int i = 0; i < N; i++) {
        group(g, i);
        long r = member(s, IPV6_ADD_MEMBERSHIP, g, 1);
        if (r == 0) joined++;
        else if (first_err == 0) first_err = r;
    }
    group(g, 0);
    long again = member(s, IPV6_ADD_MEMBERSHIP, g, 1);
    snprintf(msg, sizeof msg, "J: socket %ld; %d of %d groups joined on lo (first error %ld); the first again %ld (%d 0 -98)", s, joined, N, first_err, again, N);
    check(s >= 0 && joined == N && again == -98, msg);

    int dropped = 0;
    for (int i = 0; i < N; i++) {
        group(g, i);
        if (member(s, IPV6_DROP_MEMBERSHIP, g, 1) == 0) dropped++;
    }
    group(g, 0);
    long d2 = member(s, IPV6_DROP_MEMBERSHIP, g, 1);
    snprintf(msg, sizeof msg, "D: %d of %d dropped; the first again %ld (%d -99)", dropped, N, d2, N);
    check(dropped == N && d2 == -99, msg);
    close_(s);
    print(failures ? "hello381: FAIL\n" : "hello381: PASS\n");
    return failures ? 1 : 0;
}
