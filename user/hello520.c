/* hello520: CNAME chains and answers with several addresses (glibc 2.44 getanswer_r, measured with a local server). A stand-in DNS
 * server on 127.0.0.1:53 answers from a fixed table. A: a.test CNAME b.test, A b.test: h_name b.test, h_aliases {a.test}; B: a
 * two-step chain e -> f -> g: h_name g.test, aliases e.test f.test; C: i.test with two A records: both in h_addr_list, in reply
 * order; D: getaddrinfo(AI_CANONNAME) gives the end of the chain as ai_canonname and one entry per address; E: a CNAME with no
 * address after it is NO_RECOVERY / EAI_NONAME, as is an answer whose A record belongs to another name; F: names compare without
 * regard to case and the canonical name keeps the CNAME target's spelling (k.test CNAME L.Test, A l.test); G: an A record for the
 * old name after the CNAME no longer counts (o.test CNAME p.test, A p.test, A o.test: only p's); I: two threads resolving
 * different CNAME names with gethostbyname_r at the same time each get their own answer. Needs root (port 53 and /etc).
 * Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf and nsswitch.conf "hosts: files dns" bind-mounted). */
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
#include <pthread.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define CONF_PATH (getenv("R520") ? getenv("R520") : "/etc/resolv.conf")
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
#include "../lib/moqi_libc/include/pthread.h"
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
    print(ok ? "hello520:   ok   " : "hello520:   FAIL ");
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
/* One answer record: owner, type (1 A, 5 CNAME), then the address or the target. */
struct rec { const char *owner; int type; unsigned char ip[4]; const char *target; };
struct entry { const char *name; struct rec r[3]; int n; };
static const struct entry table[] = {
    {"a.test", {{"a.test", 5, {0}, "b.test"}, {"b.test", 1, {10, 5, 20, 1}, 0}}, 2},
    {"e.test", {{"e.test", 5, {0}, "f.test"}, {"f.test", 5, {0}, "g.test"}, {"g.test", 1, {10, 5, 20, 2}, 0}}, 3},
    {"i.test", {{"i.test", 1, {10, 5, 20, 4}, 0}, {"i.test", 1, {10, 5, 20, 5}, 0}}, 2},
    {"c.test", {{"c.test", 5, {0}, "d.test"}}, 1},
    {"h.test", {{"other.test", 1, {10, 5, 20, 3}, 0}}, 1},
    {"k.test", {{"k.test", 5, {0}, "L.Test"}, {"l.test", 1, {10, 5, 20, 8}, 0}}, 2},
    {"o.test", {{"o.test", 5, {0}, "p.test"}, {"p.test", 1, {10, 5, 20, 11}, 0}, {"o.test", 1, {10, 5, 20, 12}, 0}}, 3},
};
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
static void serve(int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512], r[512];
    sa4(sa, 127, 0, 0, 1, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    if (write(report, "R", 1) != 1) _exit(3);
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        const struct entry *e = 0;
        for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
            if (strcmp(table[i].name, name) == 0 && qtype == 1) e = &table[i];
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        r[3] = e ? 0x80 : 0x83;
        r[6] = 0; r[7] = (unsigned char)(e ? e->n : 0);
        r[8] = r[9] = r[10] = r[11] = 0;
        for (int i = 0; e && i < e->n; i++) {
            const struct rec *x = &e->r[i];
            len += put_name(r + len, x->owner);
            unsigned char fixed[] = {0, (unsigned char)x->type, 0, 1, 0, 0, 0, 60};
            memcpy(r + len, fixed, sizeof fixed);
            len += (long)sizeof fixed;
            if (x->type == 1) {
                r[len++] = 0; r[len++] = 4;
                memcpy(r + len, x->ip, 4);
                len += 4;
            } else {
                long at = len;
                len += 2;
                long l = put_name(r + len, x->target);
                r[at] = 0; r[at + 1] = (unsigned char)l;
                len += l;
            }
        }
        sendto4(s, r, len, from);
    }
}
static unsigned octet(struct hostent *h, int i) { return h && h->h_addr_list[i] ? (unsigned char)h->h_addr_list[i][3] : 0; }
static int naddr(struct hostent *h) { int n = 0; while (h && h->h_addr_list[n]) n++; return n; }
static const char *alias(struct hostent *h, int i) {
    for (int k = 0; h && h->h_aliases[k]; k++) if (k == i) return h->h_aliases[k];
    return "-";
}
/* Two threads resolving different CNAME names with gethostbyname_r at once must each get their own chain. */
struct worker { const char *name, *canon; unsigned last; int bad; };
static void *resolve_loop(void *arg) {
    struct worker *w = (struct worker *)arg;
    for (int i = 0; i < 20; i++) {
        struct hostent he, *res = 0;
        char buf[512];
        int herr = 0;
        int rc = gethostbyname_r(w->name, &he, buf, sizeof buf, &res, &herr);
        if (rc != 0 || res != &he || strcmp(he.h_name, w->canon) != 0 || (unsigned char)he.h_addr_list[0][3] != w->last) w->bad++;
    }
    return (void *)0;
}
int main(void) {
    print("hello520: CNAME chains and several addresses\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pid = pr == 0 ? (long)fork() : -1;
    if (pid == 0) { close(p[0]); serve(p[1]); }
    if (pr == 0) close(p[1]);
    char ready = 0;
    if (pid > 0 && read(p[0], &ready, 1) != 1) ready = 0;
    int wc = write_conf("nameserver 127.0.0.1\noptions timeout:1 attempts:1\n");

    struct hostent *h = gethostbyname("a.test");
    char nm[64];
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    snprintf(msg, sizeof msg, "A: a.test CNAME b.test: h_name %s, aliases %s %s, %d address .%u (conf %d ready %c; b.test a.test - 1 .1)", nm, alias(h, 0), alias(h, 1),
             naddr(h), octet(h, 0), wc, ready ? ready : '-');
    check(wc == 0 && ready == 'R' && strcmp(nm, "b.test") == 0 && strcmp(alias(h, 0), "a.test") == 0 && !strcmp(alias(h, 1), "-") && naddr(h) == 1 && octet(h, 0) == 1, msg);

    h = gethostbyname("e.test");
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    snprintf(msg, sizeof msg, "B: e -> f -> g: h_name %s, aliases %s %s, .%u (g.test e.test f.test .2)", nm, alias(h, 0), alias(h, 1), octet(h, 0));
    check(strcmp(nm, "g.test") == 0 && strcmp(alias(h, 0), "e.test") == 0 && strcmp(alias(h, 1), "f.test") == 0 && octet(h, 0) == 2, msg);

    h = gethostbyname("i.test");
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    snprintf(msg, sizeof msg, "C: two A records: h_name %s, %d addresses .%u .%u, alias %s (i.test 2 .4 .5 -)", nm, naddr(h), octet(h, 0), octet(h, 1), alias(h, 0));
    check(strcmp(nm, "i.test") == 0 && naddr(h) == 2 && octet(h, 0) == 4 && octet(h, 1) == 5 && !strcmp(alias(h, 0), "-"), msg);

    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_CANONNAME;
    int g1 = getaddrinfo("e.test", 0, &hints, &res);
    char canon[64];
    snprintf(canon, sizeof canon, "%s", g1 == 0 && res->ai_canonname ? res->ai_canonname : "-");
    if (g1 == 0) freeaddrinfo(res);
    int g2 = getaddrinfo("i.test", 0, &hints, &res);
    int cnt = 0;
    unsigned last = 0;
    for (struct addrinfo *x = g2 == 0 ? res : 0; x; x = x->ai_next) { cnt++; last = ((unsigned char *)x->ai_addr)[7]; }
    if (g2 == 0) freeaddrinfo(res);
    snprintf(msg, sizeof msg, "D: getaddrinfo(e.test) %d canonname %s; getaddrinfo(i.test) %d, %d entries, last .%u (0 g.test 0 2 .5)", g1, canon, g2, cnt, last);
    check(g1 == 0 && strcmp(canon, "g.test") == 0 && g2 == 0 && cnt == 2 && last == 5, msg);

    h = gethostbyname("c.test");
    int e1 = h ? -1 : h_errno;
    h = gethostbyname("h.test");
    int e2 = h ? -1 : h_errno;
    int e3 = getaddrinfo("c.test", 0, &hints, &res);
    if (e3 == 0) freeaddrinfo(res);
    snprintf(msg, sizeof msg, "E: a CNAME without an address h_errno %d, an A for another name %d, getaddrinfo %d (3 3 %d)", e1, e2, e3, EAI_NONAME);
    check(e1 == NO_RECOVERY && e2 == NO_RECOVERY && e3 == EAI_NONAME, msg);

    h = gethostbyname("k.test");
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    snprintf(msg, sizeof msg, "F: k.test CNAME L.Test, A l.test: h_name %s .%u (L.Test .8)", nm, octet(h, 0));
    check(strcmp(nm, "L.Test") == 0 && octet(h, 0) == 8, msg);

    h = gethostbyname("o.test");
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    snprintf(msg, sizeof msg, "G: o.test CNAME p.test, A p.test, A o.test: h_name %s, %d address .%u (p.test 1 .11)", nm, naddr(h), octet(h, 0));
    check(strcmp(nm, "p.test") == 0 && naddr(h) == 1 && octet(h, 0) == 11, msg);

    struct worker w1 = {"a.test", "b.test", 1, 0}, w2 = {"e.test", "g.test", 2, 0};
    pthread_t t1, t2;
    int c1 = pthread_create(&t1, 0, resolve_loop, &w1), c2 = pthread_create(&t2, 0, resolve_loop, &w2);
    if (c1 == 0) pthread_join(t1, 0);
    if (c2 == 0) pthread_join(t2, 0);
    snprintf(msg, sizeof msg, "I: two threads with gethostbyname_r, create %d %d, wrong answers %d %d (0 0 0 0)", c1, c2, w1.bad, w2.bad);
    check(c1 == 0 && c2 == 0 && w1.bad == 0 && w2.bad == 0, msg);

    int st = -1;
    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "H: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello520: FAIL\n" : "hello520: PASS\n");
    return failures ? 1 : 0;
}
