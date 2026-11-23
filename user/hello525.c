/* hello525: AAAA records (glibc 2.44, measured with a local server). A stand-in DNS server on 127.0.0.1:53 knows both525.test (A
 * 10.5.25.1 and AAAA 2001:db8::1), v4525.test (A 10.5.25.2 only) and v6525.test (AAAA 2001:db8::2 only); it answers NODATA for a
 * known name without that record and NXDOMAIN for others, and logs each question's type. A: gethostbyname2(AF_INET6) asks an AAAA
 * query and returns the 16-byte address; B: a name with only an A record is NO_DATA for AF_INET6; C: getaddrinfo AF_UNSPEC lists
 * the IPv6 address before the IPv4 one, after an AAAA and an A query; D: AF_UNSPEC for a v6-only and a v4-only name gives that
 * family's address alone; E: AF_INET6 for a v4-only name is EAI_NODATA, and with AI_V4MAPPED the mapped ::ffff:10.5.25.2; F: an
 * unknown name is EAI_NONAME. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf
 * and nsswitch.conf "hosts: files dns" bind-mounted; lo up). */
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
#define CONF_PATH (getenv("R525") ? getenv("R525") : "/etc/resolv.conf")
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
#endif
static int failures;
static char msg[1000];
static void check(int ok, const char *w) {
    print(ok ? "hello525:   ok   " : "hello525:   FAIL ");
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
static void serve(int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512], r[600];
    sa4(sa, 127, 0, 0, 1, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    if (write(report, "R", 1) != 1) _exit(3);
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        char line[32];
        int ll = snprintf(line, sizeof line, "%d;", qtype);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        int both = strcmp(name, "both525.test") == 0, v4 = strcmp(name, "v4525.test") == 0, v6 = strcmp(name, "v6525.test") == 0;
        int known = both || v4 || v6;
        int give_a = qtype == 1 && (both || v4), give_aaaa = qtype == 28 && (both || v6);
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        r[3] = known ? 0x80 : 0x83;
        r[6] = 0; r[7] = (unsigned char)(give_a || give_aaaa);
        r[8] = r[9] = r[10] = r[11] = 0;
        if (give_a) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 25, (unsigned char)(both ? 1 : 2)};
            memcpy(r + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
        if (give_aaaa) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                   (unsigned char)(both ? 1 : 2)};
            memcpy(r + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
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
/* getaddrinfo's result as "6:<last byte>,4:<last byte>,..." into `out`; the return value. */
static int gai(const char *name, int family, int flags, char *out, size_t cap) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = family;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = flags;
    int e = getaddrinfo(name, 0, &hints, &res);
    size_t o = 0;
    out[0] = 0;
    for (struct addrinfo *x = e == 0 ? res : 0; x && o + 12 < cap; x = x->ai_next) {
        const unsigned char *sa = (const unsigned char *)x->ai_addr;
        int f = x->ai_family;
        unsigned last = f == AF_INET6 ? sa[23] : sa[7];
        int mapped = f == AF_INET6 && sa[18] == 0xff && sa[19] == 0xff;
        o += (size_t)snprintf(out + o, cap - o, "%s%u,", f == AF_INET6 ? (mapped ? "m:" : "6:") : "4:", last);
    }
    if (e == 0) freeaddrinfo(res);
    return e;
}
int main(void) {
    print("hello525: AAAA records\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pid = pr == 0 ? (long)fork() : -1;
    if (pid == 0) { close(p[0]); serve(p[1]); }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready = 0;
    if (pid > 0 && read(p[0], &ready, 1) != 1) ready = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
    int wc = write_conf("nameserver 127.0.0.1\noptions timeout:1 attempts:1\n");

    struct hostent *h = gethostbyname2("both525.test", AF_INET6);
    int al = h ? h->h_length : 0, at = h ? h->h_addrtype : 0;
    unsigned b0 = h ? (unsigned char)h->h_addr_list[0][0] : 0, b15 = h ? (unsigned char)h->h_addr_list[0][15] : 0;
    take_log();
    snprintf(msg, sizeof msg, "A: gethostbyname2(both525.test, AF_INET6) type %d length %d %02x..%02x, asked '%s' (conf %d ready %c; 10 16 20..01, an AAAA query)", at,
             al, b0, b15, seen, wc, ready ? ready : '-');
    check(wc == 0 && ready == 'R' && at == AF_INET6 && al == 16 && b0 == 0x20 && b15 == 1 && strstr(seen, "28;") != 0, msg);

    h = gethostbyname2("v4525.test", AF_INET6);
    int bh = h ? -1 : h_errno;
    snprintf(msg, sizeof msg, "B: gethostbyname2(v4525.test, AF_INET6) h_errno %d (4)", bh);
    check(bh == NO_DATA, msg);

    take_log();
    char c[80];
    int ce = gai("both525.test", AF_UNSPEC, 0, c, sizeof c);
    take_log();
    snprintf(msg, sizeof msg, "C: getaddrinfo(both525.test, AF_UNSPEC) %d '%s', asked '%s' (0 '6:1,4:1,', an AAAA and an A query)", ce, c, seen);
    check(ce == 0 && strcmp(c, "6:1,4:1,") == 0 && strstr(seen, "28;") && strstr(seen, "1;"), msg);

    char d6[80], d4[80];
    int de6 = gai("v6525.test", AF_UNSPEC, 0, d6, sizeof d6);
    int de4 = gai("v4525.test", AF_UNSPEC, 0, d4, sizeof d4);
    snprintf(msg, sizeof msg, "D: AF_UNSPEC v6-only %d '%s', v4-only %d '%s' (0 '6:2,' 0 '4:2,')", de6, d6, de4, d4);
    check(de6 == 0 && strcmp(d6, "6:2,") == 0 && de4 == 0 && strcmp(d4, "4:2,") == 0, msg);

    char e1[80], e2[80];
    int ee1 = gai("v4525.test", AF_INET6, 0, e1, sizeof e1);
    int ee2 = gai("v4525.test", AF_INET6, AI_V4MAPPED, e2, sizeof e2);
    snprintf(msg, sizeof msg, "E: AF_INET6 v4-only %d; with AI_V4MAPPED %d '%s' (%d 0 'm:2,')", ee1, ee2, e2, EAI_NODATA);
    check(ee1 == EAI_NODATA && ee2 == 0 && strcmp(e2, "m:2,") == 0, msg);

    char f[80];
    int fe = gai("nosuch525.test", AF_UNSPEC, 0, f, sizeof f);
    snprintf(msg, sizeof msg, "F: unknown name %d (%d)", fe, EAI_NONAME);
    check(fe == EAI_NONAME, msg);

    int st = -1;
    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "G: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello525: FAIL\n" : "hello525: PASS\n");
    return failures ? 1 : 0;
}
