/* hello541: "options no-tld-query" in /etc/resolv.conf: a name with no dot is not asked as given after the search list, and a "."
 * on the search list asks the name as given in its place (glibc 2.44 res_search, measured). A stand-in server on 127.0.0.1:53
 * answers every query NXDOMAIN and logs "<name>/<type>;" for each. Needs root (port 53 and /etc). Measured with -DHOST through
 * glibc in `unshare -r -m -n` (lo up, a tmpfs on /etc). Each case prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
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
#endif
static int failures;
static char msg[800];
static void check(int ok, const char *w) {
    print(ok ? "hello541:   ok   " : "hello541:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void sa4(unsigned char sa[16], unsigned d, unsigned port) {
    memset(sa, 0, 16);
    sa[0] = 2;
    sa[2] = (unsigned char)(port >> 8);
    sa[3] = (unsigned char)port;
    sa[4] = 127; sa[7] = (unsigned char)d;
}
static int write_file(const char *path, const char *text) {
    int fd = (int)open(path, 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
static void note(int report, const char *s) {
    if (write(report, s, strlen(s)) != (long)strlen(s)) _exit(4);
}
/* Answer every query NXDOMAIN; log "<name>/<type>;". */
static void serve_udp(int report) {
    long s = sock_udp();
    unsigned char sa[16];
    sa4(sa, 1, 53);
    if (s < 0 || bind4(s, sa) != 0) _exit(2);
    note(report, "R");
    for (;;) {
        unsigned char q[600], from[16];
        long n = recvfrom4(s, q, sizeof q, from);
        if (n < 12) continue;
        char line[320];
        size_t k = 0;
        long i = 12;
        while (i < n && q[i] && k + q[i] + 2 < 280) {
            if (k) line[k++] = '.';
            memcpy(line + k, q + i + 1, q[i]);
            k += q[i];
            i += q[i] + 1;
        }
        if (i + 5 > n) continue;
        snprintf(line + k, sizeof line - k, "/%d;", q[i + 1] << 8 | q[i + 2]);
        note(report, line);
        q[2] = 0x81;
        q[3] = 0x83;
        q[6] = q[7] = q[8] = q[9] = q[10] = q[11] = 0;
        sendto4(s, q, i + 5, from);
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
/* 0 if gethostbyname found `name`, else h_errno. */
static int lookup(const char *name) {
    return gethostbyname(name) ? 0 : h_errno;
}
static const char *conf(const char *search, const char *opts) {
    static char buf[200];
    snprintf(buf, sizeof buf, "nameserver 127.0.0.1\nsearch %s\noptions timeout:1 attempts:1%s\n", search, opts);
    return buf;
}
int main(void) {
    print("hello541: options no-tld-query and a \".\" search domain\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int p[2];
    int pr = pipe(p);
    long pid = -1;
    if (pr == 0 && (pid = (long)fork()) == 0) { close(p[0]); serve_udp(p[1]); }
    if (pr == 0) close(p[1]);
    rep_fd = p[0];
    char ready = 0;
    if (pr == 0 && read(p[0], &ready, 1) != 1) ready = 0;
    fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
    int wn = write_file("/etc/nsswitch.conf", "hosts: dns\n");

    int w = write_file("/etc/resolv.conf", conf("s.test t.test", ""));
    int a = lookup("foo");
    take_log();
    snprintf(msg, sizeof msg, "A: without no-tld-query: %d, asked '%s' (ready %c conf %d %d; 1, foo.s.test/1;foo.t.test/1;foo/1;)", a, seen,
             ready ? ready : '-', wn, w);
    check(ready == 'R' && wn == 0 && w == 0 && a == HOST_NOT_FOUND && strcmp(seen, "foo.s.test/1;foo.t.test/1;foo/1;") == 0, msg);

    w = write_file("/etc/resolv.conf", conf("s.test t.test", " no-tld-query"));
    int b = lookup("foo");
    take_log();
    snprintf(msg, sizeof msg, "B: no-tld-query: %d, asked '%s' (conf %d; 1, foo.s.test/1;foo.t.test/1;)", b, seen, w);
    check(w == 0 && b == HOST_NOT_FOUND && strcmp(seen, "foo.s.test/1;foo.t.test/1;") == 0, msg);

    w = write_file("/etc/resolv.conf", conf("s.test", " no-tld-query"));
    int c = lookup("foo.bar");
    take_log();
    snprintf(msg, sizeof msg, "C: no-tld-query, a dotted name: %d, asked '%s' (conf %d; 1, foo.bar/1;foo.bar.s.test/1;)", c, seen, w);
    check(w == 0 && c == HOST_NOT_FOUND && strcmp(seen, "foo.bar/1;foo.bar.s.test/1;") == 0, msg);

    w = write_file("/etc/resolv.conf", conf("s.test", " no-tld-queryx"));
    int d1 = lookup("foo");
    take_log();
    char seen_d1[300];
    snprintf(seen_d1, sizeof seen_d1, "%s", seen);
    w |= write_file("/etc/resolv.conf", conf("s.test", " no-tld-quer"));
    int d2 = lookup("foo");
    take_log();
    snprintf(msg, sizeof msg, "D: 'no-tld-queryx' %d '%s', 'no-tld-quer' %d '%s' (conf %d; foo.s.test/1; and foo.s.test/1;foo/1;)", d1, seen_d1, d2,
             seen, w);
    check(w == 0 && d1 == HOST_NOT_FOUND && strcmp(seen_d1, "foo.s.test/1;") == 0 && d2 == HOST_NOT_FOUND && strcmp(seen, "foo.s.test/1;foo/1;") == 0,
          msg);

    w = write_file("/etc/resolv.conf", conf("s.test . t.test", ""));
    int e = lookup("foo");
    take_log();
    snprintf(msg, sizeof msg, "E: search s.test . t.test: %d, asked '%s' (conf %d; 1, foo.s.test/1;foo/1;foo.t.test/1;)", e, seen, w);
    check(w == 0 && e == HOST_NOT_FOUND && strcmp(seen, "foo.s.test/1;foo/1;foo.t.test/1;") == 0, msg);

    w = write_file("/etc/resolv.conf", conf("s.test", " no-tld-query"));
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int g = getaddrinfo("foo", 0, &hints, &res);
    if (g == 0) freeaddrinfo(res);
    take_log();
    snprintf(msg, sizeof msg, "F: getaddrinfo(foo, AF_INET) with no-tld-query: %d, asked '%s' (conf %d; %d, foo.s.test/1;)", g, seen, w, EAI_NONAME);
    check(w == 0 && g == EAI_NONAME && strcmp(seen, "foo.s.test/1;") == 0, msg);

    if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, 0, 0); }
    if (pr == 0) close(p[0]);
    long u1 = unlink("/etc/resolv.conf"), u2 = unlink("/etc/nsswitch.conf");
    snprintf(msg, sizeof msg, "G: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello541: FAIL\n" : "hello541: PASS\n");
    return failures ? 1 : 0;
}
