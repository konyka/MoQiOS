/* hello519: /etc/resolv.conf "options timeout:N attempts:N" and what each reply code means (glibc res_send/res_search, measured).
 * Stand-in DNS servers on 127.0.0.1:53 and 127.0.0.2:53 (two children) log every question; the first one's answers are
 * scripted by what the name contains: "silent-" gets no reply, "sf-" SERVFAIL, "ref-" REFUSED, "fe-" FORMERR, "nd-" NOERROR without an
 * answer, anything else NXDOMAIN; the second answers every name with 10.5.19.2. A: timeout:1 attempts:3 with one silent server: three
 * queries a second apart, then TRY_AGAIN after about 3 s; B: attempts:1 with both servers, a silent first one: the second
 * answers after about 1 s; C: SERVFAIL and REFUSED from the first server send the query on to the second at once; D: NXDOMAIN,
 * NODATA and FORMERR end it at the first server, as HOST_NOT_FOUND, NO_DATA and NO_RECOVERY; E: getaddrinfo reports NODATA as
 * EAI_NODATA and a server that never replies as EAI_AGAIN; F: a search domain answered with REFUSED ends the domain list, but the
 * name as given is still asked. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -m -n` (resolv.conf
 * and nsswitch.conf "hosts: files dns" bind-mounted, lo up with 127.0.0.2). */
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
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define CONF_PATH (getenv("R519") ? getenv("R519") : "/etc/resolv.conf")
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
#include "../lib/moqi_libc/include/time.h"
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
    print(ok ? "hello519:   ok   " : "hello519:   FAIL ");
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
static int starts(const char *s, const char *p) { return strstr(s, p) != 0; }
/* A server on 127.0.0.<last>:53. The first (last == 1) answers by the name's prefix as described above; the second answers every
 * name with 10.5.19.2. Every question goes to `report` as "<last>:<name>;". */
static void serve(int last, int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512], r[512];
    sa4(sa, 127, 0, 0, (unsigned)last, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    if (write(report, "R", 1) != 1) _exit(3);
    for (;;) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        char line[300];
        int ll = snprintf(line, sizeof line, "%d:%s;", last, name);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        int rcode = 0, answer = 0;
        if (last == 2) answer = 1;
        else if (starts(name, "silent")) continue;
        else if (starts(name, "sf-")) rcode = 2;
        else if (starts(name, "ref-")) rcode = 5;
        else if (starts(name, "fe-")) rcode = 1;
        else if (starts(name, "nd-")) rcode = 0;
        else rcode = 3;
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        r[3] = (unsigned char)(0x80 | rcode);
        r[6] = 0; r[7] = (unsigned char)answer;
        r[8] = r[9] = r[10] = r[11] = 0;
        if (answer) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 19, 2};
            memcpy(r + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
        sendto4(s, r, len, from);
    }
}
static int rep_fd = -1;
static char seen[300];
/* The servers' log since the last call: the pipe is non-blocking and is read until it stays empty for about 0.3 s. */
static void take_log(void) {
    size_t n = 0;
    for (int idle = 0; idle < 60 && n + 1 < sizeof seen;) {
        long k = (long)read(rep_fd, seen + n, 1);
        if (k <= 0) {
            idle++;
            usleep(5000);
            continue;
        }
        idle = 0;
        n++;
    }
    seen[n] = 0;
}
static long now_ms(void) {
    struct timespec t;
    clock_gettime(1 /* CLOCK_MONOTONIC */, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static unsigned last_octet(struct hostent *h) { return h && h->h_addr_list[0] ? (unsigned char)h->h_addr_list[0][3] : 0; }
int main(void) {
    print("hello519: /etc/resolv.conf timeout and attempts, reply codes\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pid1 = pr == 0 ? (long)fork() : -1;
    if (pid1 == 0) { close(p[0]); serve(1, p[1]); }
    long pid2 = pr == 0 ? (long)fork() : -1;
    if (pid2 == 0) { close(p[0]); serve(2, p[1]); }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready[2] = {0, 0};
    for (int i = 0; i < 2 && pid1 > 0 && pid2 > 0; i++)
        if (read(p[0], &ready[i], 1) != 1) ready[i] = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);

    int wa = write_conf("nameserver 127.0.0.1\noptions timeout:1 attempts:3\n");
    long t0 = now_ms();
    struct hostent *h = gethostbyname("silent-a.test");
    long ta = now_ms() - t0;
    int ha = h_errno;
    take_log();
    snprintf(msg, sizeof msg, "A: timeout:1 attempts:3, silent server: %s h_errno %d after %ld ms, asked '%s' (conf %d ready %c%c; NULL 2, 2700..4500 ms, 3 queries)",
             h ? "set" : "NULL", ha, ta, seen, wa, ready[0] ? ready[0] : '-', ready[1] ? ready[1] : '-');
    check(wa == 0 && ready[0] == 'R' && ready[1] == 'R' && !h && ha == TRY_AGAIN && ta >= 2700 && ta <= 4500 &&
              strcmp(seen, "1:silent-a.test;1:silent-a.test;1:silent-a.test;") == 0, msg);

    int wb = write_conf("nameserver 127.0.0.1\nnameserver 127.0.0.2\noptions timeout:1 attempts:1\n");
    t0 = now_ms();
    h = gethostbyname("silent-b.test");
    long tb = now_ms() - t0;
    unsigned ob = last_octet(h);
    take_log();
    snprintf(msg, sizeof msg, "B: a silent first server, the second answers: .%u after %ld ms, asked '%s' (conf %d; .2, 700..2500 ms, 1:silent-b.test;2:silent-b.test;)",
             ob, tb, seen, wb);
    check(wb == 0 && ob == 2 && tb >= 700 && tb <= 2500 && strcmp(seen, "1:silent-b.test;2:silent-b.test;") == 0, msg);

    t0 = now_ms();
    h = gethostbyname("sf-c.test");
    unsigned oc1 = last_octet(h);
    struct hostent *h2 = gethostbyname("ref-c.test");
    unsigned oc2 = last_octet(h2);
    long tc = now_ms() - t0;
    take_log();
    snprintf(msg, sizeof msg, "C: SERVFAIL .%u and REFUSED .%u go on to the second server at once (%ld ms), asked '%s' (.2 .2, < 700 ms)", oc1, oc2, tc, seen);
    check(oc1 == 2 && oc2 == 2 && tc < 700 && strcmp(seen, "1:sf-c.test;2:sf-c.test;1:ref-c.test;2:ref-c.test;") == 0, msg);

    h = gethostbyname("nx-d.test");
    int d1 = h ? -1 : h_errno;
    h = gethostbyname("nd-d.test");
    int d2 = h ? -1 : h_errno;
    h = gethostbyname("fe-d.test");
    int d3 = h ? -1 : h_errno;
    take_log();
    snprintf(msg, sizeof msg, "D: NXDOMAIN h_errno %d, NODATA %d, FORMERR %d, only the first server asked '%s' (1 4 3)", d1, d2, d3, seen);
    check(d1 == HOST_NOT_FOUND && d2 == NO_DATA && d3 == NO_RECOVERY && strcmp(seen, "1:nx-d.test;1:nd-d.test;1:fe-d.test;") == 0, msg);

    int we = write_conf("nameserver 127.0.0.1\noptions timeout:1 attempts:1\n");
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    int e1 = getaddrinfo("nd-e.test", 0, &hints, &res);
    if (e1 == 0) freeaddrinfo(res);
    int e2 = getaddrinfo("silent-e.test", 0, &hints, &res);
    if (e2 == 0) freeaddrinfo(res);
    int e3 = getaddrinfo("nx-e.test", 0, &hints, &res);
    if (e3 == 0) freeaddrinfo(res);
    take_log();
    snprintf(msg, sizeof msg, "E: getaddrinfo NODATA %d, no reply %d, NXDOMAIN %d (conf %d; %d %d %d)", e1, e2, e3, we, EAI_NODATA, EAI_AGAIN, EAI_NONAME);
    check(we == 0 && e1 == EAI_NODATA && e2 == EAI_AGAIN && e3 == EAI_NONAME, msg);

    int wf = write_conf("nameserver 127.0.0.1\nsearch ref-f.test b.test\noptions timeout:1 attempts:1\n");
    h = gethostbyname("x519");
    int f1 = h ? -1 : h_errno;
    take_log();
    snprintf(msg, sizeof msg, "F: search ref-f.test b.test, REFUSED for the first domain: h_errno %d, asked '%s' (conf %d; 1, 1:x519.ref-f.test;1:x519;)", f1, seen, wf);
    check(wf == 0 && f1 == HOST_NOT_FOUND && strcmp(seen, "1:x519.ref-f.test;1:x519;") == 0, msg);

    int st = -1;
    if (pid1 > 0) { kill(pid1, SIGKILL); waitpid(pid1, &st, 0); }
    (void)closefd;
    if (pid2 > 0) { kill(pid2, SIGKILL); waitpid(pid2, &st, 0); }
    if (pr == 0) close(p[0]);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "G: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello519: FAIL\n" : "hello519: PASS\n");
    return failures ? 1 : 0;
}
