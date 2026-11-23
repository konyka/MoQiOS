/* hello522: /etc/resolv.conf "options rotate" (glibc 2.44 res_send, measured). Stand-in DNS servers on 127.0.0.1, .2 and .3 (port 53)
 * answer every A query with 10.5.22.<their own last octet> and log who was asked. A: without rotate, six lookups all go to the first
 * server; B: with rotate, six lookups go round the three servers in file order, starting wherever the process's counter starts
 * (glibc starts a process at a random server); C: with rotate and the first-asked server silent, a lookup still goes on to the
 * next one in order and is answered there. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -m -n`
 * (resolv.conf and nsswitch.conf "hosts: files dns" bind-mounted, lo with 127.0.0.2 and .3). */
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
#define CONF_PATH (getenv("R522") ? getenv("R522") : "/etc/resolv.conf")
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
    print(ok ? "hello522:   ok   " : "hello522:   FAIL ");
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

/* The server on 127.0.0.<last>: answers A queries for anything with 10.5.22.<last>, except "quiet-*" names at server `quiet`,
 * which it ignores. Logs "<last>;" for each question. */
static void serve(int last, int quiet, int report) {
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
        char line[8];
        int ll = snprintf(line, sizeof line, "%d;", last);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        if (last == quiet && strncmp(name, "quiet", 5) == 0) continue;
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        r[3] = 0x80;
        r[6] = 0; r[7] = qtype == 1 ? 1 : 0;
        r[8] = r[9] = r[10] = r[11] = 0;
        if (qtype == 1) {
            unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 22, (unsigned char)last};
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
static unsigned lookup(const char *name) {
    struct hostent *h = gethostbyname(name);
    return h && h->h_addr_list[0] ? (unsigned char)h->h_addr_list[0][3] : 0;
}
int main(void) {
    print("hello522: /etc/resolv.conf options rotate\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pids[3] = {-1, -1, -1};
    for (int i = 0; i < 3 && pr == 0; i++) {
        pids[i] = (long)fork();
        if (pids[i] == 0) { close(p[0]); serve(i + 1, 0, p[1]); }
    }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready[3] = {0, 0, 0};
    for (int i = 0; i < 3 && pr == 0; i++)
        if (read(p[0], &ready[i], 1) != 1) ready[i] = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);

    int wa = write_conf("nameserver 127.0.0.1\nnameserver 127.0.0.2\nnameserver 127.0.0.3\noptions timeout:1 attempts:1\n");
    unsigned a[6];
    for (int i = 0; i < 6; i++) a[i] = lookup(i % 2 ? "x522.test" : "y522.test");
    take_log();
    snprintf(msg, sizeof msg, "A: no rotate: answers %u %u %u %u %u %u, asked '%s' (conf %d ready %c%c%c; all from server 1)", a[0], a[1], a[2], a[3], a[4], a[5],
             seen, wa, ready[0] ? ready[0] : '-', ready[1] ? ready[1] : '-', ready[2] ? ready[2] : '-');
    int all1 = 1;
    for (int i = 0; i < 6; i++) all1 &= a[i] == 1;
    check(wa == 0 && ready[0] == 'R' && ready[1] == 'R' && ready[2] == 'R' && all1 && strcmp(seen, "1;1;1;1;1;1;") == 0, msg);

    int wb = write_conf("nameserver 127.0.0.1\nnameserver 127.0.0.2\nnameserver 127.0.0.3\noptions rotate timeout:1 attempts:1\n");
    unsigned b[6];
    for (int i = 0; i < 6; i++) b[i] = lookup(i % 2 ? "x522.test" : "y522.test");
    take_log();
    int round = b[0] >= 1 && b[0] <= 3;
    for (int i = 1; i < 6; i++) round &= b[i] == b[i - 1] % 3 + 1;
    snprintf(msg, sizeof msg, "B: rotate: answers %u %u %u %u %u %u, asked '%s' (conf %d; each the next server in order)", b[0], b[1], b[2], b[3], b[4], b[5], seen, wb);
    check(wb == 0 && round, msg);

    /* C: server 1 is restarted so that it ignores "quiet" names; a rotated lookup that lands on it moves on to server 2. Three
     * lookups in a row cover every starting point, so one of them starts at server 1. */
    if (pids[0] > 0) { kill(pids[0], SIGKILL); waitpid(pids[0], 0, 0); }
    int p2[2];
    int pr2 = pipe(p2);
    pids[0] = pr2 == 0 ? (long)fork() : -1;
    if (pids[0] == 0) { close(p2[0]); serve(1, 1, p2[1]); }
    if (pr2 == 0) close(p2[1]);
    char r1 = 0;
    if (pids[0] > 0 && read(p2[0], &r1, 1) != 1) r1 = 0;
    unsigned c[3];
    for (int i = 0; i < 3; i++) c[i] = lookup("quiet522.test");
    take_log();
    int saw_skip = 0, all_answered = 1;
    for (int i = 0; i < 3; i++) all_answered &= c[i] == 2 || c[i] == 3;
    for (int i = 0; i < 3; i++) saw_skip |= c[i] == 2;
    snprintf(msg, sizeof msg, "C: rotate with a silent server 1: answers %u %u %u (ready %c; 2 or 3 each, 2 at least once)", c[0], c[1], c[2], r1 ? r1 : '-');
    check(r1 == 'R' && all_answered && saw_skip, msg);

    for (int i = 0; i < 3; i++) if (pids[i] > 0) { kill(pids[i], SIGKILL); waitpid(pids[i], 0, 0); }
    if (pr == 0) close(p[0]);
    if (pr2 == 0) close(p2[0]);
    (void)closefd;

#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "D: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello522: FAIL\n" : "hello522: PASS\n");
    return failures ? 1 : 0;
}
