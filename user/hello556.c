/* hello556: MSG_TRUNC on a TCP recvmsg (Linux 7.x tcp_recvmsg, measured with -DHOST): the iovecs' room is taken (or peeked) and
 * counted, nothing is copied. A: "abcdefgh" queued, recvmsg into a 3-byte iovec with MSG_TRUNC returns 3, the iovec untouched, no
 * MSG_TRUNC in msg_flags; B: no iovec at all returns 0; C: MSG_PEEK | MSG_TRUNC with a NULL 2-byte iovec returns 2; D: a plain
 * recvmsg then gets "defgh". Each case prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
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
struct msghdr { void *msg_name; socklen_t msg_namelen; struct iovec *msg_iov; unsigned long msg_iovlen; void *msg_control; unsigned long msg_controllen; int msg_flags; };
static long recvmsg(int s, struct msghdr *m, int f) { return ret(syscall3(47, s, (long)m, f)); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello556:   ok   " : "hello556:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rv(long r) { return r < 0 ? -errno : r; }
int main(void) {
    print("hello556: MSG_TRUNC on a TCP recvmsg\n");
    int l = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    unsigned char sa[16] = {AF_INET, 0, 0x25, 0x6c, 127, 0, 0, 1}; /* 127.0.0.1:9580 */
    int bl = bind(l, (void *)sa, 16), ls = listen(l, 1);
    int c = socket(AF_INET, SOCK_STREAM, 0);
    int cn = connect(c, (void *)sa, 16);
    int s = accept(l, 0, 0);
    send(c, "abcdefgh", 8, 0);
    usleep(50000);
    char b[8];
    memset(b, 'X', sizeof b);
    struct iovec iv = {b, 3};
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iv;
    m.msg_iovlen = 1;
    long a = rv(recvmsg(s, &m, MSG_TRUNC | MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "A: 3-byte iovec %ld, iovec '%.3s', msg_flags %#x (bind %d listen %d connect %d accept %d; 3 XXX 0)", a, b, m.msg_flags, bl, ls, cn,
             s >= 0);
    check(bl == 0 && ls == 0 && cn == 0 && s >= 0 && a == 3 && memcmp(b, "XXX", 3) == 0 && m.msg_flags == 0, msg);
    struct msghdr m0;
    memset(&m0, 0, sizeof m0);
    long bb = rv(recvmsg(s, &m0, MSG_TRUNC | MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "B: no iovec %ld (0)", bb);
    check(bb == 0, msg);
    iv.iov_base = (void *)0;
    iv.iov_len = 2;
    long cc = rv(recvmsg(s, &m, MSG_TRUNC | MSG_PEEK | MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "C: MSG_PEEK | MSG_TRUNC, NULL 2-byte iovec %ld (2)", cc);
    check(cc == 2, msg);
    memset(b, 0, sizeof b);
    iv.iov_base = b;
    iv.iov_len = sizeof b;
    long d = rv(recvmsg(s, &m, MSG_DONTWAIT));
    snprintf(msg, sizeof msg, "D: then recvmsg %ld '%.*s' (5 defgh)", d, d > 0 ? (int)d : 0, b);
    check(d == 5 && memcmp(b, "defgh", 5) == 0, msg);
    close(c);
    close(s);
    close(l);
    print(failures ? "hello556: FAIL\n" : "hello556: PASS\n");
    return failures ? 1 : 0;
}
