/* hello555: MSG_TRUNC on a TCP recv (Linux 7.x tcp_recvmsg, measured with -DHOST): the bytes are taken and counted but not copied,
 * so a NULL buffer is fine. A: "abcdefgh" queued, recv(buf, 3, MSG_TRUNC) returns 3 and leaves the buffer untouched; B:
 * recv(NULL, 3, MSG_TRUNC) returns 3; C: MSG_PEEK | MSG_TRUNC returns 2 and takes nothing; D: a plain read then gets "gh"; E:
 * MSG_TRUNC on an empty queue is EAGAIN. Each case prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
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
#define MSG_TRUNC 0x20
#define MSG_DONTWAIT 0x40
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
static long send(int s, const void *b, unsigned long n, int f) { return ret(syscall6(44, s, (long)b, (long)n, f, 0, 0)); }
static long recv(int s, void *b, unsigned long n, int f) { return ret(syscall6(45, s, (long)b, (long)n, f, 0, 0)); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello555:   ok   " : "hello555:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rv(long r) { return r < 0 ? -errno : r; }
int main(void) {
    print("hello555: MSG_TRUNC on a TCP recv\n");
    int l = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    unsigned char sa[16] = {AF_INET, 0, 0x25, 0x6b, 127, 0, 0, 1}; /* 127.0.0.1:9579 */
    int bl = bind(l, (void *)sa, 16), ls = listen(l, 1);
    int c = socket(AF_INET, SOCK_STREAM, 0);
    int cn = connect(c, (void *)sa, 16);
    int s = accept(l, 0, 0);
    send(c, "abcdefgh", 8, 0);
    usleep(50000);
    char b[8];
    memset(b, 'X', sizeof b);
    long a = rv(recv(s, b, 3, MSG_TRUNC | MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "A: recv(buf, 3, MSG_TRUNC) %ld, buffer '%.3s' (bind %d listen %d connect %d accept %d; 3 XXX)", a, b, bl, ls, cn, s >= 0);
    check(bl == 0 && ls == 0 && cn == 0 && s >= 0 && a == 3 && memcmp(b, "XXX", 3) == 0, msg);
    long bb = rv(recv(s, (void *)0, 3, MSG_TRUNC | MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "B: recv(NULL, 3, MSG_TRUNC) %ld (3)", bb);
    check(bb == 3, msg);
    memset(b, 'X', sizeof b);
    long cc = rv(recv(s, b, 2, MSG_PEEK | MSG_TRUNC | MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "C: MSG_PEEK | MSG_TRUNC %ld, buffer '%.2s' (2 XX)", cc, b);
    check(cc == 2 && memcmp(b, "XX", 2) == 0, msg);
    memset(b, 0, sizeof b);
    long d = rv(recv(s, b, sizeof b, MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "D: then a read %ld '%.*s' (2 gh)", d, d > 0 ? (int)d : 0, b);
    check(d == 2 && memcmp(b, "gh", 2) == 0, msg);
    long e = rv(recv(s, b, 3, MSG_TRUNC | MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "E: MSG_TRUNC on an empty queue %ld (%d)", e, -EAGAIN);
    check(e == -EAGAIN, msg);
    close(c);
    close(s);
    close(l);
    print(failures ? "hello555: FAIL\n" : "hello555: PASS\n");
    return failures ? 1 : 0;
}
