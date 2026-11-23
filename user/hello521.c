/* hello521: reverse DNS (PTR) for addresses /etc/hosts does not name (glibc 2.44 gethostbyaddr/getnameinfo through "files dns",
 * measured with a local server). A stand-in DNS server on 127.0.0.1:53 answers PTR queries from a table and logs each question. A:
 * gethostbyaddr(10.5.21.4) asks 4.21.5.10.in-addr.arpa and gets host4.test, with the address asked for in h_addr_list; B: two PTR
 * records give the first; C: a CNAME (RFC 2317 classless delegation) is followed, and a trailing dot is dropped with the case kept;
 * D: no PTR is HOST_NOT_FOUND, a NOERROR reply without answers NO_DATA, a PTR for another owner NO_RECOVERY; E: an IPv6 address asks
 * its ip6.arpa name, and ::ffff:10.5.21.4 asks the IPv4 one and is answered as an IPv4 host (h_length 4; glibc 2.44 does so
 * for a DNS answer, unlike its /etc/hosts answer, which keeps the 16 bytes); F: getnameinfo gives the PTR name, the
 * numeric form when there is none, and EAI_NONAME with NI_NAMEREQD; G: an address in /etc/hosts is answered from the file without a
 * query. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf, hosts and nsswitch.conf
 * "hosts: files dns" bind-mounted). */
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
#define CONF_PATH (getenv("R521") ? getenv("R521") : "/etc/resolv.conf")
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
    print(ok ? "hello521:   ok   " : "hello521:   FAIL ");
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
/* The PTR table: the question name, then up to two records (type 12 PTR or 5 CNAME, owner, target); rcode 0 with n == 0 is NODATA. */
struct rec { int type; const char *owner, *target; };
struct entry { const char *q; struct rec r[2]; int n; };
static const struct entry table[] = {
    {"4.21.5.10.in-addr.arpa", {{12, "4.21.5.10.in-addr.arpa", "host4.test"}}, 1},
    {"5.21.5.10.in-addr.arpa", {{12, "5.21.5.10.in-addr.arpa", "a5.test"}, {12, "5.21.5.10.in-addr.arpa", "b5.test"}}, 2},
    {"6.21.5.10.in-addr.arpa", {{5, "6.21.5.10.in-addr.arpa", "6.0-24.21.5.10.in-addr.arpa"}, {12, "6.0-24.21.5.10.in-addr.arpa", "C6.Test."}}, 2},
    {"7.21.5.10.in-addr.arpa", {{12, "other.in-addr.arpa", "d7.test"}}, 1},
    {"8.21.5.10.in-addr.arpa", {{0, 0, 0}}, 0},
    {"7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa", {{12, "7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa", "v6.test"}}, 1},
};
static long put_name(unsigned char *p, const char *name) {
    long o = 0;
    while (*name) {
        const char *dot = strchr(name, '.');
        long l = dot ? dot - name : (long)strlen(name);
        if (l) {
            p[o++] = (unsigned char)l;
            memcpy(p + o, name, (size_t)l);
            o += l;
        }
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
        char line[300];
        int ll = snprintf(line, sizeof line, "%s/%d;", name, qtype);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        const struct entry *e = 0;
        for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
            if (strcmp(table[i].q, name) == 0 && qtype == 12) e = &table[i];
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        r[3] = e ? 0x80 : 0x83;
        r[6] = 0; r[7] = (unsigned char)(e ? e->n : 0);
        r[8] = r[9] = r[10] = r[11] = 0;
        for (int i = 0; e && i < e->n; i++) {
            len += put_name(r + len, e->r[i].owner);
            unsigned char fixed[] = {0, (unsigned char)e->r[i].type, 0, 1, 0, 0, 0, 60};
            memcpy(r + len, fixed, sizeof fixed);
            len += (long)sizeof fixed;
            long at = len;
            len += 2;
            long l = put_name(r + len, e->r[i].target);
            r[at] = 0; r[at + 1] = (unsigned char)l;
            len += l;
        }
        sendto4(s, r, len, from);
    }
}
static int rep_fd = -1;
static char seen[600];
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
/* gethostbyaddr of a.b.c.d; its name or "NULL/<h_errno>" into `out`. */
static void rev4(unsigned a, unsigned b, unsigned c, unsigned d, char *out, size_t cap) {
    unsigned char ip[4] = {(unsigned char)a, (unsigned char)b, (unsigned char)c, (unsigned char)d};
    struct hostent *h = gethostbyaddr(ip, 4, AF_INET);
    if (h) snprintf(out, cap, "%s", h->h_name);
    else snprintf(out, cap, "NULL/%d", h_errno);
}
static int write_hosts(const char *text) {
    int fd = (int)open("/etc/hosts", 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
int main(void) {
    print("hello521: reverse DNS (PTR)\n");
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
    int wh = write_hosts("127.0.0.1 localhost\n10.5.21.9 file9.test\n");

    unsigned char ip4[4] = {10, 5, 21, 4};
    struct hostent *h = gethostbyaddr(ip4, 4, AF_INET);
    char nm[80];
    snprintf(nm, sizeof nm, "%s", h ? h->h_name : "NULL");
    unsigned last = h && h->h_addr_list[0] ? (unsigned char)h->h_addr_list[0][3] : 0;
    int len4 = h ? h->h_length : 0;
    take_log();
    snprintf(msg, sizeof msg, "A: gethostbyaddr(10.5.21.4) %s, address .%u length %d, asked '%s' (conf %d hosts %d ready %c; host4.test .4 4, 4.21.5.10.in-addr.arpa/12;)",
             nm, last, len4, seen, wc, wh, ready ? ready : '-');
    check(wc == 0 && wh == 0 && ready == 'R' && strcmp(nm, "host4.test") == 0 && last == 4 && len4 == 4 && strcmp(seen, "4.21.5.10.in-addr.arpa/12;") == 0, msg);

    char b5[80], c6[80];
    rev4(10, 5, 21, 5, b5, sizeof b5);
    rev4(10, 5, 21, 6, c6, sizeof c6);
    snprintf(msg, sizeof msg, "B/C: two PTRs %s; a CNAME then a PTR with a trailing dot %s (a5.test C6.Test)", b5, c6);
    check(strcmp(b5, "a5.test") == 0 && strcmp(c6, "C6.Test") == 0, msg);

    char d1[80], d2[80], d3[80];
    rev4(10, 5, 21, 3, d1, sizeof d1);
    rev4(10, 5, 21, 8, d2, sizeof d2);
    rev4(10, 5, 21, 7, d3, sizeof d3);
    snprintf(msg, sizeof msg, "D: no PTR %s, NOERROR without answers %s, a PTR for another owner %s (NULL/1 NULL/4 NULL/3)", d1, d2, d3);
    check(strcmp(d1, "NULL/1") == 0 && strcmp(d2, "NULL/4") == 0 && strcmp(d3, "NULL/3") == 0, msg);

    take_log();
    unsigned char v6[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7};
    unsigned char m6[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 5, 21, 4};
    h = gethostbyaddr(v6, 16, AF_INET6);
    char e1[80];
    snprintf(e1, sizeof e1, "%s", h ? h->h_name : "NULL");
    h = gethostbyaddr(m6, 16, AF_INET6);
    char e2[80];
    snprintf(e2, sizeof e2, "%s", h ? h->h_name : "NULL");
    int e2len = h ? h->h_length : 0;
    unsigned e2last = h && h->h_addr_list[0] ? (unsigned char)h->h_addr_list[0][15] : 0;
    take_log();
    snprintf(msg, sizeof msg, "E: 2001:db8::7 %s; ::ffff:10.5.21.4 %s length %d; asked '%s' (v6.test host4.test 4, the ip6.arpa name then 4.21.5.10.in-addr.arpa)",
             e1, e2, e2len, seen);
    (void)e2last;
    check(strcmp(e1, "v6.test") == 0 && strcmp(e2, "host4.test") == 0 && e2len == 4 &&
              strstr(seen, "7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa/12;") && strstr(seen, "4.21.5.10.in-addr.arpa/12;"), msg);

    unsigned char sa[16] = {2, 0, 0, 80, 10, 5, 21, 4};
    char g1[80] = "", g2[80] = "";
    int r1 = getnameinfo((void *)sa, 16, g1, sizeof g1, 0, 0, 0);
    sa[7] = 3;
    int r2 = getnameinfo((void *)sa, 16, g2, sizeof g2, 0, 0, 0);
    int r3 = getnameinfo((void *)sa, 16, g2, sizeof g2, 0, 0, NI_NAMEREQD);
    snprintf(msg, sizeof msg, "F: getnameinfo 10.5.21.4 %d %s; 10.5.21.3 %d %s; NI_NAMEREQD %d (0 host4.test 0 10.5.21.3 %d)", r1, g1, r2, g2, r3, EAI_NONAME);
    check(r1 == 0 && strcmp(g1, "host4.test") == 0 && r2 == 0 && strcmp(g2, "10.5.21.3") == 0 && r3 == EAI_NONAME, msg);

    take_log();
    char f9[80];
    rev4(10, 5, 21, 9, f9, sizeof f9);
    take_log();
    snprintf(msg, sizeof msg, "G: 10.5.21.9 from /etc/hosts %s, asked '%s' (file9.test, nothing)", f9, seen);
    check(strcmp(f9, "file9.test") == 0 && seen[0] == 0, msg);

    int st = -1;
    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0, u2 = 0; /* the host files are bind-mount targets */
#else
    long u = unlink(CONF_PATH), u2 = unlink("/etc/hosts");
#endif
    snprintf(msg, sizeof msg, "H: unlink %ld %ld (0 0)", u, u2);
    check(u == 0 && u2 == 0, msg);
    print(failures ? "hello521: FAIL\n" : "hello521: PASS\n");
    return failures ? 1 : 0;
}
