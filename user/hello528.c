/* hello528: the "hosts:" line of /etc/nsswitch.conf (glibc 2.44, measured with a local server and bind-mounted files). A stand-in
 * DNS server on 127.0.0.1:53 answers A queries for filehost.test (10.9.9.77) and a.test (10.9.9.1) and the PTR query for 10.5.28.9
 * (dnsrev.test), NXDOMAIN otherwise, and logs each question; /etc/hosts names filehost.test 10.1.1.1, onlyfile.test 10.1.1.2
 * and 10.5.28.9 filerev.test.
 * A: "files dns" answers filehost.test from the file without a query; B: "dns files" asks DNS first and takes its answer, and goes
 * on to the file after NXDOMAIN; C: "files" never asks (HOST_NOT_FOUND, EAI_NONAME); D: "files [NOTFOUND=return] dns" stops after
 * the file; E: no hosts line is "files dns"; F: an empty line is refused: NETDB_INTERNAL, EAI_SYSTEM, and getnameinfo EAI_SYSTEM;
 * G: "dns files" for an address names it by PTR, "files" from the file only; H: the last "hosts" line counts, '#' lines
 * are comments, and "Hosts" is not "hosts"; I: a service glibc does not know ("bogus") is skipped. Needs root (port 53 and
 * /etc). Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf, hosts and nsswitch.conf bind-mounted). */
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
#define CONF_PATH (getenv("R528") ? getenv("R528") : "/etc/resolv.conf")
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
    print(ok ? "hello528:   ok   " : "hello528:   FAIL ");
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
#define NSS_PATH (getenv("N528") ? getenv("N528") : "/etc/nsswitch.conf")
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
/* gethostbyname(name) as "a.b.c.d" or "NULL/<h_errno>", then the getaddrinfo(AF_INET) code and first address, into `out`. */
static void fwd(const char *name, char *out, size_t cap) {
    struct hostent *h = gethostbyname(name);
    char a[40];
    if (h) snprintf(a, sizeof a, "%u.%u.%u.%u", (unsigned char)h->h_addr_list[0][0], (unsigned char)h->h_addr_list[0][1],
                    (unsigned char)h->h_addr_list[0][2], (unsigned char)h->h_addr_list[0][3]);
    else snprintf(a, sizeof a, "NULL/%d", h_errno);
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int e = getaddrinfo(name, 0, &hints, &res);
    unsigned last = 0;
    if (e == 0) {
        last = ((unsigned char *)res->ai_addr)[7];
        freeaddrinfo(res);
    }
    snprintf(out, cap, "%s gai %d .%u", a, e, last);
}
/* gethostbyaddr of 10.5.28.<d> as its name or "NULL/<h_errno>", then getnameinfo's code and text, into `out`. */
static void rev(unsigned d, char *out, size_t cap) {
    unsigned char ip[4] = {10, 5, 28, (unsigned char)d};
    struct hostent *h = gethostbyaddr(ip, 4, AF_INET);
    char a[80];
    if (h) snprintf(a, sizeof a, "%s", h->h_name);
    else snprintf(a, sizeof a, "NULL/%d", h_errno);
    unsigned char sa[16] = {2, 0, 0, 80, 10, 5, 28, (unsigned char)d};
    char g[80] = "";
    int e = getnameinfo((void *)sa, 16, g, sizeof g, 0, 0, 0);
    snprintf(out, cap, "%s gni %d %s", a, e, e ? "-" : g);
}
int main(void) {
    print("hello528: /etc/nsswitch.conf hosts line\n");
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
    int wh = write_hosts("127.0.0.1 localhost\n10.1.1.1 filehost.test\n10.1.1.2 onlyfile.test\n10.5.28.9 filerev.test\n");
    char x[100], y[100];

    int wn = write_nss("hosts: files dns\n");
    fwd("filehost.test", x, sizeof x);
    take_log();
    snprintf(msg, sizeof msg, "A: files dns: filehost.test %s, asked '%s' (conf %d hosts %d nss %d ready %c; 10.1.1.1 gai 0 .1, nothing)",
             x, seen, wc, wh, wn, ready ? ready : '-');
    check(wc == 0 && wh == 0 && wn == 0 && ready == 'R' && strcmp(x, "10.1.1.1 gai 0 .1") == 0 && seen[0] == 0, msg);

    write_nss("hosts: dns files\n");
    fwd("filehost.test", x, sizeof x);
    fwd("onlyfile.test", y, sizeof y);
    take_log();
    snprintf(msg, sizeof msg, "B: dns files: filehost.test %s; onlyfile.test %s; asked '%s' (10.9.9.77 gai 0 .77; 10.1.1.2 gai 0 .2 after NXDOMAIN)", x, y, seen);
    check(strcmp(x, "10.9.9.77 gai 0 .77") == 0 && strcmp(y, "10.1.1.2 gai 0 .2") == 0 &&
              strcmp(seen, "filehost.test/1;filehost.test/1;onlyfile.test/1;onlyfile.test/1;") == 0, msg);

    write_nss("hosts: files\n");
    fwd("a.test", x, sizeof x);
    take_log();
    snprintf(msg, sizeof msg, "C: files: a.test %s, asked '%s' (NULL/1 gai %d .0, nothing)", x, seen, EAI_NONAME);
    char want[80];
    snprintf(want, sizeof want, "NULL/1 gai %d .0", EAI_NONAME);
    check(strcmp(x, want) == 0 && seen[0] == 0, msg);

    write_nss("hosts: files [NOTFOUND=return] dns\n");
    fwd("a.test", x, sizeof x);
    take_log();
    snprintf(msg, sizeof msg, "D: files [NOTFOUND=return] dns: a.test %s, asked '%s' (%s, nothing)", x, seen, want);
    check(strcmp(x, want) == 0 && seen[0] == 0, msg);

    write_nss("passwd: files\n");
    fwd("filehost.test", x, sizeof x);
    fwd("a.test", y, sizeof y);
    take_log();
    snprintf(msg, sizeof msg, "E: no hosts line: filehost.test %s; a.test %s; asked '%s' (10.1.1.1 gai 0 .1; 10.9.9.1 gai 0 .1)", x, y, seen);
    check(strcmp(x, "10.1.1.1 gai 0 .1") == 0 && strcmp(y, "10.9.9.1 gai 0 .1") == 0 && strcmp(seen, "a.test/1;a.test/1;") == 0, msg);

    write_nss("hosts:\n");
    fwd("filehost.test", x, sizeof x);
    rev(9, y, sizeof y);
    take_log();
    snprintf(msg, sizeof msg, "F: empty line: filehost.test %s; 10.5.28.9 %s; asked '%s' (NULL/-1 gai -11 .0; NULL/-1 gni -11 -; nothing)", x, y, seen);
    check(strcmp(x, "NULL/-1 gai -11 .0") == 0 && strcmp(y, "NULL/-1 gni -11 -") == 0 && seen[0] == 0, msg);

    write_nss("hosts: dns files\n");
    rev(9, x, sizeof x);
    write_nss("hosts: files\n");
    rev(9, y, sizeof y);
    char z[100];
    rev(8, z, sizeof z);
    take_log();
    snprintf(msg, sizeof msg, "G: dns files: 10.5.28.9 %s; files: %s; 10.5.28.8 %s; asked '%s' (dnsrev.test gni 0 dnsrev.test; filerev.test gni 0 filerev.test; NULL/1 gni 0 10.5.28.8; the PTR twice)", x, y, z, seen);
    check(strcmp(x, "dnsrev.test gni 0 dnsrev.test") == 0 && strcmp(y, "filerev.test gni 0 filerev.test") == 0 &&
              strcmp(z, "NULL/1 gni 0 10.5.28.8") == 0 && strcmp(seen, "9.28.5.10.in-addr.arpa/12;9.28.5.10.in-addr.arpa/12;") == 0, msg);

    write_nss("# hosts: files\nhosts: files\n hosts : dns\nHosts: files\n#hosts: files\n");
    fwd("filehost.test", x, sizeof x);
    take_log();
    snprintf(msg, sizeof msg, "H: the last hosts line (not Hosts, not a comment): filehost.test %s, asked '%s' (10.9.9.77 gai 0 .77)", x, seen);
    check(strcmp(x, "10.9.9.77 gai 0 .77") == 0 && strcmp(seen, "filehost.test/1;filehost.test/1;") == 0, msg);

    write_nss("hosts: files bogus dns\n");
    fwd("nosuch.test", y, sizeof y);
    fwd("a.test", z, sizeof z);
    take_log();
    char want2[80];
    snprintf(want2, sizeof want2, "NULL/1 gai %d .0", EAI_NONAME);
    snprintf(msg, sizeof msg, "I: files bogus dns: nosuch.test %s, a.test %s, asked '%s' (%s; 10.9.9.1 gai 0 .1; both asked)", y, z, seen, want2);
    check(strcmp(y, want2) == 0 && strcmp(z, "10.9.9.1 gai 0 .1") == 0 &&
              strcmp(seen, "nosuch.test/1;nosuch.test/1;a.test/1;a.test/1;") == 0, msg);

    int st = -1;
    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, &st, 0); }
    if (pr == 0) close(p[0]);
    (void)closefd;
#ifdef HOST
    long u = 0, u2 = 0, u3 = 0; /* the host files are bind-mount targets */
#else
    long u = unlink(CONF_PATH), u2 = unlink("/etc/hosts"), u3 = unlink(NSS_PATH);
#endif
    snprintf(msg, sizeof msg, "J: unlink %ld %ld %ld (0 0 0)", u, u2, u3);
    check(u == 0 && u2 == 0 && u3 == 0, msg);
    print(failures ? "hello528: FAIL\n" : "hello528: PASS\n");
    return failures ? 1 : 0;
}
