/* hello531: "options single-request" and "single-request-reopen" in /etc/resolv.conf (glibc 2.44, measured with a local server): an
 * AF_UNSPEC getaddrinfo asks A, waits for its reply, and only then asks AAAA (-reopen from a new port). The stand-in DNS server on
 * 127.0.0.1:53 logs each question and each reply it sends. A: single-request: the log is A, reply, AAAA, reply, both addresses;
 * B: single-request-reopen: the same order; C: "single-requestx" counts too (glibc matches the first 14 characters); D: without the
 * option both questions arrive before the first reply; E: single-request with a server that never answers A: EAI_AGAIN after one
 * timeout and no AAAA question. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf and
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
#define CONF_PATH (getenv("R531") ? getenv("R531") : "/etc/resolv.conf")
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
static long recvfrom_nb(long s, unsigned char *b, long n, unsigned char *sa) {
    socklen_t l = 16;
    long r = recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, (struct sockaddr *)sa, &l);
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
#include "../lib/moqi_libc/include/stdlib.h"
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
static long recvfrom_nb(long s, unsigned char *b, long n, unsigned char *sa) {
    unsigned l = 16;
    syscall1(SYS_netpoll, 0);
    return syscall6(NR_RECVFROM, s, (long)b, n, 0x40 /* MSG_DONTWAIT */, (long)sa, (long)&l);
}
#endif
static int failures;
static char msg[1000];
static void check(int ok, const char *w) {
    print(ok ? "hello531:   ok   " : "hello531:   FAIL ");
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
static void put_name(unsigned char *r, long *len, const char *name) {
    while (*name) {
        const char *dot = strchr(name, '.');
        long l = dot ? dot - name : (long)strlen(name);
        r[(*len)++] = (unsigned char)l;
        memcpy(r + *len, name, (size_t)l);
        *len += l;
        name += l;
        if (*name == '.') name++;
    }
    r[(*len)++] = 0;
}
/* The reply to `q` (n bytes, question `name`/`qtype`) into r. */
static long reply(unsigned char *r, const unsigned char *q, long n, const char *name, int qtype) {
    int a = 0, aaaa = 0, known = 1;
    if (strcmp(name, "a531.test") == 0 || strcmp(name, "both530.test") == 0 || strcmp(name, "x.d2.test") == 0 || strcmp(name, "hold530.test") == 0) a = aaaa = 1;
    else if (strcmp(name, "x.d1.test") == 0) a = 1;
    else known = 0;
    int has = (qtype == 1 && a) || (qtype == 28 && aaaa);
    memcpy(r, q, (size_t)n);
    long len = n;
    r[2] = 0x81;
    r[3] = (unsigned char)(has ? 0x80 : (known && strcmp(name, "x.d1.test") != 0 ? 0x80 : 0x83));
    r[6] = 0; r[7] = (unsigned char)has;
    r[8] = r[9] = r[10] = r[11] = 0;
    if (has) {
        put_name(r, &len, name);
        unsigned char fixed[] = {0, (unsigned char)qtype, 0, 1, 0, 0, 0, 60, 0, (unsigned char)(qtype == 1 ? 4 : 16)};
        memcpy(r + len, fixed, sizeof fixed);
        len += (long)sizeof fixed;
        if (qtype == 1) {
            unsigned char ip[4] = {10, 5, 30, (unsigned char)(name[0] == 'x' ? (name[2] == 'd' && name[3] == '1' ? 11 : 12) : 1)};
            memcpy(r + len, ip, 4);
            len += 4;
        } else {
            unsigned char ip[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05, 0x30};
            memcpy(r + len, ip, 16);
            len += 16;
        }
    }
    return len;
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
        char line[300];
        int ll = snprintf(line, sizeof line, "%d;", qtype);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        if (strcmp(name, "silent531.test") == 0 && qtype == 1) continue;
        /* A pause before each reply: queries asked one after the other take two of them, a parallel pair one less wait for the
         * second question (it is already queued when the first reply goes out). */
        usleep(300000);
        /* A second question already waiting is answered at once: only a pair sent together has one. It is looked for before the
         * first reply goes out, so a question the client sends on receiving that reply is never taken for one (on SMP the client
         * used to send AAAA before this check ran when it came after the reply). */
        unsigned char q2[512], from2[16];
        long n2 = recvfrom_nb(s, q2, sizeof q2, from2);
        long len = reply(r, q, n, name, qtype);
        if (sendto4(s, r, len, from) > 0 && write(report, "r;", 2) != 2) _exit(4);
        if (n2 >= 12 && qname(q2, n2, name, sizeof name, &qtype) == 0) {
            ll = snprintf(line, sizeof line, "%d+;", qtype);
            if (write(report, line, (size_t)ll) != ll) _exit(4);
            len = reply(r, q2, n2, name, qtype);
            if (sendto4(s, r, len, from2) > 0 && write(report, "r;", 2) != 2) _exit(4);
        }
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
/* getaddrinfo(AF_UNSPEC, SOCK_STREAM) as "fam:last-byte,..." or "E<code>". */
static void gai(const char *name, char *out, size_t cap) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(name, 0, &hints, &res);
    if (rc) { snprintf(out, cap, "E%d", rc); return; }
    size_t n = 0;
    out[0] = 0;
    for (struct addrinfo *p = res; p && n + 12 < cap; p = p->ai_next) {
        const unsigned char *a = (const unsigned char *)p->ai_addr;
        unsigned last = p->ai_family == AF_INET6 ? a[23] : a[7];
        n += (size_t)snprintf(out + n, cap - n, "%s%d:%u", n ? "," : "", p->ai_family, last);
    }
    freeaddrinfo(res);
}
int main(void) {
    print("hello531: options single-request\n");
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
    char got[200];
    static const char *const opts[] = {"single-request", "single-request-reopen", "single-requestx"};
    for (int k = 0; k < 3; k++) {
        char conf[160];
        snprintf(conf, sizeof conf, "nameserver 127.0.0.1\noptions timeout:2 attempts:1 %s\n", opts[k]);
        int w = write_conf(conf);
        gai("a531.test", got, sizeof got);
        take_log();
        snprintf(msg, sizeof msg, "%c: %s: %s, server saw '%s' (conf %d ready %c; 10:48,2:1, 1;r;28;r;: AAAA asked after the A reply)", 'A' + k, opts[k], got, seen, w, ready ? ready : '-');
        check(w == 0 && ready == 'R' && strcmp(got, "10:48,2:1") == 0 && strcmp(seen, "1;r;28;r;") == 0, msg);
    }
    write_conf("nameserver 127.0.0.1\noptions timeout:2 attempts:1\n");
    gai("a531.test", got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "D: no option: %s, server saw '%s' (10:48,2:1, the second question already queued: 1;r;28+;r;)", got, seen);
    check(strcmp(got, "10:48,2:1") == 0 && (strcmp(seen, "1;r;28+;r;") == 0 || strcmp(seen, "28;r;1+;r;") == 0), msg);

    write_conf("nameserver 127.0.0.1\noptions timeout:1 attempts:1 single-request\n");
    gai("silent531.test", got, sizeof got);
    take_log();
    char want[16];
    snprintf(want, sizeof want, "E%d", EAI_AGAIN);
    snprintf(msg, sizeof msg, "E: single-request, A never answered: %s, server saw '%s' (%s, 1; only)", got, seen, want);
    check(strcmp(got, want) == 0 && strcmp(seen, "1;") == 0, msg);

    int st = -1;
    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello531: FAIL\n" : "hello531: PASS\n");
    return failures ? 1 : 0;
}
