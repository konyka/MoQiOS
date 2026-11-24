/* hello553: SO_PEEK_OFF on TCP sockets (Linux 7.x tcp_recvmsg, measured with -DHOST). The offset is -1 until set (a negative one
 * is kept as given); a peek starts at the offset and moves it past what it copied, and a read moves it back by what it took, not
 * below 0. A: default -1, -5 reads back -5; B: "abcdef" then "ghij": peeks of 2 and 3 give "ab" "cde" (offset 5), a read of 4
 * "abcd" (1), peeks "fgh" (4) and "ij" (6), then EAGAIN; C: -1 turns it off, 100 is EAGAIN and a read of 6 leaves 94; D: a blocking
 * peek at the end waits for more data; E: recvmsg with MSG_PEEK moves it the same way. Each case prints what it saw; the expected
 * value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
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
#define SOCK_STREAM 1
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define MSG_PEEK 0x2
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
static int listen(int s, int b) { return (int)ret(syscall2(50, s, b)); }
static int accept(int s, void *a, void *l) { return (int)ret(syscall3(43, s, (long)a, (long)l)); }
static int connect(int s, const void *a, socklen_t n) { return (int)ret(syscall3(42, s, (long)a, n)); }
static int setsockopt(int s, int l, int o, const void *v, socklen_t n) { return (int)ret(syscall5(54, s, l, o, (long)v, n)); }
static int getsockopt(int s, int l, int o, void *v, socklen_t *n) { return (int)ret(syscall5(55, s, l, o, (long)v, (long)n)); }
static long send(int s, const void *b, unsigned long n, int f) { return ret(syscall6(44, s, (long)b, (long)n, f, 0, 0)); }
static long recv(int s, void *b, unsigned long n, int f) { return ret(syscall6(45, s, (long)b, (long)n, f, 0, 0)); }
static long recvmsg(int s, struct msghdr *m, int f) { return ret(syscall3(47, s, (long)m, f)); }
#endif
#ifndef SO_PEEK_OFF
#define SO_PEEK_OFF 42
#endif
static int failures;
static char msg[800];
static void check(int ok, const char *w) {
    print(ok ? "hello553:   ok   " : "hello553:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int s, c;
static int off(void) {
    int v = -99;
    socklen_t l = sizeof v;
    if (getsockopt(s, SOL_SOCKET, SO_PEEK_OFF, &v, &l) != 0) return -100 - errno;
    return v;
}
static int so(int v) { return setsockopt(s, SOL_SOCKET, SO_PEEK_OFF, &v, sizeof v) == 0 ? 0 : -errno; }
static void rd(int peek, int n, char *out, size_t cap) {
    char b[64];
    memset(b, 0, sizeof b);
    long r = recv(s, b, (unsigned long)n, (peek ? MSG_PEEK : 0) | MSG_DONTWAIT);
    if (r < 0) r = -errno;
    size_t l = strlen(out);
    snprintf(out + l, cap - l, "%c%d:%ld'%.*s'/%d;", peek ? 'P' : 'R', n, r, r > 0 ? (int)r : 0, b, off());
}
static void settle(void) { usleep(50000); }
int main(void) {
    print("hello553: SO_PEEK_OFF on TCP sockets\n");
    int l = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    unsigned char sa[16] = {AF_INET, 0, 0x25, 0x69, 127, 0, 0, 1}; /* 127.0.0.1:9577 */
    int bl = bind(l, (void *)sa, 16), ls = listen(l, 1);
    c = socket(AF_INET, SOCK_STREAM, 0);
    int cn = connect(c, (void *)sa, 16);
    s = accept(l, 0, 0);
    int o0 = off(), m5 = so(-5), o5 = off();
    so(-1);
    snprintf(msg, sizeof msg, "A: default %d, set -5 %d -> %d (bind %d listen %d connect %d accept %d; -1 0 -5)", o0, m5, o5, bl, ls, cn, s >= 0);
    check(bl == 0 && ls == 0 && cn == 0 && s >= 0 && o0 == -1 && m5 == 0 && o5 == -5, msg);

    char got[400] = "", want[400];
    send(c, "abcdef", 6, 0);
    send(c, "ghij", 4, 0);
    settle();
    so(0);
    rd(1, 2, got, sizeof got);
    rd(1, 3, got, sizeof got);
    rd(0, 4, got, sizeof got);
    rd(1, 3, got, sizeof got);
    rd(1, 10, got, sizeof got);
    rd(1, 2, got, sizeof got);
    snprintf(want, sizeof want, "P2:2'ab'/2;P3:3'cde'/5;R4:4'abcd'/1;P3:3'fgh'/4;P10:2'ij'/6;P2:%d''/6;", -EAGAIN);
    snprintf(msg, sizeof msg, "B: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    got[0] = 0;
    so(-1);
    rd(1, 2, got, sizeof got);
    so(100);
    rd(1, 2, got, sizeof got);
    rd(0, 10, got, sizeof got);
    snprintf(want, sizeof want, "P2:2'ef'/-1;P2:%d''/100;R10:6'efghij'/94;", -EAGAIN);
    snprintf(msg, sizeof msg, "C: -1 and 100: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    send(c, "x", 1, 0);
    settle();
    so(1);
    long pid = (long)fork();
    if (pid == 0) {
        usleep(200000);
        send(c, "yz", 2, 0);
        _exit(0);
    }
    char b[8];
    memset(b, 0, sizeof b);
    long r = recv(s, b, sizeof b, MSG_PEEK);
    int st = -1;
    if (pid > 0) waitpid(pid, &st, 0);
    snprintf(msg, sizeof msg, "D: blocking peek at the end: %ld '%.*s' offset %d (2 yz 3)", r, r > 0 ? (int)r : 0, b, off());
    check(r == 2 && memcmp(b, "yz", 2) == 0 && off() == 3, msg);

    so(0);
    memset(b, 0, sizeof b);
    struct iovec iv = {b, 2};
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iv;
    m.msg_iovlen = 1;
    long r1 = recvmsg(s, &m, MSG_PEEK | MSG_DONTWAIT);
    int oa = off();
    char b2[8];
    memset(b2, 0, sizeof b2);
    iv.iov_base = b2;
    long r2 = recvmsg(s, &m, MSG_PEEK | MSG_DONTWAIT);
    int ob = off();
    snprintf(msg, sizeof msg, "E: recvmsg peeks %ld '%.2s' offset %d, %ld '%.1s' offset %d (2 xy 2, 1 z 3)", r1, b, oa, r2, b2, ob);
    check(r1 == 2 && memcmp(b, "xy", 2) == 0 && oa == 2 && r2 == 1 && b2[0] == 'z' && ob == 3, msg);

    close(c);
    close(s);
    close(l);
    print(failures ? "hello553: FAIL\n" : "hello553: PASS\n");
    return failures ? 1 : 0;
}
