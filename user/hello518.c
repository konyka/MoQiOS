/* hello518: /etc/resolv.conf "search", "domain" and "options ndots" (glibc res_search, measured). A stand-in DNS server on
 * 127.0.0.1:53 knows x518.b.test, y.z.a518.test and lit518.test and logs every question. A "search a518.test b.test": gethostbyname("x518")
 * asks x518.a518.test (NXDOMAIN), then x518.b.test, which answers, and that is h_name; B a name with a dot ("y.z") is asked as given
 * first, then with the domains; C a trailing dot asks for the name alone; D "options ndots:2" puts the domains before a one-dot name;
 * E "domain b.test" is a one-entry search list; F getaddrinfo(AI_CANONNAME) reports the name that answered; G a dotted literal is
 * not searched; H a name that nobody knows is asked with every domain and then as given, and fails. Needs root (port 53 and /etc).
 * Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf and nsswitch.conf "hosts: files dns" bind-mounted, lo up). */
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
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define CONF_PATH (getenv("R518") ? getenv("R518") : "/etc/resolv.conf")
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
    print(ok ? "hello518:   ok   " : "hello518:   FAIL ");
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
static const char *const known[] = {"x518.b.test", "y.z.a518.test", "lit518.test"};
/* The server: answers the names above with 10.5.18.<index+1>, anything else NXDOMAIN, until it reads a query for "stop518". Every
 * question name goes to the pipe `report` followed by ';'. */
static void serve(int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512], r[512];
    sa4(sa, 127, 0, 0, 1, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    if (write(report, "R", 1) != 1) _exit(3); /* ready */
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        if (strcmp(name, "stop518") == 0) break;
        char line[300];
        int ll = snprintf(line, sizeof line, "%s;", name);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        int hit = -1;
        for (int i = 0; i < 3; i++) if (strcmp(name, known[i]) == 0 && qtype == 1) hit = i;
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        r[3] = hit >= 0 ? 0x80 : 0x83; /* RA, NOERROR or NXDOMAIN */
        r[6] = 0; r[7] = hit >= 0 ? 1 : 0;
        r[8] = r[9] = r[10] = r[11] = 0;
        if (hit >= 0) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 18, (unsigned char)(hit + 1)};
            memcpy(r + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
        sendto4(s, r, len, from);
    }
    closefd(s);
    _exit(0);
}
static int rep_fd = -1;
static char seen[200];
/* What the server logged since the last call, into `seen`: the pipe is non-blocking, and is read until it holds `want` entries or
 * stays empty for about a second. */
static void take_log(int want) {
    size_t n = 0;
    int got = 0;
    for (int idle = 0; idle < 200 && got < want && n + 1 < sizeof seen;) {
        long k = (long)read(rep_fd, seen + n, 1);
        if (k <= 0) {
            idle++;
            usleep(5000);
            continue;
        }
        if (seen[n] == ';') got++;
        n++;
    }
    seen[n] = 0;
}
static unsigned last_octet(struct hostent *h) { return h && h->h_addr_list[0] ? (unsigned char)h->h_addr_list[0][3] : 0; }
int main(void) {
    print("hello518: /etc/resolv.conf search, domain and ndots\n");
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

    int wa = write_conf("nameserver 127.0.0.1\nsearch a518.test b.test\n");
    struct hostent *h = gethostbyname("x518");
    char name_a[100];
    snprintf(name_a, sizeof name_a, "%s", h ? h->h_name : "NULL");
    unsigned oa = last_octet(h);
    take_log(2);
    snprintf(msg, sizeof msg, "A: search a518.test b.test: gethostbyname(x518) %s .%u, asked '%s' (conf %d ready %c; x518.b.test .1, x518.a518.test;x518.b.test;)",
             name_a, oa, seen, wa, ready ? ready : '-');
    check(wa == 0 && ready == 'R' && strcmp(name_a, "x518.b.test") == 0 && oa == 1 && strcmp(seen, "x518.a518.test;x518.b.test;") == 0, msg);

    h = gethostbyname("y.z");
    snprintf(name_a, sizeof name_a, "%s", h ? h->h_name : "NULL");
    unsigned ob = last_octet(h);
    take_log(2);
    snprintf(msg, sizeof msg, "B: gethostbyname(y.z) %s .%u, asked '%s' (y.z.a518.test .2, y.z;y.z.a518.test;)", name_a, ob, seen);
    check(strcmp(name_a, "y.z.a518.test") == 0 && ob == 2 && strcmp(seen, "y.z;y.z.a518.test;") == 0, msg);

    h = gethostbyname("x518.");
    int c_herr = h_errno;
    take_log(1);
    snprintf(msg, sizeof msg, "C: gethostbyname(x518.) %s h_errno %d, asked '%s' (NULL 1, x518;)", h ? h->h_name : "NULL", c_herr, seen);
    check(!h && c_herr == HOST_NOT_FOUND && strcmp(seen, "x518;") == 0, msg);

    int wd = write_conf("nameserver 127.0.0.1\nsearch a518.test b.test\noptions ndots:2\n");
    h = gethostbyname("y.z");
    snprintf(name_a, sizeof name_a, "%s", h ? h->h_name : "NULL");
    take_log(1);
    snprintf(msg, sizeof msg, "D: ndots:2, gethostbyname(y.z) %s, asked '%s' (conf %d; y.z.a518.test, y.z.a518.test;)", name_a, seen, wd);
    check(wd == 0 && strcmp(name_a, "y.z.a518.test") == 0 && strcmp(seen, "y.z.a518.test;") == 0, msg);

    int we = write_conf("nameserver 127.0.0.1\ndomain b.test\n");
    h = gethostbyname("x518");
    snprintf(name_a, sizeof name_a, "%s", h ? h->h_name : "NULL");
    take_log(1);
    snprintf(msg, sizeof msg, "E: domain b.test, gethostbyname(x518) %s, asked '%s' (conf %d; x518.b.test, x518.b.test;)", name_a, seen, we);
    check(we == 0 && strcmp(name_a, "x518.b.test") == 0 && strcmp(seen, "x518.b.test;") == 0, msg);

    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_CANONNAME;
    int ge = getaddrinfo("x518", 0, &hints, &res);
    snprintf(name_a, sizeof name_a, "%s", ge == 0 && res && res->ai_canonname ? res->ai_canonname : "-");
    unsigned of = ge == 0 && res ? ((unsigned char *)res->ai_addr)[7] : 0;
    if (ge == 0) freeaddrinfo(res);
    take_log(1);
    snprintf(msg, sizeof msg, "F: getaddrinfo(x518, AI_CANONNAME) %d '%s' .%u, asked '%s' (0 x518.b.test .1, x518.b.test;)", ge, name_a, of, seen);
    check(ge == 0 && strcmp(name_a, "x518.b.test") == 0 && of == 1 && strcmp(seen, "x518.b.test;") == 0, msg);

    int wg = write_conf("nameserver 127.0.0.1\nsearch a518.test\noptions ndots:5\n");
    h = gethostbyname("10.5.18.9");
    unsigned og = last_octet(h);
    snprintf(name_a, sizeof name_a, "%s", h ? h->h_name : "NULL");
    h = gethostbyname("nobody518");
    int h_herr = h_errno;
    take_log(2);
    snprintf(msg, sizeof msg, "G/H: ndots:5, literal %s .%u; gethostbyname(nobody518) %s h_errno %d; asked '%s' (conf %d; 10.5.18.9 .9; NULL 1; nobody518.a518.test;nobody518;)",
             name_a, og, h ? "set" : "NULL", h_herr, seen, wg);
    check(wg == 0 && strcmp(name_a, "10.5.18.9") == 0 && og == 9 && !h && h_herr == HOST_NOT_FOUND && strcmp(seen, "nobody518.a518.test;nobody518;") == 0, msg);

    /* Stop the server with a query it recognises, through the resolver itself. */
    write_conf("nameserver 127.0.0.1\n");
    gethostbyname("stop518");
    int st = -1;
    if (pid > 0) {
        kill(pid, SIGKILL);
        waitpid(pid, &st, 0);
    }
    if (pr == 0) close(p[0]);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "I: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello518: FAIL\n" : "hello518: PASS\n");
    return failures ? 1 : 0;
}
