/* hello544: the "merge" action of the /etc/nsswitch.conf hosts line (glibc 2.44, measured with a local server and bind-mounted
 * files). glibc's hosts database has no merge function: a source that answers under [SUCCESS=merge] fails gethostbyname* and
 * gethostbyaddr* with errno EINVAL (h_errno HOST_NOT_FOUND for a name, unchanged for an address); getaddrinfo AF_INET (through
 * gethostbyname2_r) is EAI_NODATA with errno EINVAL, the other requests end at the next source with errno EBUSY and the code of the
 * merged status (EAI_NONAME after an answer or NXDOMAIN). merge on the last source, or for a status that did not happen, is
 * continue. A stand-in DNS server on 127.0.0.1:53 answers A for filehost.test (10.9.9.77) and a.test (10.9.9.1) and the PTR for
 * 10.5.28.9 (dnsrev.test), NXDOMAIN otherwise, and logs each question; /etc/hosts names filehost.test 10.1.1.1 and 10.5.28.9
 * filerev.test. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -r -m -n` (resolv.conf, hosts and
 * nsswitch.conf bind-mounted). */
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
#define CONF_PATH (getenv("R544") ? getenv("R544") : "/etc/resolv.conf")
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
static char msg[2000];
static void check(int ok, const char *w) {
    print(ok ? "hello544:   ok   " : "hello544:   FAIL ");
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
static const struct { const char *q; int type; unsigned char ip[4]; const char *ptr; } table[] = {
    {"filehost.test", 1, {10, 9, 9, 77}, 0},
    {"a.test", 1, {10, 9, 9, 1}, 0},
    {"9.28.5.10.in-addr.arpa", 12, {0, 0, 0, 0}, "dnsrev.test"},
};
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
        int e = -1;
        for (int i = 0; i < (int)(sizeof table / sizeof table[0]); i++)
            if (strcmp(table[i].q, name) == 0 && qtype == table[i].type) e = i;
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        r[3] = e >= 0 ? 0x80 : 0x83;
        r[6] = 0; r[7] = e >= 0 ? 1 : 0;
        r[8] = r[9] = r[10] = r[11] = 0;
        if (e >= 0) {
            len += put_name(r + len, name);
            unsigned char fixed[] = {0, (unsigned char)table[e].type, 0, 1, 0, 0, 0, 60};
            memcpy(r + len, fixed, sizeof fixed);
            len += (long)sizeof fixed;
            if (table[e].type == 1) {
                r[len++] = 0; r[len++] = 4;
                memcpy(r + len, table[e].ip, 4);
                len += 4;
            } else {
                long at = len;
                len += 2;
                long l = put_name(r + len, table[e].ptr);
                r[at] = 0; r[at + 1] = (unsigned char)l;
                len += l;
            }
        }
        sendto4(s, r, len, from);
    }
}
static int rep_fd = -1;
static char seen[400];
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
static int write_hosts(const char *text) {
    int fd = (int)open("/etc/hosts", 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
#ifdef HOST
#define NSS_PATH (getenv("N544") ? getenv("N544") : "/etc/nsswitch.conf")
#else
#define NSS_PATH "/etc/nsswitch.conf"
#endif
static int write_nss(const char *text) {
    int fd = (int)open(NSS_PATH, 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
/* gethostbyname(name) as "a.b.c.d" or "NULL/<h_errno>/<errno>", into `out`; h_errno and errno are 0 before. */
static void ghbn(const char *name, char *out, size_t cap) {
    h_errno = 0;
    errno = 0;
    struct hostent *h = gethostbyname(name);
    if (h) snprintf(out, cap, "%u.%u.%u.%u", (unsigned char)h->h_addr_list[0][0], (unsigned char)h->h_addr_list[0][1],
                    (unsigned char)h->h_addr_list[0][2], (unsigned char)h->h_addr_list[0][3]);
    else snprintf(out, cap, "NULL/%d/%d", h_errno, errno);
}
/* gethostbyname_r(name): "rc/<rc>/<herr>/<set or null>", *h_errnop 77 before. */
static void ghbn_r(const char *name, char *out, size_t cap) {
    struct hostent he, *res = 0;
    char buf[1024];
    int herr = 77;
    int rc = gethostbyname_r(name, &he, buf, sizeof buf, &res, &herr);
    snprintf(out, cap, "rc/%d/%d/%s", rc, herr, res ? "set" : "null");
}
/* getaddrinfo(name, family): "<code>/<errno>" and the first address's last byte. */
static void gai(const char *name, int family, char *out, size_t cap) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = family;
    hints.ai_socktype = SOCK_STREAM;
    errno = 0;
    int e = getaddrinfo(name, 0, &hints, &res);
    int en = errno;
    unsigned last = 0;
    if (e == 0) {
        last = res->ai_family == AF_INET ? ((unsigned char *)res->ai_addr)[7] : 6;
        freeaddrinfo(res);
        en = 0;
    }
    snprintf(out, cap, "%d/%d .%u", e, en, last);
}
/* gethostbyaddr of 10.5.28.9 as its name or "NULL/<h_errno>/<errno>" (h_errno 77 before), then getnameinfo with NI_NAMEREQD and
 * without, into `out`. */
static void rev(char *out, size_t cap) {
    unsigned char ip[4] = {10, 5, 28, 9};
    h_errno = 77;
    errno = 0;
    struct hostent *h = gethostbyaddr(ip, 4, AF_INET);
    char a[80];
    if (h) snprintf(a, sizeof a, "%s", h->h_name);
    else snprintf(a, sizeof a, "NULL/%d/%d", h_errno, errno);
    unsigned char sa[16] = {2, 0, 0, 80, 10, 5, 28, 9};
    char g[80] = "";
    int e1 = getnameinfo((void *)sa, 16, g, sizeof g, 0, 0, NI_NAMEREQD);
    int e2 = getnameinfo((void *)sa, 16, g, sizeof g, 0, 0, 0);
    snprintf(out, cap, "%s gni %d %d %s", a, e1, e2, e2 ? "-" : g);
}
int main(void) {
    print("hello544: nsswitch.conf merge action\n");
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
    int wh = write_hosts("127.0.0.1 localhost\n10.1.1.1 filehost.test\n10.5.28.9 filerev.test\n");
    char x[100], y[100], z[100], w[100], want[200];

    int wn = write_nss("hosts: files [SUCCESS=merge] dns\n");
    ghbn("filehost.test", x, sizeof x);
    ghbn_r("filehost.test", y, sizeof y);
    gai("filehost.test", AF_UNSPEC, z, sizeof z);
    gai("filehost.test", AF_INET, w, sizeof w);
    take_log();
    snprintf(want, sizeof want, "NULL/1/22 rc/22/1/null %d/16 .0 %d/22 .0", EAI_NONAME, EAI_NODATA);
    snprintf(msg, sizeof msg, "A: files [SUCCESS=merge] dns, filehost.test: %s %s %s %s, asked '%s' (conf %d hosts %d nss %d ready %c; %s, nothing)",
             x, y, z, w, seen, wc, wh, wn, ready ? ready : '-', want);
    char got[400];
    snprintf(got, sizeof got, "%s %s %s %s", x, y, z, w);
    check(wc == 0 && wh == 0 && wn == 0 && ready == 'R' && strcmp(got, want) == 0 && seen[0] == 0, msg);

    ghbn("a.test", x, sizeof x);
    take_log();
    snprintf(msg, sizeof msg, "B: the same line, a.test (not in the file): %s, asked '%s' (10.9.9.1, a.test/1;)", x, seen);
    check(strcmp(x, "10.9.9.1") == 0 && strcmp(seen, "a.test/1;") == 0, msg);

    rev(x, sizeof x);
    take_log();
    snprintf(want, sizeof want, "NULL/77/22 gni %d 0 10.5.28.9", EAI_NONAME);
    snprintf(msg, sizeof msg, "C: the same line, 10.5.28.9 (in the file): %s, asked '%s' (%s, nothing)", x, seen, want);
    check(strcmp(x, want) == 0 && seen[0] == 0, msg);

    write_nss("hosts: dns [SUCCESS=merge] files\n");
    ghbn("filehost.test", x, sizeof x);
    gai("filehost.test", AF_INET, y, sizeof y);
    rev(z, sizeof z);
    take_log();
    snprintf(want, sizeof want, "NULL/1/22 %d/22 .0 NULL/77/22 gni %d 0 10.5.28.9", EAI_NODATA, EAI_NONAME);
    snprintf(got, sizeof got, "%s %s %s", x, y, z);
    snprintf(msg, sizeof msg, "D: dns [SUCCESS=merge] files: %s, asked '%s' (%s; A twice, the PTR three times)", got, seen, want);
    check(strcmp(got, want) == 0 &&
              strcmp(seen, "filehost.test/1;filehost.test/1;9.28.5.10.in-addr.arpa/12;9.28.5.10.in-addr.arpa/12;9.28.5.10.in-addr.arpa/12;") == 0,
          msg);

    write_nss("hosts: dns [NOTFOUND=merge] files\n");
    ghbn("filerev.test", x, sizeof x);
    gai("filerev.test", AF_INET, y, sizeof y);
    gai("filerev.test", AF_UNSPEC, z, sizeof z);
    take_log();
    snprintf(want, sizeof want, "10.5.28.9 0/0 .9 %d/16 .0", EAI_NONAME);
    snprintf(got, sizeof got, "%s %s %s", x, y, z);
    snprintf(msg, sizeof msg, "E: dns [NOTFOUND=merge] files, filerev.test (NXDOMAIN): %s, asked '%s' (%s; A, A, then A and AAAA)", got, seen, want);
    check(strcmp(got, want) == 0 && strncmp(seen, "filerev.test/1;filerev.test/1;", 30) == 0 && strstr(seen + 30, "filerev.test/1;") &&
              strstr(seen + 30, "filerev.test/28;") && strlen(seen) == 30 + 15 + 16, msg);

    write_nss("hosts: files [SUCCESS=merge]\n");
    ghbn("filehost.test", x, sizeof x);
    gai("filehost.test", AF_UNSPEC, y, sizeof y);
    take_log();
    snprintf(msg, sizeof msg, "F: files [SUCCESS=merge] alone: %s %s, asked '%s' (NULL/1/22 0/0 .1, nothing)", x, y, seen);
    check(strcmp(x, "NULL/1/22") == 0 && strcmp(y, "0/0 .1") == 0 && seen[0] == 0, msg);

    int st = -1;
    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0, u2 = 0, u3 = 0; /* the host files are bind-mount targets */
#else
    long u = unlink(CONF_PATH), u2 = unlink("/etc/hosts"), u3 = unlink(NSS_PATH);
#endif
    snprintf(msg, sizeof msg, "G: unlink %ld %ld %ld (0 0 0)", u, u2, u3);
    check(u == 0 && u2 == 0 && u3 == 0, msg);
    print(failures ? "hello544: FAIL\n" : "hello544: PASS\n");
    return failures ? 1 : 0;
}
