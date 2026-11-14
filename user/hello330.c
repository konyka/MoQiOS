/* hello330: the owner a SO_REUSEPORT port group is checked against is the socket's, fixed when socket() created it from the caller's fsuid
 * (Linux net/socket.c sock_alloc: inode->i_uid = current_fsuid(); net/core/sock.c sock_init_data: sk_uid from that inode; the bind
 * conflict checks in net/ipv4/inet_connection_sock.c and net/ipv4/udp.c compare sk_uid). Runs as root holding CAP_SETUID. Measured on the
 * host (build with -DHOST, run under `unshare --map-auto --map-root-user --net` after `ip link set lo up`), for TCP and UDP alike:
 *   A. a socket created as root that binds after the process became uid 1000 belongs to root: a uid 1000 socket cannot join (EADDRINUSE);
 *   B. a socket created as uid 1000 that binds after the process went back to root belongs to 1000: a root socket cannot join;
 *   C. a socket created by root with fsuid 1000 belongs to 1000: after fsuid returns to 0 a root socket cannot join;
 *   D. two root sockets share the port;
 *   E. a socket created as uid 1000 and one created by root with fsuid 1000 share the port. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sfsuid(long id) { return syscall(SYS_setfsuid, id); }
static long sresuid(long r, long e, long s) { return syscall(SYS_setresuid, r, e, s) == -1 ? -errno : 0; }
static long sock(int type) {
    long s = socket(AF_INET, type, 0);
    int one = 1;
    if (s >= 0) setsockopt((int)s, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    return s < 0 ? -errno : s;
}
static long bnd(long s, int port) {
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    return bind((int)s, (struct sockaddr *)&a, sizeof a) == 0 ? 0 : -errno;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sfsuid(long id) { return syscall1(504, id); }
static long sresuid(long r, long e, long s) { return syscall3(178, r, e, s); }
static long sock(int type) {
    long s = syscall3(117, 2, type, 0);
    int one = 1;
    if (s >= 0) syscall5(132, s, 1, 15, (long)&one, 4);
    return s;
}
static long bnd(long s, int port) {
    unsigned char a[16] = { 0 };
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
    return syscall3(118, s, (long)a, 16);
}
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#endif

#define EADDRINUSE_ 98

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello330:   ok   " : "hello330:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static long opened[32];
static int nopen;
static long keep(long s) {
    if (s >= 0 && nopen < 32) opened[nopen++] = s;
    return s;
}

static void one_type(int type, const char *n, int base) {
    long s1 = keep(sock(type));
    long u = sresuid(1000, 1000, 0);
    long a1 = bnd(s1, base);
    long s2 = keep(sock(type));
    long a2 = bnd(s2, base);
    long back = sresuid(0, 0, 0);
    snprintf(msg, sizeof msg, "%s A: created as root, bound as uid 1000: binds (%ld), a uid 1000 socket is refused (%ld) [ids %ld %ld]", n, a1, a2, u,
             back);
    check(u == 0 && back == 0 && a1 == 0 && a2 == -EADDRINUSE_, msg);

    u = sresuid(1000, 1000, 0);
    long s3 = keep(sock(type));
    back = sresuid(0, 0, 0);
    long b1 = bnd(s3, base + 1);
    long s4 = keep(sock(type));
    long b2 = bnd(s4, base + 1);
    snprintf(msg, sizeof msg, "%s B: created as uid 1000, bound as root: binds (%ld), a root socket is refused (%ld) [ids %ld %ld]", n, b1, b2, u, back);
    check(u == 0 && back == 0 && b1 == 0 && b2 == -EADDRINUSE_, msg);

    sfsuid(1000);
    long s5 = keep(sock(type));
    sfsuid(0);
    long fs_now = sfsuid(-1);
    long c1 = bnd(s5, base + 2);
    long s6 = keep(sock(type));
    long c2 = bnd(s6, base + 2);
    snprintf(msg, sizeof msg, "%s C: created by root with fsuid 1000: binds (%ld), a root socket is refused (%ld) [fsuid %ld]", n, c1, c2, fs_now);
    check(fs_now == 0 && c1 == 0 && c2 == -EADDRINUSE_, msg);

    long s7 = keep(sock(type)), s8 = keep(sock(type));
    long d1 = bnd(s7, base + 3);
    long d2 = bnd(s8, base + 3);
    snprintf(msg, sizeof msg, "%s D: two root sockets share the port (%ld %ld)", n, d1, d2);
    check(d1 == 0 && d2 == 0, msg);

    u = sresuid(1000, 1000, 0);
    long s9 = keep(sock(type));
    long e1 = bnd(s9, base + 4);
    back = sresuid(0, 0, 0);
    sfsuid(1000);
    long s10 = keep(sock(type));
    sfsuid(0);
    long e2 = bnd(s10, base + 4);
    snprintf(msg, sizeof msg, "%s E: a uid 1000 socket and one created with fsuid 1000 share the port (%ld %ld)", n, e1, e2);
    check(u == 0 && back == 0 && e1 == 0 && e2 == 0, msg);

    for (int i = 0; i < nopen; i++) close((int)opened[i]);
    nopen = 0;
}

int main(void) {
    print("hello330: SO_REUSEPORT owner is the socket creator's fsuid\n");
    one_type(SOCK_STREAM, "tcp", 18600);
    one_type(SOCK_DGRAM, "udp", 18610);
    print(failures ? "hello330: FAIL\n" : "hello330: PASS\n");
    return failures ? 1 : 0;
}
