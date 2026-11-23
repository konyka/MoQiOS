/* hello524: a truncated UDP reply (TC set) makes the resolver ask again over TCP (glibc 2.44 res_send, measured). A stand-in server on
 * 127.0.0.1:53 answers every UDP query with TC set and no records (or, for "tcans-*", TC set with a record that must not be used),
 * and over TCP (a 2-byte length, then the message) answers "ok-*" with three addresses, "nx-*" with NXDOMAIN and "close-*" by
 * closing without a reply; 127.0.0.2 answers UDP the same way but has no TCP listener. A: gethostbyname(ok524.test) gets the three
 * TCP addresses, after one UDP and one TCP query; B: TC with a record in the UDP reply: the record is ignored and the TCP answer
 * used; C: NXDOMAIN over TCP is HOST_NOT_FOUND; D: a TCP connection closed before the reply is TRY_AGAIN; E: a server with no TCP
 * listener is TRY_AGAIN at once (the connection is refused). Needs root (port 53 and /etc). Measured with -DHOST through glibc in
 * `unshare -m -n` (resolv.conf and nsswitch.conf "hosts: files dns" bind-mounted, lo with 127.0.0.2). */
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
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define CONF_PATH (getenv("R524") ? getenv("R524") : "/etc/resolv.conf")
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
static long sock_tcp(void) { int s = socket(AF_INET, SOCK_STREAM, 0); return s < 0 ? -errno : s; }
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
#include "../lib/moqi_libc/include/time.h"
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
static long sock_tcp(void) { return syscall3(SYS_socket, 2, 1, 0); }
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
static char msg[1000];
static void check(int ok, const char *w) {
    print(ok ? "hello524:   ok   " : "hello524:   FAIL ");
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
static int rep_fd = -1;
static void note(int report, const char *s) {
    if (write(report, s, strlen(s)) != (long)strlen(s)) _exit(4);
}
/* The UDP side on 127.0.0.<last>: TC set, and a record (10.5.24.9) only for "tcans" names. */
static void serve_udp(int last, int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512], r[600];
    sa4(sa, 127, 0, 0, (unsigned)last, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    note(report, "R");
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        note(report, last == 1 ? "u;" : "u2;");
        memcpy(r, q, (size_t)n);
        long len = n;
        int rec = strncmp(name, "tcans", 5) == 0 && qtype == 1;
        r[2] = 0x83; /* QR, TC, RD */
        r[3] = 0x80;
        r[6] = 0; r[7] = (unsigned char)rec;
        r[8] = r[9] = r[10] = r[11] = 0;
        if (rec) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 24, 9};
            memcpy(r + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
        sendto4(s, r, len, from);
    }
}
/* The TCP side on 127.0.0.1:53. */
static void serve_tcp(int report) {
    long l = sock_tcp();
    unsigned char sa[16];
    sa4(sa, 127, 0, 0, 1, 53);
    if (l < 0 || bind4(l, sa) != 0 || listen4(l) != 0) _exit(5);
    note(report, "R");
    for (;;) {
        long c = accept4b(l);
        if (c < 0) continue;
        unsigned char q[600], r[700];
        long got = 0;
        while (got < 2) {
            long k = rd(c, q + got, 2 - got);
            if (k <= 0) break;
            got += k;
        }
        long want = got == 2 ? (q[0] << 8 | q[1]) : 0;
        got = 0;
        while (got < want && want <= (long)sizeof q) {
            long k = rd(c, q + got, want - got);
            if (k <= 0) break;
            got += k;
        }
        note(report, "t;");
        char name[256];
        int qtype = 0;
        if (got < 12 || qname(q, got, name, sizeof name, &qtype) != 0 || strncmp(name, "close", 5) == 0) {
            closefd(c);
            continue;
        }
        memcpy(r + 2, q, (size_t)got);
        long len = got;
        int nx = strncmp(name, "nx", 2) == 0;
        r[2 + 2] = 0x81;
        r[2 + 3] = nx ? 0x83 : 0x80;
        r[2 + 6] = 0; r[2 + 7] = nx ? 0 : 3;
        r[2 + 8] = r[2 + 9] = r[2 + 10] = r[2 + 11] = 0;
        for (int k = 0; !nx && k < 3; k++) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 24, (unsigned char)(k + 1)};
            memcpy(r + 2 + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
        r[0] = (unsigned char)(len >> 8);
        r[1] = (unsigned char)len;
        wrt(c, r, len + 2);
        closefd(c);
    }
}
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
static void addrs(struct hostent *h, char *out, size_t cap) {
    size_t o = 0;
    out[0] = 0;
    for (int i = 0; h && h->h_addr_list[i] && o + 6 < cap; i++) o += (size_t)snprintf(out + o, cap - o, ".%u", (unsigned char)h->h_addr_list[i][3]);
    if (!h) snprintf(out, cap, "NULL/%d", h_errno);
}
static long now_ms(void) {
    struct timespec t;
    clock_gettime(1, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
int main(void) {
    print("hello524: truncated replies and DNS over TCP\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pids[3] = {-1, -1, -1};
    if (pr == 0 && (pids[0] = (long)fork()) == 0) { close(p[0]); serve_udp(1, p[1]); }
    if (pr == 0 && (pids[1] = (long)fork()) == 0) { close(p[0]); serve_tcp(p[1]); }
    if (pr == 0 && (pids[2] = (long)fork()) == 0) { close(p[0]); serve_udp(2, p[1]); }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready[3] = {0, 0, 0};
    for (int i = 0; i < 3 && pr == 0; i++)
        if (read(p[0], &ready[i], 1) != 1) ready[i] = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
    int wc = write_conf("nameserver 127.0.0.1\noptions timeout:2 attempts:1\n");

    char a[64], b[64], c[64], d[64], e[64];
    addrs(gethostbyname("ok524.test"), a, sizeof a);
    take_log();
    char seen_a[300];
    snprintf(seen_a, sizeof seen_a, "%s", seen);
    snprintf(msg, sizeof msg, "A: TC then TCP: %s, asked '%s' (conf %d ready %c%c%c; .1.2.3, u;t;)", a, seen_a, wc, ready[0] ? ready[0] : '-',
             ready[1] ? ready[1] : '-', ready[2] ? ready[2] : '-');
    check(wc == 0 && ready[0] == 'R' && ready[1] == 'R' && ready[2] == 'R' && strcmp(a, ".1.2.3") == 0 && strncmp(seen_a, "u;t;", 4) == 0, msg);

    addrs(gethostbyname("tcans524.test"), b, sizeof b);
    snprintf(msg, sizeof msg, "B: TC with a record in the UDP reply: %s (.1.2.3, not .9)", b);
    check(strcmp(b, ".1.2.3") == 0, msg);

    addrs(gethostbyname("nx524.test"), c, sizeof c);
    snprintf(msg, sizeof msg, "C: NXDOMAIN over TCP: %s (NULL/1)", c);
    check(strcmp(c, "NULL/1") == 0, msg);

    addrs(gethostbyname("close524.test"), d, sizeof d);
    snprintf(msg, sizeof msg, "D: TCP closed before the reply: %s (NULL/2)", d);
    check(strcmp(d, "NULL/2") == 0, msg);

    take_log();
    int we = write_conf("nameserver 127.0.0.2\noptions timeout:2 attempts:1\n");
    long t0 = now_ms();
    addrs(gethostbyname("ok524.test"), e, sizeof e);
    long te = now_ms() - t0;
    take_log();
    snprintf(msg, sizeof msg, "E: no TCP listener: %s after %ld ms, asked '%s' (conf %d; NULL/2, under 1500 ms)", e, te, seen, we);
    check(we == 0 && strcmp(e, "NULL/2") == 0 && te < 1500 && strncmp(seen, "u2;", 3) == 0, msg);

    for (int i = 0; i < 3; i++) if (pids[i] > 0) { kill(pids[i], SIGKILL); waitpid(pids[i], 0, 0); }
    if (pr == 0) close(p[0]);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello524: FAIL\n" : "hello524: PASS\n");
    return failures ? 1 : 0;
}
