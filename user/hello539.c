/* hello539: a DNS reply over TCP may be longer than 4096 bytes (glibc 2.44 res_send grows its buffer up to 65535 bytes,
 * measured). A stand-in server on 127.0.0.1:53 answers every UDP query with TC set and no records, and over TCP answers
 * "big539.test" with 300 A records (4829 bytes) and "huge539.test" with 4000 (64029 bytes), 10.39.<k / 256>.<k % 256> for
 * k = 1... A: gethostbyname(big539.test) answers, its first address 10.39.0.1 and at least 64 addresses; B: huge539.test the
 * same; C: getaddrinfo(big539.test, AF_INET) answers; D: cleanup. Measured with -DHOST through glibc in `unshare -r -m -n`
 * (lo up, a tmpfs on /etc), so both builds create and remove the same files. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
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
static long wrt(long s, const void *b, long n) {
    for (;;) {
        long r = syscall3(SYS_write, s, (long)b, n);
        if (r != -11) return r;
        syscall1(SYS_netpoll, 0);
    }
}
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello539:   ok   " : "hello539:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void sa4(unsigned char sa[16], unsigned d, unsigned port) {
    memset(sa, 0, 16);
    sa[0] = 2;
    sa[2] = (unsigned char)(port >> 8);
    sa[3] = (unsigned char)port;
    sa[4] = 127; sa[7] = (unsigned char)d;
}
static int write_file(const char *path, const char *text) {
    int fd = (int)open(path, 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
/* The question name of a query (from byte 12) as "a.b.c" into `out`; the offset just past the question, or -1. */
static long qname(const unsigned char *q, long n, char *out, size_t cap) {
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
    return i + 5 <= n ? i + 5 : -1;
}
static void serve_udp(int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512];
    sa4(sa, 1, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    if (write(report, "R", 1) != 1) _exit(3);
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        q[2] = 0x83; /* QR, TC, RD */
        q[3] = 0x80;
        q[6] = q[7] = q[8] = q[9] = q[10] = q[11] = 0;
        sendto4(s, q, n, from);
    }
}
static unsigned char reply[2 + 65535];
static void serve_tcp(int report) {
    long l = sock_tcp();
    unsigned char sa[16];
    sa4(sa, 1, 53);
    if (l < 0 || bind4(l, sa) != 0 || listen4(l) != 0) _exit(5);
    if (write(report, "R", 1) != 1) _exit(6);
    for (;;) {
        long c = accept4b(l);
        if (c < 0) continue;
        unsigned char q[600];
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
        char name[256];
        long qend = got >= 12 ? qname(q, got, name, sizeof name) : -1;
        int count = qend < 0 ? 0 : strcmp(name, "big539.test") == 0 ? 300 : strcmp(name, "huge539.test") == 0 ? 4000 : 0;
        if (qend < 0) {
            closefd(c);
            continue;
        }
        unsigned char *r = reply + 2;
        memcpy(r, q, (size_t)qend);
        r[2] = 0x81;
        r[3] = count ? 0x80 : 0x83;
        r[6] = (unsigned char)(count >> 8); r[7] = (unsigned char)count;
        r[8] = r[9] = r[10] = r[11] = 0;
        long len = qend;
        for (int k = 1; k <= count; k++) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 39, (unsigned char)(k >> 8), (unsigned char)k};
            memcpy(r + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
        reply[0] = (unsigned char)(len >> 8);
        reply[1] = (unsigned char)len;
        long off = 0;
        while (off < len + 2) {
            long w = wrt(c, reply + off, len + 2 - off);
            if (w <= 0) break;
            off += w;
        }
        closefd(c);
    }
}
/* "hit/<first address's last two bytes>/<count>" or "NULL/<h_errno>". */
static void describe(struct hostent *h, char *out, size_t cap) {
    if (!h) { snprintf(out, cap, "NULL/%d", h_errno); return; }
    int n = 0;
    while (h->h_addr_list[n]) n++;
    snprintf(out, cap, "hit/%u.%u/%d", (unsigned char)h->h_addr_list[0][2], (unsigned char)h->h_addr_list[0][3], n);
}
static int good(struct hostent *h) {
    int n = 0;
    while (h && h->h_addr_list[n]) n++;
    return h && (unsigned char)h->h_addr_list[0][0] == 10 && (unsigned char)h->h_addr_list[0][1] == 39 &&
           (unsigned char)h->h_addr_list[0][2] == 0 && (unsigned char)h->h_addr_list[0][3] == 1 && n >= 64;
}
int main(void) {
    print("hello539: DNS replies over TCP longer than 4096 bytes\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pids[2] = {-1, -1};
    if (pr == 0 && (pids[0] = (long)fork()) == 0) { close(p[0]); serve_udp(p[1]); }
    if (pr == 0 && (pids[1] = (long)fork()) == 0) { close(p[0]); serve_tcp(p[1]); }
    char ready[2] = {0, 0};
    if (pr == 0) {
        close(p[1]);
        for (int i = 0; i < 2; i++)
            if (read(p[0], &ready[i], 1) != 1) ready[i] = 0;
        close(p[0]);
    }
    int wr = write_file("/etc/resolv.conf", "nameserver 127.0.0.1\noptions timeout:3 attempts:1\n");
    int wn = write_file("/etc/nsswitch.conf", "hosts: dns\n");
    char a[64], b[64];
    struct hostent *h = gethostbyname("big539.test");
    int a_ok = good(h);
    describe(h, a, sizeof a);
    snprintf(msg, sizeof msg, "A: 300 records, 4829 bytes over TCP (ready %c%c, conf %d %d): %s (hit/0.1/>=64)", ready[0] ? ready[0] : '-',
             ready[1] ? ready[1] : '-', wr, wn, a);
    check(ready[0] == 'R' && ready[1] == 'R' && wr == 0 && wn == 0 && a_ok, msg);

    h = gethostbyname("huge539.test");
    int b_ok = good(h);
    describe(h, b, sizeof b);
    snprintf(msg, sizeof msg, "B: 4000 records, 64029 bytes over TCP: %s (hit/0.1/>=64)", b);
    check(b_ok, msg);

    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int g = getaddrinfo("big539.test", 0, &hints, &res);
    int c_ok = g == 0 && res && ((unsigned char *)res->ai_addr)[4] == 10 && ((unsigned char *)res->ai_addr)[5] == 39;
    if (g == 0) freeaddrinfo(res);
    snprintf(msg, sizeof msg, "C: getaddrinfo(big539.test, AF_INET): %d (0)", g);
    check(c_ok, msg);

    for (int i = 0; i < 2; i++) if (pids[i] > 0) { kill(pids[i], SIGKILL); waitpid(pids[i], 0, 0); }
    long u1 = unlink("/etc/resolv.conf"), u2 = unlink("/etc/nsswitch.conf");
    snprintf(msg, sizeof msg, "D: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello539: FAIL\n" : "hello539: PASS\n");
    return failures ? 1 : 0;
}
