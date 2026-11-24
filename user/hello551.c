/* hello551: zero-length UDP datagrams (Linux 7.x, measured with -DHOST): sendto, send on a connected socket and sendmsg with no
 * bytes each send an empty datagram and return 0, and recv/recvfrom/recvmsg return it as a 0-byte message with the sender's
 * address. A: sendto("", 0) returns 0 and the receiver gets a 0-byte datagram from the sender's port; B: sendto(NULL, 0) does
 * the same; C: sendmsg with no iovecs does the same; D: send() on a connected socket does the same; E: an empty datagram queued
 * before a 2-byte one comes out first; F: IPv6 the same as A. Each case prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
typedef unsigned socklen_t;
#define AF_INET 2
#define AF_INET6 10
#define SOCK_DGRAM 2
#define MSG_DONTWAIT 0x40
struct msghdr { void *msg_name; socklen_t msg_namelen; struct iovec *msg_iov; unsigned long msg_iovlen; void *msg_control; unsigned long msg_controllen; int msg_flags; };
static long ret(long r) {
    if (r < 0) {
        errno = (int)-r;
        return -1;
    }
    return r;
}
static int socket(int d, int t, int p) { return (int)ret(syscall3(41, d, t, p)); }
static int bind(int s, const void *a, socklen_t n) { return (int)ret(syscall3(49, s, (long)a, n)); }
static int connect(int s, const void *a, socklen_t n) { return (int)ret(syscall3(42, s, (long)a, n)); }
static long sendto(int s, const void *b, unsigned long n, int f, const void *a, socklen_t al) { return ret(syscall6(44, s, (long)b, (long)n, f, (long)a, al)); }
static long send(int s, const void *b, unsigned long n, int f) { return ret(syscall6(44, s, (long)b, (long)n, f, 0, 0)); }
static long sendmsg(int s, const struct msghdr *m, int f) { return ret(syscall3(46, s, (long)m, f)); }
static long recvfrom(int s, void *b, unsigned long n, int f, void *a, socklen_t *al) { return ret(syscall6(45, s, (long)b, (long)n, f, (long)a, (long)al)); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello551:   ok   " : "hello551:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int u, w;
static unsigned char to[28], me[28];
static unsigned to_len;
static int setup(int six, unsigned port) {
    u = socket(six ? AF_INET6 : AF_INET, SOCK_DGRAM, 0);
    w = socket(six ? AF_INET6 : AF_INET, SOCK_DGRAM, 0);
    memset(to, 0, sizeof to);
    to[0] = (unsigned char)(six ? AF_INET6 : AF_INET);
    to[2] = (unsigned char)(port >> 8);
    to[3] = (unsigned char)port;
    if (six) {
        to_len = 28;
        to[23] = 1;
    } else {
        to_len = 16;
        to[4] = 127;
        to[7] = 1;
    }
    memcpy(me, to, sizeof me);
    me[2] = (unsigned char)((port + 1) >> 8);
    me[3] = (unsigned char)(port + 1);
    return u >= 0 && w >= 0 && bind(u, (void *)to, to_len) == 0 && bind(w, (void *)me, to_len) == 0 ? 0 : -1;
}
/* One recvfrom: "<result>/<sender port>" appended to `out`, or "<-errno>". */
static void take(char *out, size_t cap) {
    char b[16];
    unsigned char from[28];
    socklen_t fl = sizeof from;
    memset(from, 0, sizeof from);
    usleep(30000);
    long r = recvfrom(u, b, sizeof b, MSG_DONTWAIT, (void *)from, &fl);
    size_t l = strlen(out);
    if (r < 0) snprintf(out + l, cap - l, "%d;", -errno);
    else snprintf(out + l, cap - l, "%ld/%u;", r, (unsigned)(from[2] << 8 | from[3]));
}
int main(void) {
    print("hello551: zero-length UDP datagrams\n");
    char got[200], want[200];
    int sr = setup(0, 9570);
    got[0] = 0;
    long a = sendto(w, "", 0, 0, (void *)to, to_len);
    take(got, sizeof got);
    snprintf(msg, sizeof msg, "A: sendto(\"\", 0) %ld, received '%s' (setup %d; 0, 0/9571;)", a, got, sr);
    check(sr == 0 && a == 0 && strcmp(got, "0/9571;") == 0, msg);

    got[0] = 0;
    long b = sendto(w, (void *)0, 0, 0, (void *)to, to_len);
    take(got, sizeof got);
    snprintf(msg, sizeof msg, "B: sendto(NULL, 0) %ld, received '%s' (0, 0/9571;)", b, got);
    check(b == 0 && strcmp(got, "0/9571;") == 0, msg);

    got[0] = 0;
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_name = to;
    m.msg_namelen = to_len;
    long c = sendmsg(w, &m, 0);
    take(got, sizeof got);
    snprintf(msg, sizeof msg, "C: sendmsg with no iovecs %ld, received '%s' (0, 0/9571;)", c, got);
    check(c == 0 && strcmp(got, "0/9571;") == 0, msg);

    got[0] = 0;
    int cn = connect(w, (void *)to, to_len);
    long d = send(w, "", 0, 0);
    take(got, sizeof got);
    snprintf(msg, sizeof msg, "D: connect %d, send(\"\", 0) %ld, received '%s' (0 0, 0/9571;)", cn, d, got);
    check(cn == 0 && d == 0 && strcmp(got, "0/9571;") == 0, msg);

    got[0] = 0;
    send(w, "", 0, 0);
    send(w, "xy", 2, 0);
    take(got, sizeof got);
    take(got, sizeof got);
    take(got, sizeof got);
    snprintf(want, sizeof want, "0/9571;2/9571;%d;", -EAGAIN);
    snprintf(msg, sizeof msg, "E: empty then 2 bytes: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);
    close(u);
    close(w);

    got[0] = 0;
    sr = setup(1, 9572);
    long f = sendto(w, "", 0, 0, (void *)to, to_len);
    take(got, sizeof got);
    snprintf(msg, sizeof msg, "F: IPv6 sendto(\"\", 0) %ld, received '%s' (setup %d; 0, 0/9573;)", f, got, sr);
    check(sr == 0 && f == 0 && strcmp(got, "0/9573;") == 0, msg);
    close(u);
    close(w);

    print(failures ? "hello551: FAIL\n" : "hello551: PASS\n");
    return failures ? 1 : 0;
}
