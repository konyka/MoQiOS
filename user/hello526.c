/* hello526: IPv6 nameservers in /etc/resolv.conf (glibc 2.44 res_init/res_send, measured). A stand-in DNS server on [::1]:53 answers A
 * queries with 10.5.26.6 and PTR queries with v6ns.test, and logs each question; an IPv4 one on 127.0.0.1:53 answers A with
 * 10.5.26.4. A: "nameserver ::1" alone: gethostbyname asks the IPv6 server and gets 10.5.26.6; B: ::1 first and 127.0.0.1 second:
 * the IPv6 server answers, the IPv4 one is not asked; C: a silent IPv6 address (2001:db8::1, routed nowhere here) first: the lookup
 * goes on to 127.0.0.1; D: gethostbyaddr through the IPv6 server; E: ::ffff:127.0.0.1 is the IPv4 server. Needs root (port 53 and
 * /etc). Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf and nsswitch.conf "hosts: files dns" bind-mounted). */
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
#define CONF_PATH (getenv("R526") ? getenv("R526") : "/etc/resolv.conf")
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
static long sock_udp6(void) { int s = socket(AF_INET6, SOCK_DGRAM, 0); return s < 0 ? -errno : s; }
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
    print(ok ? "hello526:   ok   " : "hello526:   FAIL ");
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
    sa[0] = 10; sa[2] = 0; sa[3] = 53; sa[23] = 1; /* [::1]:53 */
    long bres = s < 0 ? s : bind6(s, sa);
    if (s < 0 || bres != 0) {
        char e[64];
        snprintf(e, sizeof e, "hello526:   .. IPv6 server: socket %ld bind %ld\n", s, bres);
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
        char e[64];
        snprintf(e, sizeof e, "hello526:   .. IPv4 server: socket %ld bind %ld\n", s, bres);
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
int main(void) {
    print("hello526: IPv6 nameservers\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
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

    int wa = write_conf("nameserver ::1\noptions timeout:1 attempts:1\n");
    unsigned a = last(gethostbyname("x526.test"));
    take_log();
    snprintf(msg, sizeof msg, "A: nameserver ::1: .%u, asked '%s' (conf %d ready %c%c; .6, 6:1;)", a, seen, wa, ready[0] ? ready[0] : '-', ready[1] ? ready[1] : '-');
    check(wa == 0 && ready[0] == 'R' && ready[1] == 'R' && a == 6 && strncmp(seen, "6:1;", 4) == 0 && !strstr(seen, "4:"), msg);

    int wb = write_conf("nameserver ::1\nnameserver 127.0.0.1\noptions timeout:1 attempts:1\n");
    unsigned b = last(gethostbyname("y526.test"));
    take_log();
    snprintf(msg, sizeof msg, "B: ::1 then 127.0.0.1: .%u, asked '%s' (conf %d; .6, the IPv6 server only)", b, seen, wb);
    check(wb == 0 && b == 6 && strstr(seen, "6:1;") && !strstr(seen, "4:"), msg);

    int wc = write_conf("nameserver 2001:db8::1\nnameserver 127.0.0.1\noptions timeout:1 attempts:1\n");
    unsigned c = last(gethostbyname("z526.test"));
    take_log();
    snprintf(msg, sizeof msg, "C: a silent IPv6 server first: .%u, asked '%s' (conf %d; .4)", c, seen, wc);
    check(wc == 0 && c == 4 && strstr(seen, "4:1;"), msg);

    int wd = write_conf("nameserver ::1\noptions timeout:1 attempts:1\n");
    unsigned char ip[4] = {10, 5, 26, 9};
    struct hostent *h = gethostbyaddr(ip, 4, AF_INET);
    char nm[64];
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    take_log();
    snprintf(msg, sizeof msg, "D: gethostbyaddr through ::1: %s, asked '%s' (conf %d; v6ns.test, 6:12;)", nm, seen, wd);
    check(wd == 0 && strcmp(nm, "v6ns.test") == 0 && strstr(seen, "6:12;"), msg);

    int we = write_conf("nameserver ::ffff:127.0.0.1\noptions timeout:1 attempts:1\n");
    unsigned e = last(gethostbyname("w526.test"));
    take_log();
    snprintf(msg, sizeof msg, "E: ::ffff:127.0.0.1: .%u, asked '%s' (conf %d; .4, the IPv4 server)", e, seen, we);
    check(we == 0 && e == 4 && strstr(seen, "4:1;"), msg);

    for (int i = 0; i < 2; i++) if (pids[i] > 0) { kill(pids[i], SIGKILL); waitpid(pids[i], 0, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello526: FAIL\n" : "hello526: PASS\n");
    return failures ? 1 : 0;
}
