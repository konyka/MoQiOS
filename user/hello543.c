/* hello543: under "options use-vc" an AF_UNSPEC getaddrinfo asks A and AAAA on one TCP connection, both queries sent before any
 * reply, and takes the replies in either order (glibc 2.44, measured; "single-request" changes nothing then). A stand-in server on
 * 127.0.0.1:53 accepts connections, waits 300 ms after the first query and checks whether the second is already there, then
 * answers A queries with 10.5.43.2 and AAAA queries with NODATA. It logs "c;" per connection, "B;" when the second query came
 * before any reply or "O;" when only one had, then the type of each query it answers. A name starting "swap" is answered AAAA
 * first; for "close" the connection is closed after the first reply. Needs root (port 53 and /etc). Measured with -DHOST through
 * glibc in `unshare -r -m -n` (lo up, resolv.conf and nsswitch.conf bind-mounted). Each case prints what it saw; the expected
 * value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
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
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long bind4(long s, const unsigned char *sa) { return bind((int)s, (const struct sockaddr *)sa, 16) < 0 ? -errno : 0; }
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
static long rd_nb(long s, void *b, long n) { long r = recv((int)s, b, (size_t)n, MSG_DONTWAIT); return r < 0 ? -errno : r; }
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
#define NR_RECVFROM 122
static long bind4(long s, const unsigned char *sa) { return syscall3(SYS_bind, s, (long)sa, 16); }
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
static long rd_nb(long s, void *b, long n) {
    syscall1(SYS_netpoll, 0);
    return syscall6(NR_RECVFROM, s, (long)b, n, 0x40 /* MSG_DONTWAIT */, 0, 0);
}
#endif
static int failures;
static char msg[800];
static void check(int ok, const char *w) {
    print(ok ? "hello543:   ok   " : "hello543:   FAIL ");
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
/* Answer the framed query at f (2-byte length, then the message): A 10.5.43.2 for an A query, NODATA for any other. Its type,
 * or -1. The query name's first label goes into `name`. */
static int answer(long c, const unsigned char *f, char *name, size_t cap) {
    long n = f[0] << 8 | f[1];
    const unsigned char *q = f + 2;
    long i = 12;
    if (n > 12 && q[12] < cap) {
        memcpy(name, q + 13, q[12]);
        name[q[12]] = 0;
    }
    while (i < n && q[i]) i += q[i] + 1;
    if (i + 5 > n) return -1;
    int qtype = q[i + 1] << 8 | q[i + 2];
    long qe = i + 5;
    unsigned char r[700];
    memcpy(r + 2, q, (size_t)qe);
    r[4] = 0x81; r[5] = 0x80;
    r[8] = 0; r[9] = qtype == 1;
    r[10] = r[11] = r[12] = r[13] = 0;
    long len = qe;
    if (qtype == 1) {
        unsigned char rec[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 43, 2};
        memcpy(r + 2 + len, rec, sizeof rec);
        len += (long)sizeof rec;
    }
    r[0] = (unsigned char)(len >> 8);
    r[1] = (unsigned char)len;
    if (wrt(c, r, len + 2) != len + 2) return -1;
    return qtype;
}
/* The bytes of the whole frames at the start of b[0..got): how many frames, and the offset of each. */
static int frames(const unsigned char *b, long got, long off[4]) {
    int k = 0;
    long at = 0;
    while (k < 4 && got - at >= 2 && got - at >= 2 + (b[at] << 8 | b[at + 1])) {
        off[k++] = at;
        at += 2 + (b[at] << 8 | b[at + 1]);
    }
    return k;
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
        unsigned char b[1400];
        long got = 0, off[4];
        int nf = 0, first = 1, closed = 0;
        while (!closed) {
            while ((nf = frames(b, got, off)) == 0) {
                long k = rd(c, b + got, (long)sizeof b - got);
                if (k <= 0) { closed = 1; break; }
                got += k;
            }
            if (closed) break;
            if (first) {
                /* Is a second query already here before any reply goes out? */
                usleep(300000);
                long k = rd_nb(c, b + got, (long)sizeof b - got);
                if (k > 0) got += k;
                nf = frames(b, got, off);
                note(report, nf > 1 || got > off[0] + 2 + (b[0] << 8 | b[1]) ? "B;" : "O;");
            }
            char name[64] = "";
            int order[4] = {0, 1, 2, 3};
            if (nf >= 2) {
                answer(-1, b + off[0], name, sizeof name); /* the name only: no reply sent to fd -1 */
                if (strncmp(name, "swap", 4) == 0) { order[0] = 1; order[1] = 0; }
            }
            long used = 0;
            for (int j = 0; j < nf; j++) {
                const unsigned char *f = b + off[order[j]];
                int t = answer(c, f, name, sizeof name);
                char line[16];
                snprintf(line, sizeof line, "%d;", t);
                note(report, line);
                long end = off[order[j]] + 2 + (f[0] << 8 | f[1]);
                if (end > used) used = end;
                if (strncmp(name, "close", 5) == 0) { closed = 1; break; }
            }
            if (first && !closed && used < got) {
                memmove(b, b + used, (size_t)(got - used));
                got -= used;
            } else {
                got = 0;
            }
            first = 0;
        }
        closefd(c);
    }
}
static int rep_fd = -1;
static char seen[300];
static void take_log(void) {
    size_t n = 0;
    for (int idle = 0; idle < 80 && n + 1 < sizeof seen;) {
        long k = (long)read(rep_fd, seen + n, 1);
        if (k <= 0) { idle++; usleep(5000); continue; }
        idle = 0;
        n++;
    }
    seen[n] = 0;
}
/* getaddrinfo(name, family) as "<rc>" or "0:<fam>.<last byte>,...". */
static void gai(const char *name, int family, char *out, size_t cap) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = family;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(name, 0, &hints, &res);
    if (rc) { snprintf(out, cap, "%d", rc); return; }
    size_t n = (size_t)snprintf(out, cap, "0");
    for (struct addrinfo *p = res; p && n + 12 < cap; p = p->ai_next) {
        const unsigned char *a = (const unsigned char *)p->ai_addr;
        n += (size_t)snprintf(out + n, cap - n, ":%d.%u", p->ai_family, p->ai_family == AF_INET6 ? a[23] : a[7]);
    }
    freeaddrinfo(res);
}
static int conf(const char *opts) {
    char text[160];
    snprintf(text, sizeof text, "nameserver 127.0.0.1\noptions timeout:2 attempts:1 %s\n", opts);
    return write_file("/etc/resolv.conf", text);
}
int main(void) {
    print("hello543: use-vc asks an AF_UNSPEC pair on one TCP connection\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pid = -1;
    if (pr == 0 && (pid = (long)fork()) == 0) { close(p[0]); serve_tcp(p[1]); }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready = 0;
    if (pr == 0 && read(p[0], &ready, 1) != 1) ready = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
    int wn = write_file("/etc/nsswitch.conf", "hosts: dns\n");
    char got[120], want[40];

    int w = conf("use-vc");
    gai("a543.test", AF_UNSPEC, got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "A: use-vc, AF_UNSPEC: %s, server saw '%s' (ready %c conf %d %d; 0:2.2, c;B;1;28;)", got, seen, ready ? ready : '-', wn, w);
    check(ready == 'R' && wn == 0 && w == 0 && strcmp(got, "0:2.2") == 0 && strcmp(seen, "c;B;1;28;") == 0, msg);

    w = conf("use-vc single-request");
    gai("b543.test", AF_UNSPEC, got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "B: use-vc single-request: %s, server saw '%s' (conf %d; 0:2.2, c;B;1;28;)", got, seen, w);
    check(w == 0 && strcmp(got, "0:2.2") == 0 && strcmp(seen, "c;B;1;28;") == 0, msg);

    w = conf("use-vc");
    gai("swap543.test", AF_UNSPEC, got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "C: replies AAAA first: %s, server saw '%s' (conf %d; 0:2.2, c;B;28;1;)", got, seen, w);
    check(w == 0 && strcmp(got, "0:2.2") == 0 && strcmp(seen, "c;B;28;1;") == 0, msg);

    gai("close543.test", AF_UNSPEC, got, sizeof got);
    take_log();
    snprintf(want, sizeof want, "%d", EAI_AGAIN);
    snprintf(msg, sizeof msg, "D: closed after the A reply: %s, server saw '%s' (%s, c;B;1;)", got, seen, want);
    check(strcmp(got, want) == 0 && strcmp(seen, "c;B;1;") == 0, msg);

    gai("e543.test", AF_INET, got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "E: use-vc, AF_INET: %s, server saw '%s' (0:2.2, c;O;1;)", got, seen);
    check(strcmp(got, "0:2.2") == 0 && strcmp(seen, "c;O;1;") == 0, msg);

    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, 0, 0); }
    if (pr == 0) close(p[0]);
#ifdef HOST
    long u1 = 0, u2 = 0; /* the host files are bind-mount targets */
#else
    long u1 = unlink("/etc/resolv.conf"), u2 = unlink("/etc/nsswitch.conf");
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello543: FAIL\n" : "hello543: PASS\n");
    return failures ? 1 : 0;
}
