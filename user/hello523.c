/* hello523: large DNS answers (glibc 2.44, measured with a local server). A stand-in DNS server on 127.0.0.1:53 answers
 * "many.test" with 60 A records (a 987-byte reply, over the classic 512 bytes, sent without EDNS as glibc accepts it) and
 * "w.test" with a 12-step CNAME chain w -> w1 -> ... -> w12 and one address. A: gethostbyname(many.test) lists all 60
 * addresses in reply order; B: getaddrinfo(many.test) gives 60 entries; C: gethostbyname(w.test) has h_name w12.test and the 12
 * earlier names as aliases in order; D: gethostbyname_r with a buffer that is too small for the 60 addresses is ERANGE, one that
 * is large enough holds them all. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -m -n`
 * (resolv.conf and nsswitch.conf "hosts: files dns" bind-mounted). */
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
#define CONF_PATH (getenv("R523") ? getenv("R523") : "/etc/resolv.conf")
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
    print(ok ? "hello523:   ok   " : "hello523:   FAIL ");
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
static long put_name(unsigned char *p, const char *name) {
    long o = 0;
    while (*name) {
        const char *dot = strchr(name, '.');
        long l = dot ? dot - name : (long)strlen(name);
        p[o++] = (unsigned char)l;
        memcpy(p + o, name, (size_t)l);
        o += l;
        name += l;
        if (*name == '.') name++;
    }
    p[o++] = 0;
    return o;
}
static long rr(unsigned char *p, const char *owner, int type, const unsigned char *ip, const char *target) {
    long o = put_name(p, owner);
    unsigned char fixed[] = {0, (unsigned char)type, 0, 1, 0, 0, 0, 60};
    memcpy(p + o, fixed, sizeof fixed);
    o += (long)sizeof fixed;
    if (type == 1) {
        p[o++] = 0; p[o++] = 4;
        memcpy(p + o, ip, 4);
        return o + 4;
    }
    long at = o;
    o += 2;
    long l = put_name(p + o, target);
    p[at] = 0; p[at + 1] = (unsigned char)l;
    return o + l;
}
static void serve(int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512];
    static unsigned char r[4096];
    sa4(sa, 127, 0, 0, 1, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    if (write(report, "R", 1) != 1) _exit(3);
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        memcpy(r, q, (size_t)n);
        long len = n;
        int an = 0;
        if (qtype == 1 && strcmp(name, "many.test") == 0) {
            /* Each owner is a pointer to the question's name (offset 12), as servers compress it: 16 bytes a record. */
            for (int i = 0; i < 60; i++) {
                unsigned char rec[] = {0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 23, (unsigned char)(i + 1)};
                memcpy(r + len, rec, sizeof rec);
                len += (long)sizeof rec;
            }
            an = 60;
        } else if (qtype == 1 && strcmp(name, "w.test") == 0) {
            char a[24], b[24];
            for (int i = 0; i < 12; i++) {
                if (i == 0) snprintf(a, sizeof a, "w.test"); else snprintf(a, sizeof a, "w%d.test", i);
                snprintf(b, sizeof b, "w%d.test", i + 1);
                len += rr(r + len, a, 5, 0, b);
            }
            unsigned char ip[4] = {10, 5, 23, 99};
            len += rr(r + len, "w12.test", 1, ip, 0);
            an = 13;
        }
        r[2] = 0x81;
        r[3] = an ? 0x80 : 0x83;
        r[6] = 0; r[7] = (unsigned char)an;
        r[8] = r[9] = r[10] = r[11] = 0;
        char line[32];
        int ll = snprintf(line, sizeof line, "%ld;", len);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
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
int main(void) {
    print("hello523: large DNS answers\n");
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

    struct hostent *h = gethostbyname("many.test");
    int na = 0, inorder = 1;
    while (h && h->h_addr_list[na]) {
        if ((unsigned char)h->h_addr_list[na][3] != na + 1) inorder = 0;
        na++;
    }
    take_log();
    long reply = 0;
    for (const char *q = seen; *q >= '0' && *q <= '9'; q++) reply = reply * 10 + (*q - '0');
    snprintf(msg, sizeof msg, "A: gethostbyname(many.test) %d addresses, in order %d, reply of %ld bytes (conf %d ready %c; 60 1, over 512)", na, inorder, reply, wc,
             ready ? ready : '-');
    check(wc == 0 && ready == 'R' && na == 60 && inorder && reply > 512, msg);

    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int g = getaddrinfo("many.test", 0, &hints, &res);
    int ng = 0;
    unsigned lastg = 0;
    for (struct addrinfo *x = g == 0 ? res : 0; x; x = x->ai_next) { ng++; lastg = ((unsigned char *)x->ai_addr)[7]; }
    if (g == 0) freeaddrinfo(res);
    snprintf(msg, sizeof msg, "B: getaddrinfo(many.test) %d, %d entries, last .%u (0 60 .60)", g, ng, lastg);
    check(g == 0 && ng == 60 && lastg == 60, msg);

    h = gethostbyname("w.test");
    int nal = 0, chain_ok = 1;
    char want[24];
    while (h && h->h_aliases[nal]) {
        if (nal == 0) snprintf(want, sizeof want, "w.test"); else snprintf(want, sizeof want, "w%d.test", nal);
        if (strcmp(h->h_aliases[nal], want) != 0) chain_ok = 0;
        nal++;
    }
    char nm[32];
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    snprintf(msg, sizeof msg, "C: a 12-step CNAME chain: h_name %s, %d aliases in order %d, .%u (w12.test 12 1 .99)", nm, nal, chain_ok,
             h && h->h_addr_list[0] ? (unsigned char)h->h_addr_list[0][3] : 0);
    check(strcmp(nm, "w12.test") == 0 && nal == 12 && chain_ok && h->h_addr_list[0] && (unsigned char)h->h_addr_list[0][3] == 99, msg);

    struct hostent he, *rp = 0;
    static char small[200], large[2000];
    int herr = 0;
    int d1 = gethostbyname_r("many.test", &he, small, sizeof small, &rp, &herr);
    int d1ok = d1 == ERANGE && rp == 0;
    int d2 = gethostbyname_r("many.test", &he, large, sizeof large, &rp, &herr);
    int nd = 0;
    while (d2 == 0 && rp && rp->h_addr_list[nd]) nd++;
    snprintf(msg, sizeof msg, "D: gethostbyname_r 200 bytes %d, 2000 bytes %d with %d addresses (%d 0 60)", d1, d2, nd, ERANGE);
    check(d1ok && d2 == 0 && nd == 60, msg);

    int st = -1;
    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "E: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello523: FAIL\n" : "hello523: PASS\n");
    return failures ? 1 : 0;
}
