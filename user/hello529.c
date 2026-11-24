/* hello529: a link-local nameserver with a "%scope" in /etc/resolv.conf (glibc 2.44 res_init/res_send, measured). A stand-in DNS server
 * on [::]:53 answers A queries with 10.5.26.6 and PTR queries with v6ns.test, an IPv4 one on 127.0.0.1:53 answers A with 10.5.26.4,
 * and both log each question. L is the link-local address of eth0 (fe80::EUI-64 of its MAC). A: "nameserver L%eth0": gethostbyname
 * asks the IPv6 server through eth0 and gets 10.5.26.6; B: the scope as a number ("L%2"); C: L with no scope, then 127.0.0.1: the
 * first server fails at once (no wait) and the IPv4 one answers; D: L%lo (an interface without a link-local address) likewise;
 * E: gethostbyaddr through L%eth0; F: "::1%bogus": an address that needs no scope ignores the suffix. Needs root (port 53 and
 * /etc). Measured with -DHOST through glibc in `unshare -m -n` with a dummy link standing in for eth0 (resolv.conf and
 * nsswitch.conf "hosts: files dns" bind-mounted). */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define CONF_PATH (getenv("R529") ? getenv("R529") : "/etc/resolv.conf")
#define DEV (getenv("D529") ? getenv("D529") : "eth0")
#include <sys/ioctl.h>
#include <sys/time.h>
static long ifioctl(unsigned long cmd, const char *name, unsigned char out[40]) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    memset(out, 0, 40);
    strncpy((char *)out, name, 15);
    long rc = ioctl(s, cmd, out) < 0 ? -errno : 0;
    close(s);
    return rc;
}
static long sock_udp(void) { int s = socket(AF_INET, SOCK_DGRAM, 0); return s < 0 ? -errno : s; }
static long bind4(long s, const unsigned char *sa) { return bind((int)s, (const struct sockaddr *)sa, 16) < 0 ? -errno : 0; }
static long recvfrom4(long s, unsigned char *b, long n, unsigned char *sa) {
    socklen_t l = 16;
    long r = recvfrom((int)s, b, (size_t)n, 0, (struct sockaddr *)sa, &l);
    return r < 0 ? -errno : r;
}
static long sendto4(long s, const unsigned char *b, long n, const unsigned char *sa) {
    long r = sendto((int)s, b, (size_t)n, 0, (const struct sockaddr *)sa, 16);
    return r < 0 ? -errno : r;
}
static void closefd(long s) { close((int)s); }
static long sock_udp6(void) {
    int s = socket(AF_INET6, SOCK_DGRAM, 0);
    int one = 1;
    if (s >= 0) setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s < 0 ? -errno : s;
}
static long bind6(long s, const unsigned char *sa) { return bind((int)s, (const struct sockaddr *)sa, 28) < 0 ? -errno : 0; }
static long recvfrom6(long s, unsigned char *b, long n, unsigned char *sa) {
    socklen_t l = 28;
    long r = recvfrom((int)s, b, (size_t)n, 0, (struct sockaddr *)sa, &l);
    return r < 0 ? -errno : r;
}
static long sendto6(long s, const unsigned char *b, long n, const unsigned char *sa) {
    long r = sendto((int)s, b, (size_t)n, 0, (const struct sockaddr *)sa, 28);
    return r < 0 ? -errno : r;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/netdb.h"
#include "../lib/moqi_libc/include/fcntl.h"
#define CONF_PATH "/etc/resolv.conf"
#define DEV "eth0"
#include "../lib/moqi_libc/include/time.h"
static long ifioctl(unsigned long cmd, const char *name, unsigned char out[40]) {
    long s = syscall3(SYS_socket, 2, 2, 0);
    memset(out, 0, 40);
    strncpy((char *)out, name, 15);
    long rc = syscall3(SYS_ioctl, s, (long)cmd, (long)out);
    syscall1(SYS_close, s);
    return rc;
}
#define NR_SENDTO 121
#define NR_RECVFROM 122
static long sock_udp(void) { return syscall3(SYS_socket, 2, 2, 0); }
static long bind4(long s, const unsigned char *sa) { return syscall3(SYS_bind, s, (long)sa, 16); }
static long recvfrom4(long s, unsigned char *b, long n, unsigned char *sa) {
    unsigned l = 16;
    for (;;) {
        long r = syscall6(NR_RECVFROM, s, (long)b, n, 0, (long)sa, (long)&l);
        if (r != -11) return r;
        syscall1(SYS_netpoll, 0);
    }
}
static long sendto4(long s, const unsigned char *b, long n, const unsigned char *sa) { return syscall6(NR_SENDTO, s, (long)b, n, 0, (long)sa, 16); }
static void closefd(long s) { syscall1(SYS_close, s); }
static long sock_udp6(void) { return syscall3(SYS_socket, 10, 2, 0); }
static long bind6(long s, const unsigned char *sa) { return syscall3(SYS_bind, s, (long)sa, 28); }
static long recvfrom6(long s, unsigned char *b, long n, unsigned char *sa) {
    unsigned l = 28;
    for (;;) {
        long r = syscall6(NR_RECVFROM, s, (long)b, n, 0, (long)sa, (long)&l);
        if (r != -11) return r;
        syscall1(SYS_netpoll, 0);
    }
}
static long sendto6(long s, const unsigned char *b, long n, const unsigned char *sa) { return syscall6(NR_SENDTO, s, (long)b, n, 0, (long)sa, 28); }
#endif
static int failures;
static char msg[1000];
static void check(int ok, const char *w) {
    print(ok ? "hello529:   ok   " : "hello529:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void sa4(unsigned char sa[16], unsigned a, unsigned b, unsigned c, unsigned d, unsigned port) {
    memset(sa, 0, 16);
    sa[0] = 2;
    sa[2] = (unsigned char)(port >> 8);
    sa[3] = (unsigned char)port;
    sa[4] = (unsigned char)a; sa[5] = (unsigned char)b; sa[6] = (unsigned char)c; sa[7] = (unsigned char)d;
}
static int write_conf(const char *text) {
    int fd = (int)open(CONF_PATH, 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
/* The question name of a query as "a.b.c", into `out`; the question type in *qtype. 0 on success. */
static int qname(const unsigned char *q, long n, char *out, size_t cap, int *qtype) {
    long i = 12;
    size_t o = 0;
    while (i < n && q[i]) {
        int l = q[i++];
        if (i + l > n || o + (size_t)l + 2 > cap) return -1;
        if (o) out[o++] = '.';
        memcpy(out + o, q + i, (size_t)l);
        o += (size_t)l;
        i += l;
    }
    out[o] = 0;
    if (i + 5 > n) return -1;
    *qtype = q[i + 1] << 8 | q[i + 2];
    return 0;
}
static void answer(unsigned char *r, long *len, const unsigned char *q, long n, int qtype, int last) {
    memcpy(r, q, (size_t)n);
    *len = n;
    r[2] = 0x81;
    r[3] = 0x80;
    r[6] = 0; r[7] = (qtype == 1 || qtype == 12) ? 1 : 0;
    r[8] = r[9] = r[10] = r[11] = 0;
    if (qtype == 1) {
        unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 26, (unsigned char)last};
        memcpy(r + *len, ans, sizeof ans);
        *len += (long)sizeof ans;
    } else if (qtype == 12) {
        unsigned char ans[] = {0xc0, 0x0c, 0, 12, 0, 1, 0, 0, 0, 60, 0, 11, 4, 'v', '6', 'n', 's', 4, 't', 'e', 's', 't', 0};
        memcpy(r + *len, ans, sizeof ans);
        *len += (long)sizeof ans;
    }
}
static void serve6(int report) {
    long s = sock_udp6();
    unsigned char sa[28], from[28], q[512], r[600];
    memset(sa, 0, sizeof sa);
    sa[0] = 10; sa[2] = 0; sa[3] = 53; /* [::]:53 */
    long bres = s < 0 ? s : bind6(s, sa);
    if (s < 0 || bres != 0) {
        char e[96];
        snprintf(e, sizeof e, "hello529:   .. IPv6 server: socket %ld bind %ld\n", s, bres);
        print(e);
        if (write(report, "X", 1) != 1) _exit(3);
        _exit(2);
    }
    if (write(report, "R", 1) != 1) _exit(3);
    for (;;) {
        long n = recvfrom6(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        char line[16];
        int ll = snprintf(line, sizeof line, "6:%d;", qtype);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        long len = 0;
        answer(r, &len, q, n, qtype, 6);
        sendto6(s, r, len, from);
    }
}
static void serve4(int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512], r[600];
    sa4(sa, 127, 0, 0, 1, 53);
    long bres = s < 0 ? s : bind4(s, sa);
    if (s < 0 || bres != 0) {
        char e[96];
        snprintf(e, sizeof e, "hello529:   .. IPv4 server: socket %ld bind %ld\n", s, bres);
        print(e);
        _exit(2);
    }
    if (write(report, "R", 1) != 1) _exit(3);
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        char line[16];
        int ll = snprintf(line, sizeof line, "4:%d;", qtype);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        long len = 0;
        answer(r, &len, q, n, qtype, 4);
        sendto4(s, r, len, from);
    }
}
static int rep_fd = -1;
static char seen[300];
static void take_log(void) {
    size_t n = 0;
    for (int idle = 0; idle < 60 && n + 1 < sizeof seen;) {
        long k = (long)read(rep_fd, seen + n, 1);
        if (k <= 0) { idle++; usleep(5000); continue; }
        idle = 0;
        n++;
    }
    seen[n] = 0;
}
static unsigned last(struct hostent *h) { return h && h->h_addr_list[0] ? (unsigned char)h->h_addr_list[0][3] : 0; }
static long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, 0);
    return (long)tv.tv_sec * 1000 + (long)tv.tv_usec / 1000;
}
int main(void) {
    print("hello529: a link-local nameserver with a scope\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    unsigned char hw[40];
    long hr = ifioctl(0x8927 /* SIOCGIFHWADDR */, DEV, hw);
    const unsigned char *m = hw + 18;
    char ll[64];
    snprintf(ll, sizeof ll, "fe80::%02x%02x:%02xff:fe%02x:%02x%02x", m[0] ^ 2, m[1], m[2], m[3], m[4], m[5]);
    int p[2];
    int pr = pipe(p);
    long pids[2] = {-1, -1};
    if (pr == 0 && (pids[0] = (long)fork()) == 0) { close(p[0]); serve6(p[1]); }
    if (pr == 0 && (pids[1] = (long)fork()) == 0) { close(p[0]); serve4(p[1]); }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready[2] = {0, 0};
    for (int i = 0; i < 2 && pr == 0; i++)
        if (read(p[0], &ready[i], 1) != 1) ready[i] = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
    char conf[200];

    snprintf(conf, sizeof conf, "nameserver %s%%%s\noptions timeout:2 attempts:1\n", ll, DEV);
    int wa = write_conf(conf);
    unsigned a = last(gethostbyname("x529.test"));
    take_log();
    snprintf(msg, sizeof msg, "A: nameserver %s%%%s: .%u, asked '%s' (hwaddr %ld conf %d ready %c%c; .6, 6:1;)", ll, DEV, a, seen, hr, wa,
             ready[0] ? ready[0] : '-', ready[1] ? ready[1] : '-');
    check(hr == 0 && wa == 0 && ready[0] == 'R' && ready[1] == 'R' && a == 6 && strcmp(seen, "6:1;") == 0, msg);

    unsigned char ix[40];
    long xr = ifioctl(0x8933 /* SIOCGIFINDEX */, DEV, ix);
    snprintf(conf, sizeof conf, "nameserver %s%%%u\noptions timeout:2 attempts:1\n", ll, (unsigned)ix[16]);
    write_conf(conf);
    unsigned b = last(gethostbyname("y529.test"));
    take_log();
    snprintf(msg, sizeof msg, "B: %s%%%u: .%u, asked '%s' (index %ld; .6, 6:1;)", ll, (unsigned)ix[16], b, seen, xr);
    check(xr == 0 && b == 6 && strcmp(seen, "6:1;") == 0, msg);

    snprintf(conf, sizeof conf, "nameserver %s\nnameserver 127.0.0.1\noptions timeout:2 attempts:1\n", ll);
    write_conf(conf);
    long t0 = now_ms();
    unsigned c = last(gethostbyname("z529.test"));
    long tc = now_ms() - t0;
    take_log();
    snprintf(msg, sizeof msg, "C: %s with no scope, then 127.0.0.1: .%u in %ld ms, asked '%s' (.4 well under 2000 ms, 4:1;)", ll, c, tc, seen);
    check(c == 4 && tc < 1500 && strcmp(seen, "4:1;") == 0, msg);

    snprintf(conf, sizeof conf, "nameserver %s%%lo\nnameserver 127.0.0.1\noptions timeout:2 attempts:1\n", ll);
    write_conf(conf);
    t0 = now_ms();
    unsigned d = last(gethostbyname("v529.test"));
    long td = now_ms() - t0;
    take_log();
    snprintf(msg, sizeof msg, "D: %s%%lo, then 127.0.0.1: .%u in %ld ms, asked '%s' (.4 well under 2000 ms, 4:1;)", ll, d, td, seen);
    check(d == 4 && td < 1500 && strcmp(seen, "4:1;") == 0, msg);

    snprintf(conf, sizeof conf, "nameserver %s%%%s\noptions timeout:2 attempts:1\n", ll, DEV);
    write_conf(conf);
    unsigned char ip[4] = {10, 5, 29, 9};
    struct hostent *h = gethostbyaddr(ip, 4, AF_INET);
    char nm[64];
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    take_log();
    snprintf(msg, sizeof msg, "E: gethostbyaddr through %s%%%s: %s, asked '%s' (v6ns.test, 6:12;)", ll, DEV, nm, seen);
    check(strcmp(nm, "v6ns.test") == 0 && strcmp(seen, "6:12;") == 0, msg);

    write_conf("nameserver ::1%bogus\noptions timeout:2 attempts:1\n");
    unsigned f = last(gethostbyname("w529.test"));
    take_log();
    snprintf(msg, sizeof msg, "F: ::1%%bogus: .%u, asked '%s' (.6, 6:1;)", f, seen);
    check(f == 6 && strcmp(seen, "6:1;") == 0, msg);

    for (int i = 0; i < 2; i++) if (pids[i] > 0) { kill(pids[i], SIGKILL); waitpid(pids[i], 0, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "G: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello529: FAIL\n" : "hello529: PASS\n");
    return failures ? 1 : 0;
}
