/* hello530: getaddrinfo(AF_UNSPEC) sends its A and AAAA queries together (glibc 2.44, measured with a local server). A stand-in DNS
 * server on 127.0.0.1:53 logs each question with its type and source port: A: both530.test (A 10.5.30.1, AAAA 2001:db8::530):
 * the A and the AAAA query arrive from one port before either reply is needed, and both addresses come back, IPv6 first;
 * B: with "search d1.test d2.test", x.d1.test has only an A record (AAAA NXDOMAIN) and x.d2.test has both: the lookup of "x"
 * stops at d1 with its one address, as glibc does (a lookup asking A and AAAA one after the other ran on to d2 for the AAAA);
 * C: x.d1.test NXDOMAIN for both and x.d2.test both answering: d2's two addresses; D: a server that answers the A query only
 * after the AAAA query has arrived (it holds the A reply until then) still answers within the limit. Needs root (port 53 and
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
#define CONF_PATH (getenv("R530") ? getenv("R530") : "/etc/resolv.conf")
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
#endif
static int failures;
static char msg[1000];
static void check(int ok, const char *w) {
    print(ok ? "hello530:   ok   " : "hello530:   FAIL ");
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
    if (strcmp(name, "both530.test") == 0 || strcmp(name, "x.d2.test") == 0 || strcmp(name, "hold530.test") == 0) a = aaaa = 1;
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
    /* An A query for hold530.test is answered only once its AAAA query has arrived. */
    unsigned char held[512], held_from[16];
    long held_n = 0;
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        char line[300];
        int ll = snprintf(line, sizeof line, "%s/%d:%u;", name, qtype, (unsigned)(from[2] << 8 | from[3]));
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        if (strcmp(name, "hold530.test") == 0 && qtype == 1) {
            memcpy(held, q, (size_t)n);
            memcpy(held_from, from, 16);
            held_n = n;
            continue;
        }
        long len = reply(r, q, n, name, qtype);
        sendto4(s, r, len, from);
        if (held_n && strcmp(name, "hold530.test") == 0) {
            len = reply(r, held, held_n, name, 1);
            sendto4(s, r, len, held_from);
            held_n = 0;
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
/* The ports of the "name/type:port;" entries for `name`: both types from one port, each asked once. */
static int one_port(const char *log, const char *name) {
    char k1[300], k2[300];
    snprintf(k1, sizeof k1, "%s/1:", name);
    snprintf(k2, sizeof k2, "%s/28:", name);
    const char *a = strstr(log, k1), *b = strstr(log, k2);
    if (!a || !b) return 0;
    if (strstr(a + 1, k1) || strstr(b + 1, k2)) return 0;
    return atoi(a + strlen(k1)) == atoi(b + strlen(k2));
}
int main(void) {
    print("hello530: AF_UNSPEC asks A and AAAA together\n");
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

    int wa = write_conf("nameserver 127.0.0.1\noptions timeout:2 attempts:1\n");
    gai("both530.test", got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "A: both530.test %s, asked '%s' (conf %d ready %c; 10:48,2:1, A and AAAA from one port)", got, seen, wa, ready ? ready : '-');
    check(wa == 0 && ready == 'R' && strcmp(got, "10:48,2:1") == 0 && one_port(seen, "both530.test"), msg);

    write_conf("nameserver 127.0.0.1\nsearch d1.test d2.test\noptions timeout:2 attempts:1\n");
    gai("x", got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "B: x with only an A record at d1: %s, asked '%s' (2:11, d1 only)", got, seen);
    check(strcmp(got, "2:11") == 0 && one_port(seen, "x.d1.test") && !strstr(seen, "x.d2.test"), msg);

    write_conf("nameserver 127.0.0.1\nsearch d0.test d2.test\noptions timeout:2 attempts:1\n");
    gai("x", got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "C: x NXDOMAIN at d0, both at d2: %s, asked '%s' (10:48,2:12)", got, seen);
    check(strcmp(got, "10:48,2:12") == 0 && one_port(seen, "x.d0.test") && one_port(seen, "x.d2.test"), msg);

    write_conf("nameserver 127.0.0.1\noptions timeout:2 attempts:1\n");
    gai("hold530.test", got, sizeof got);
    take_log();
    snprintf(msg, sizeof msg, "D: the A reply held until the AAAA query arrives: %s, asked '%s' (10:48,2:1)", got, seen);
    check(strcmp(got, "10:48,2:1") == 0 && one_port(seen, "hold530.test"), msg);

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
    print(failures ? "hello530: FAIL\n" : "hello530: PASS\n");
    return failures ? 1 : 0;
}
