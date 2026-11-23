/* hello514: /etc/resolv.conf nameservers (glibc semantics, measured). A creates /etc/resolv.conf naming 127.0.0.1 and starts a
 * one-shot DNS server on 127.0.0.1:53 in a child; B gethostbyname of an unknown name is answered by that server (10.5.14.1), so the
 * query went to the resolv.conf server and not to the kernel's DHCP server; C the server saw an A query for the name, from the kernel
 * resolver; D dns_resolve_via (506) refuses 0.0.0.0, broadcast and multicast servers with EINVAL and a NULL server with EFAULT; E a
 * name the server does not know (it answers NXDOMAIN) is HOST_NOT_FOUND; F with resolv.conf naming a server that does not answer
 * first, the second server is used; G cleanup. Needs root (port 53 and /etc). Measured with -DHOST through glibc in `unshare -m -n`
 * (resolv.conf bind-mounted, lo up), except D, which is MoQiOS's own system call. */
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
#define CONF_PATH (getenv("R514") ? getenv("R514") : "/etc/resolv.conf")
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
static char msg[800];
static void check(int ok, const char *w) {
    print(ok ? "hello514:   ok   " : "hello514:   FAIL ");
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
/* One DNS server on 127.0.0.1:53 for `rounds` queries: "known514.test" gets 10.5.14.1 (A), anything else NXDOMAIN. It reports the
 * last question name and type through the pipe `report`. */
static void serve(int rounds, int report) {
    long s = sock_udp();
    unsigned char sa[16], from[16], q[512], r[512];
    sa4(sa, 127, 0, 0, 1, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    if (write(report, "R", 1) != 1) _exit(3); /* ready */
    for (int k = 0; k < rounds; k++) {
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char name[256];
        int qtype = 0;
        if (qname(q, n, name, sizeof name, &qtype) != 0) continue;
        char line[300];
        int ll = snprintf(line, sizeof line, "%s/%d;", name, qtype);
        if (write(report, line, (size_t)ll) != ll) _exit(4);
        memcpy(r, q, (size_t)n);
        long len = n;
        r[2] = 0x81;
        int known = strcmp(name, "known514.test") == 0 && qtype == 1;
        r[3] = known ? 0x80 : 0x83; /* RA, NOERROR or NXDOMAIN */
        r[6] = 0; r[7] = known ? 1 : 0; /* ancount */
        r[8] = r[9] = r[10] = r[11] = 0;
        if (known) {
            static const unsigned char ans[] = {0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 5, 14, 1};
            memcpy(r + len, ans, sizeof ans);
            len += (long)sizeof ans;
        }
        sendto4(s, r, len, from);
    }
    closefd(s);
    _exit(0);
}
int main(void) {
    print("hello514: /etc/resolv.conf nameservers\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello514:   .. "); print(msg); print("\n");
#endif
    int wc = write_conf("# test\nnameserver 127.0.0.1\n");
    int p[2];
    int pr = pipe(p);
    long pid = pr == 0 ? (long)fork() : -1;
    if (pid == 0) { close(p[0]); serve(2, p[1]); }
    if (pr == 0) close(p[1]);
    char ready = 0;
    long rr = pid > 0 ? (long)read(p[0], &ready, 1) : -1;
    snprintf(msg, sizeof msg, "A: resolv.conf %d, server pid %d ready %ld '%c' (0 >0 1 R)", wc, (int)pid, rr, ready ? ready : '-');
    check(wc == 0 && pid > 0 && rr == 1 && ready == 'R', msg);

    struct hostent *h = gethostbyname("known514.test");
    unsigned char got[4] = {0};
    if (h && h->h_addr_list[0]) memcpy(got, h->h_addr_list[0], 4);
    snprintf(msg, sizeof msg, "B: gethostbyname(known514.test) %s %u.%u.%u.%u h_errno %d (10.5.14.1)", h ? "ok" : "NULL", got[0], got[1], got[2],
             got[3], h ? 0 : h_errno);
    check(h && got[0] == 10 && got[1] == 5 && got[2] == 14 && got[3] == 1, msg);

    h = gethostbyname("missing514.test");
    int e_herr = h_errno;
    snprintf(msg, sizeof msg, "E: gethostbyname(missing514.test) %s h_errno %d (NULL 1)", h ? "set" : "NULL", e_herr);
    check(!h && e_herr == HOST_NOT_FOUND, msg);

    char rep[600];
    long rn = 0, k;
    while (rn < (long)sizeof rep - 1 && (k = (long)read(p[0], rep + rn, sizeof rep - 1 - (size_t)rn)) > 0) rn += k;
    rep[rn > 0 ? rn : 0] = 0;
    int st = -1;
    if (pid > 0) waitpid(pid, &st, 0);
    if (pr == 0) close(p[0]);
    snprintf(msg, sizeof msg, "C: the server saw '%s', exit %d (known514.test/1;missing514.test/1; 0)", rep, st);
    check(strcmp(rep, "known514.test/1;missing514.test/1;") == 0 && st == 0, msg);

#ifdef HOST
    print("hello514:   .. D skipped on the host: dns_resolve_via is MoQiOS's own system call\n");
    check(1, "D: (target only)");
#else
    unsigned char out[4];
    static const unsigned char zero[4] = {0, 0, 0, 0}, bcast[4] = {255, 255, 255, 255}, mcast[4] = {224, 0, 0, 251};
    long d1 = syscall3(SYS_dns_resolve_via, (long)"x.test", (long)out, (long)zero);
    long d2 = syscall3(SYS_dns_resolve_via, (long)"x.test", (long)out, (long)bcast);
    long d3 = syscall3(SYS_dns_resolve_via, (long)"x.test", (long)out, (long)mcast);
    long d4 = syscall3(SYS_dns_resolve_via, (long)"x.test", (long)out, 0);
    long d5 = syscall3(SYS_dns_resolve_via, (long)"localhost", (long)out, (long)mcast);
    snprintf(msg, sizeof msg, "D: dns_resolve_via servers 0.0.0.0 %ld, broadcast %ld, multicast %ld, NULL %ld; localhost via multicast %ld (-22 -22 -22 -14 -22)",
             d1, d2, d3, d4, d5);
    check(d1 == -22 && d2 == -22 && d3 == -22 && d4 == -14 && d5 == -22, msg);
#endif

    /* F: a first server that nobody answers on, then the real one. 127.0.0.2 is on loopback but has no listener, so the query
     * gets no reply (MoQiOS) or a port unreachable (Linux); either way the resolver moves on to 127.0.0.1. */
    int wc2 = write_conf("nameserver 127.0.0.2\nnameserver 127.0.0.1\n");
    int p2[2];
    int pr2 = pipe(p2);
    long pid2 = pr2 == 0 ? (long)fork() : -1;
    if (pid2 == 0) { close(p2[0]); serve(1, p2[1]); }
    if (pr2 == 0) close(p2[1]);
    char ready2 = 0;
    if (pid2 > 0 && read(p2[0], &ready2, 1) != 1) ready2 = 0;
    h = gethostbyname("known514.test");
    memset(got, 0, sizeof got);
    if (h && h->h_addr_list[0]) memcpy(got, h->h_addr_list[0], 4);
    int st2 = -1;
    if (pid2 > 0) {
        kill(pid2, SIGKILL);
        waitpid(pid2, &st2, 0);
    }
    if (pr2 == 0) close(p2[0]);
    snprintf(msg, sizeof msg, "F: conf %d ready '%c', second server answers %s %u.%u.%u.%u (0 R ok 10.5.14.1)", wc2, ready2 ? ready2 : '-', h ? "ok" : "NULL",
             got[0], got[1], got[2], got[3]);
    check(wc2 == 0 && ready2 == 'R' && h && got[0] == 10 && got[3] == 1, msg);

#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(CONF_PATH);
#endif
    snprintf(msg, sizeof msg, "G: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello514: FAIL\n" : "hello514: PASS\n");
    return failures ? 1 : 0;
}
