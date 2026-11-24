/* hello542: "options edns0" in /etc/resolv.conf adds an EDNS(0) OPT record to every query (glibc 2.44 res_mkquery/res_nopt,
 * measured): ARCOUNT 1 and, after the question, a root-owned record of type 41 with class 1200 (the UDP payload size), TTL 0 and
 * no data, the same over UDP and TCP. A stand-in server on 127.0.0.1:53 answers A queries with 10.5.42.1 (UDP) or 10.5.42.2 (TCP)
 * and others with NODATA; it logs "u+;" for a UDP query that ends in exactly that record, "u-;" for one without any additional
 * record, "u?;" for anything else, and "c;" then "t+;"/"t-;"/"t?;" for a TCP connection and its query. Needs root (port 53 and
 * /etc). Measured with -DHOST through glibc in `unshare -r -m -n` (lo up, resolv.conf and nsswitch.conf bind-mounted). Each case
 * prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
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
/* SO_REUSEADDR: an earlier test's connections to port 53 may still be in TIME_WAIT, which blocks a plain bind. */
static long sock_tcp(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    if (s >= 0) setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    return s < 0 ? -errno : s;
}
static long listen4(long s) { return listen((int)s, 4) < 0 ? -errno : 0; }
static long accept4b(long s) { int c = accept((int)s, 0, 0); return c < 0 ? -errno : c; }
static long rd(long s, void *b, long n) { long r = read((int)s, b, (size_t)n); return r < 0 ? -errno : r; }
static long wrt(long s, const void *b, long n) { long r = write((int)s, b, (size_t)n); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/netdb.h"
#include "../lib/moqi_libc/include/fcntl.h"
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
static long sock_tcp(void) {
    long s = syscall3(SYS_socket, 2, 1, 0);
    int one = 1;
    if (s >= 0) syscall5(132, s, 1, 2, (long)&one, 4); /* setsockopt(SOL_SOCKET, SO_REUSEADDR) */
    return s;
}
static long listen4(long s) { return syscall2(SYS_listen, s, 4); }
static long accept4b(long s) {
    for (;;) {
        long r = syscall4(SYS_accept4, s, 0, 0, 0);
        if (r != -11) return r;
        syscall1(SYS_netpoll, 0);
    }
}
static long rd(long s, void *b, long n) {
    for (;;) {
        long r = syscall3(SYS_read, s, (long)b, n);
        if (r != -11) return r;
        syscall1(SYS_netpoll, 0);
    }
}
static long wrt(long s, const void *b, long n) { return syscall3(SYS_write, s, (long)b, n); }
#endif
static int failures;
static char msg[800];
static void check(int ok, const char *w) {
    print(ok ? "hello542:   ok   " : "hello542:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void sa4(unsigned char sa[16], unsigned port) {
    memset(sa, 0, 16);
    sa[0] = 2;
    sa[2] = (unsigned char)(port >> 8);
    sa[3] = (unsigned char)port;
    sa[4] = 127; sa[7] = 1;
}
static int write_file(const char *path, const char *text) {
    int fd = (int)open(path, 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
static void note(int report, const char *s) {
    if (write(report, s, strlen(s)) != (long)strlen(s)) _exit(4);
}
/* '+' for a query that ends in glibc's OPT record (ARCOUNT 1, root owner, type 41, class 1200, TTL 0, no data), '-' for one with
 * no additional record, '?' for anything else; the question's end and type into *qe and *qtype. */
static char opt_kind(const unsigned char *q, long n, long *qe, int *qtype) {
    long i = 12;
    while (i < n && q[i]) i += q[i] + 1;
    if (i + 5 > n) return '?';
    *qtype = q[i + 1] << 8 | q[i + 2];
    *qe = i + 5;
    int ar = q[10] << 8 | q[11];
    static const unsigned char opt[11] = {0, 0, 0x29, 0x04, 0xb0, 0, 0, 0, 0, 0, 0};
    if (ar == 0 && n == *qe) return '-';
    if (ar == 1 && n == *qe + 11 && memcmp(q + *qe, opt, 11) == 0) return '+';
    return '?';
}
/* The reply to query `q`: one A record 10.5.42.<last> for an A query, NODATA for any other, no additional record. */
static long answer(const unsigned char *q, long qe, int qtype, unsigned char *r, int last) {
    memcpy(r, q, (size_t)qe);
    r[2] = 0x81;
    r[3] = 0x80;
    r[6] = 0; r[7] = qtype == 1;
    r[8] = r[9] = r[10] = r[11] = 0;
    long len = qe;
    if (qtype == 1) {
        unsigned char rec[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 42, (unsigned char)last};
        memcpy(r + len, rec, sizeof rec);
        len += (long)sizeof rec;
    }
    return len;
}
static void serve_udp(int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[600], r[700];
    sa4(sa, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    note(report, "R");
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        long qe = 0;
        int qtype = 0;
        char k = opt_kind(q, n, &qe, &qtype);
        char line[8] = {'u', k, ';', 0};
        note(report, line);
        if (qe == 0) continue;
        sendto4(s, r, answer(q, qe, qtype, r, 1), from);
    }
}
static void serve_tcp(int report) {
    long l = sock_tcp();
    unsigned char sa[16];
    sa4(sa, 53);
    if (l < 0 || bind4(l, sa) != 0 || listen4(l) != 0) _exit(5);
    note(report, "R");
    for (;;) {
        long c = accept4b(l);
        if (c < 0) continue;
        note(report, "c;");
        for (;;) {
            unsigned char q[600], r[700];
            long got = 0;
            while (got < 2) {
                long k = rd(c, q + got, 2 - got);
                if (k <= 0) break;
                got += k;
            }
            if (got < 2) break;
            long want = q[0] << 8 | q[1];
            if (want > (long)sizeof q) break;
            got = 0;
            while (got < want) {
                long k = rd(c, q + got, want - got);
                if (k <= 0) break;
                got += k;
            }
            if (got < want) break;
            long qe = 0;
            int qtype = 0;
            char k = opt_kind(q, got, &qe, &qtype);
            char line[8] = {'t', k, ';', 0};
            note(report, line);
            if (qe == 0) break;
            long len = answer(q, qe, qtype, r + 2, 2);
            r[0] = (unsigned char)(len >> 8);
            r[1] = (unsigned char)len;
            if (wrt(c, r, len + 2) != len + 2) break;
        }
        closefd(c);
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
/* gethostbyname's first address's last byte, or -h_errno. */
static int lookup(const char *name) {
    struct hostent *h = gethostbyname(name);
    return h ? (unsigned char)h->h_addr_list[0][3] : -h_errno;
}
static int conf(const char *opts) {
    char text[160];
    snprintf(text, sizeof text, "nameserver 127.0.0.1\noptions timeout:2 attempts:1 %s\n", opts);
    return write_file("/etc/resolv.conf", text);
}
int main(void) {
    print("hello542: options edns0 adds an OPT record to every query\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pids[2] = {-1, -1};
    if (pr == 0 && (pids[0] = (long)fork()) == 0) { close(p[0]); serve_udp(p[1]); }
    if (pr == 0 && (pids[1] = (long)fork()) == 0) { close(p[0]); serve_tcp(p[1]); }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready[2] = {0, 0};
    for (int i = 0; i < 2 && pr == 0; i++)
        if (read(p[0], &ready[i], 1) != 1) ready[i] = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
    int wn = write_file("/etc/nsswitch.conf", "hosts: dns\n");

    int w = conf("");
    int a = lookup("a542.test");
    take_log();
    snprintf(msg, sizeof msg, "A: without edns0: .%d, asked '%s' (ready %c%c conf %d %d; .1, u-;)", a, seen, ready[0] ? ready[0] : '-',
             ready[1] ? ready[1] : '-', wn, w);
    check(ready[0] == 'R' && ready[1] == 'R' && wn == 0 && w == 0 && a == 1 && strcmp(seen, "u-;") == 0, msg);

    w = conf("edns0");
    int b = lookup("b542.test");
    take_log();
    snprintf(msg, sizeof msg, "B: edns0: .%d, asked '%s' (conf %d; .1, u+;)", b, seen, w);
    check(w == 0 && b == 1 && strcmp(seen, "u+;") == 0, msg);

    w = conf("edns0x");
    int c1 = lookup("c542.test");
    take_log();
    char seen_c1[300];
    snprintf(seen_c1, sizeof seen_c1, "%s", seen);
    w |= conf("edns");
    int c2 = lookup("c542.test");
    take_log();
    snprintf(msg, sizeof msg, "C: 'edns0x' .%d '%s', 'edns' .%d '%s' (conf %d; .1 u+; .1 u-;)", c1, seen_c1, c2, seen, w);
    check(w == 0 && c1 == 1 && strcmp(seen_c1, "u+;") == 0 && c2 == 1 && strcmp(seen, "u-;") == 0, msg);

    w = conf("edns0");
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    int g = getaddrinfo("d542.test", 0, &hints, &res);
    int d_ok = g == 0 && res && res->ai_family == AF_INET && ((unsigned char *)res->ai_addr)[7] == 1;
    if (g == 0) freeaddrinfo(res);
    take_log();
    snprintf(msg, sizeof msg, "D: getaddrinfo(AF_UNSPEC) with edns0: %d, asked '%s' (conf %d; 0 and 10.5.42.1, u+;u+;)", g, seen, w);
    check(w == 0 && d_ok && strcmp(seen, "u+;u+;") == 0, msg);

    w = conf("edns0 use-vc");
    int e = lookup("e542.test");
    take_log();
    snprintf(msg, sizeof msg, "E: edns0 use-vc: .%d, asked '%s' (conf %d; .2, c;t+;)", e, seen, w);
    check(w == 0 && e == 2 && strcmp(seen, "c;t+;") == 0, msg);

    w = conf("edns0");
    unsigned char pa[4] = {10, 5, 42, 9};
    struct hostent *hp = gethostbyaddr(pa, 4, AF_INET);
    take_log();
    snprintf(msg, sizeof msg, "F: gethostbyaddr with edns0: %s, asked '%s' (conf %d; none (NODATA), u+;)", hp ? hp->h_name : "none", seen, w);
    check(w == 0 && !hp && strcmp(seen, "u+;") == 0, msg);

    for (int i = 0; i < 2; i++) if (pids[i] > 0) { kill(pids[i], SIGKILL); waitpid(pids[i], 0, 0); }
    if (pr == 0) close(p[0]);
#ifdef HOST
    long u1 = 0, u2 = 0; /* the host files are bind-mount targets */
#else
    long u1 = unlink("/etc/resolv.conf"), u2 = unlink("/etc/nsswitch.conf");
#endif
    snprintf(msg, sizeof msg, "G: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello542: FAIL\n" : "hello542: PASS\n");
    return failures ? 1 : 0;
}
