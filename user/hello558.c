/* hello558: sending with an address on an unconnected AF_UNIX connection-oriented socket (Linux 7.x, measured with -DHOST):
 * SOCK_SEQPACKET is ENOTCONN for sendto, send and sendmsg with msg_name (unix_seqpacket_sendmsg checks the connection first);
 * SOCK_STREAM is EOPNOTSUPP for sendto with an address and ENOTCONN for send without one. A: seqpacket sendto; B: seqpacket send;
 * C: seqpacket sendmsg with msg_name; D: stream sendto with an address; E: stream send. Each case prints what it saw; the expected
 * value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define MSG_NOSIG MSG_NOSIGNAL
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
typedef unsigned socklen_t;
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_SEQPACKET 5
#define MSG_NOSIG 0x4000
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
static long sendto(int s, const void *b, unsigned long n, int f, const void *a, socklen_t al) { return ret(syscall6(44, s, (long)b, (long)n, f, (long)a, al)); }
static long send(int s, const void *b, unsigned long n, int f) { return ret(syscall6(44, s, (long)b, (long)n, f, 0, 0)); }
static long sendmsg(int s, const struct msghdr *m, int f) { return ret(syscall3(46, s, (long)m, f)); }
#endif
static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello558:   ok   " : "hello558:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rv(long r) { return r < 0 ? -errno : r; }
int main(void) {
    print("hello558: an address on an unconnected AF_UNIX stream or seqpacket socket\n");
    unsigned char a[16] = {AF_UNIX, 0, 0, 'h', '5', '5', '8'}; /* abstract "\0h558" */
    int l = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    int b = bind(l, (void *)a, 7);
    int s = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    long ra = rv(sendto(s, "x", 1, MSG_NOSIG, (void *)a, 7));
    snprintf(msg, sizeof msg, "A: seqpacket sendto with an address %ld (bind %d; %d)", ra, b, -ENOTCONN);
    check(b == 0 && ra == -ENOTCONN, msg);
    long rb = rv(send(s, "x", 1, MSG_NOSIG));
    snprintf(msg, sizeof msg, "B: seqpacket send %ld (%d)", rb, -ENOTCONN);
    check(rb == -ENOTCONN, msg);
    struct iovec iv = {(void *)"x", 1};
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iv;
    m.msg_iovlen = 1;
    m.msg_name = a;
    m.msg_namelen = 7;
    long rc = rv(sendmsg(s, &m, MSG_NOSIG));
    snprintf(msg, sizeof msg, "C: seqpacket sendmsg with msg_name %ld (%d)", rc, -ENOTCONN);
    check(rc == -ENOTCONN, msg);
    int t = socket(AF_UNIX, SOCK_STREAM, 0);
    long rd = rv(sendto(t, "x", 1, MSG_NOSIG, (void *)a, 7));
    snprintf(msg, sizeof msg, "D: stream sendto with an address %ld (%d)", rd, -EOPNOTSUPP);
    check(rd == -EOPNOTSUPP, msg);
    long re = rv(send(t, "x", 1, MSG_NOSIG));
    snprintf(msg, sizeof msg, "E: stream send %ld (%d)", re, -ENOTCONN);
    check(re == -ENOTCONN, msg);
    close(l);
    close(s);
    close(t);
    print(failures ? "hello558: FAIL\n" : "hello558: PASS\n");
    return failures ? 1 : 0;
}
