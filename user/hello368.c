/* hello368: the IPv4 next hop. An address outside the interface's subnet is reached through the default gateway, so it is the
 * gateway that is resolved with ARP, not the address itself (Linux fib_lookup picks the gateway route; the neighbour is the
 * gateway). A TCP SYN that waits for ARP counts as sent: a non-blocking connect is EINPROGRESS (Linux queues the SYN on the
 * neighbour entry) instead of failing at once. Measured on the host (build with -DHOST, run in `unshare -rn` with a veth pair
 * whose far end has no address, so nothing answers ARP:
 *   ip link set lo up; ip link add v0 type veth peer name v1; ip link set v1 up; ip link set v0 up;
 *   ip addr add 10.0.2.15/24 dev v0; ip route add default via 10.0.2.2 dev v0):
 *   A. a datagram to the gateway 10.0.2.2 is sent (MoQiOS: retried until ARP has the gateway), then datagrams to the off-link
 *      192.0.2.1 and 198.51.100.7 are sent at once;
 *   B. a non-blocking connect to the off-link 192.0.2.1 is EINPROGRESS;
 *   C. a non-blocking connect to the on-link 10.0.2.99, which does not answer ARP, is EINPROGRESS. */
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
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long nbsock(void) { return rc(socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM4(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long usock(void) { return syscall3(117, 2, 2, 0); }
static long nbsock(void) { return syscall3(117, 2, 1 | 0x800, 0); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM4(a) do { (a)[0] = 2; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello368:   ok   " : "hello368:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, int a, int b, int c, int d, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM4(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[4] = (unsigned char)a; s[5] = (unsigned char)b; s[6] = (unsigned char)c; s[7] = (unsigned char)d;
}
int main(void) {
    print("hello368: the IPv4 next hop\n");
    unsigned char gw[16], off1[16], off2[16], near[16];
    mk4(gw, 10, 0, 2, 2, 19809);
    mk4(off1, 192, 0, 2, 1, 19809);
    mk4(off2, 198, 51, 100, 7, 19809);
    mk4(near, 10, 0, 2, 99, 19809);

    long u = usock();
    long g = -1;
    int tries = 0;
    while (tries < 100 && (g = sendto_(u, "x", 1, gw)) != 1) { tries++; pump(); }
    long o1 = sendto_(u, "x", 1, off1), o2 = sendto_(u, "x", 1, off2);
    snprintf(msg, sizeof msg, "A: to the gateway %ld (after %d retries), to 192.0.2.1 %ld, to 198.51.100.7 %ld (1 1 1)", g, tries, o1, o2);
    check(g == 1 && o1 == 1 && o2 == 1, msg);
    close_(u);

    long t = nbsock();
    long tc = connect_(t, off1);
    snprintf(msg, sizeof msg, "B: non-blocking connect to 192.0.2.1 %ld (-115)", tc);
    check(tc == -115, msg);
    close_(t);

    long n = nbsock();
    long nc = connect_(n, near);
    snprintf(msg, sizeof msg, "C: non-blocking connect to 10.0.2.99 %ld (-115)", nc);
    check(nc == -115, msg);
    close_(n);

    print(failures ? "hello368: FAIL\n" : "hello368: PASS\n");
    return failures ? 1 : 0;
}
