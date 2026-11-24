/* hello552: write() and AF_UNIX sends of zero bytes (Linux 7.x, measured with -DHOST). A: write(fd, "", 0) on a connected UDP
 * socket returns 0 and the peer receives an empty datagram; B: write(fd, NULL, 0) the same; C: write of 0 bytes on an unconnected
 * UDP socket is EDESTADDRREQ; D: send("", 0) on an AF_UNIX datagram socket queues an empty record, and one before "ab" comes out
 * first (0 then 2); E: send(NULL, 0) and write(fd, "", 0) on it the same; F: SOCK_SEQPACKET as D; G: on an AF_UNIX stream socket a
 * zero-length send and write return 0 and queue nothing; H: sendto a bound datagram path with 0 bytes queues an empty record. Each
 * case prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
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
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_SEQPACKET 5
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
static int connect(int s, const void *a, socklen_t n) { return (int)ret(syscall3(42, s, (long)a, n)); }
static int socketpair(int d, int t, int p, int sv[2]) { return (int)ret(syscall4(53, d, t, p, (long)sv)); }
static long sendto(int s, const void *b, unsigned long n, int f, const void *a, socklen_t al) { return ret(syscall6(44, s, (long)b, (long)n, f, (long)a, al)); }
static long send(int s, const void *b, unsigned long n, int f) { return ret(syscall6(44, s, (long)b, (long)n, f, 0, 0)); }
static long recv(int s, void *b, unsigned long n, int f) { return ret(syscall6(45, s, (long)b, (long)n, f, 0, 0)); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello552:   ok   " : "hello552:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* Every queued message on `s` as "<len>;" (then the -errno that ended it). */
static void drain(int s, char *out, size_t cap) {
    char b[16];
    out[0] = 0;
    usleep(20000);
    for (int i = 0; i < 6; i++) {
        long r = recv(s, b, sizeof b, MSG_DONTWAIT);
        size_t l = strlen(out);
        if (r < 0) {
            snprintf(out + l, cap - l, "%d;", -errno);
            return;
        }
        snprintf(out + l, cap - l, "%ld;", r);
    }
}
static long rv(long r) { return r < 0 ? -errno : r; }
/* write() as a result or -errno: moqi_libc's write() returns the kernel's -errno itself, glibc's -1 with errno. */
#ifdef HOST
static long wr(int fd, const void *b, unsigned long n) { return rv(write(fd, b, n)); }
#else
static long wr(int fd, const void *b, unsigned long n) { return write(fd, b, n); }
#endif
int main(void) {
    print("hello552: zero-byte write() and AF_UNIX sends\n");
    char got[100], want[100];
    int u = socket(AF_INET, SOCK_DGRAM, 0), w = socket(AF_INET, SOCK_DGRAM, 0);
    unsigned char sa[16] = {AF_INET, 0, 0x25, 0x60, 127, 0, 0, 1}; /* 127.0.0.1:9568 */
    int bd = bind(u, (void *)sa, 16);
    long c0 = wr(w, "", 0);
    int cn = connect(w, (void *)sa, 16);
    long a = wr(w, "", 0);
    drain(u, got, sizeof got);
    snprintf(want, sizeof want, "0;%d;", -EAGAIN);
    snprintf(msg, sizeof msg, "A: UDP write(\"\", 0) %ld, received '%s' (bind %d connect %d; 0, '%s')", a, got, bd, cn, want);
    check(bd == 0 && cn == 0 && a == 0 && strcmp(got, want) == 0, msg);
    long b = wr(w, (void *)0, 0);
    drain(u, got, sizeof got);
    snprintf(msg, sizeof msg, "B: UDP write(NULL, 0) %ld, received '%s' (0, '%s')", b, got, want);
    check(b == 0 && strcmp(got, want) == 0, msg);
    snprintf(msg, sizeof msg, "C: unconnected UDP write of 0 bytes %ld (%d)", c0, -EDESTADDRREQ);
    check(c0 == -EDESTADDRREQ, msg);
    close(u);
    close(w);

    int sv[2];
    int sp = socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
    long d1 = rv(send(sv[0], "", 0, 0));
    long d2 = rv(send(sv[0], "ab", 2, 0));
    drain(sv[1], got, sizeof got);
    snprintf(want, sizeof want, "0;2;%d;", -EAGAIN);
    snprintf(msg, sizeof msg, "D: AF_UNIX dgram send(\"\", 0) %ld then \"ab\" %ld, received '%s' (socketpair %d; 0 2, '%s')", d1, d2, got, sp, want);
    check(sp == 0 && d1 == 0 && d2 == 2 && strcmp(got, want) == 0, msg);
    long e1 = rv(send(sv[0], (void *)0, 0, 0));
    long e2 = wr(sv[0], "", 0);
    drain(sv[1], got, sizeof got);
    snprintf(want, sizeof want, "0;0;%d;", -EAGAIN);
    snprintf(msg, sizeof msg, "E: send(NULL, 0) %ld, write(\"\", 0) %ld, received '%s' (0 0, '%s')", e1, e2, got, want);
    check(e1 == 0 && e2 == 0 && strcmp(got, want) == 0, msg);
    close(sv[0]);
    close(sv[1]);

    sp = socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv);
    long f1 = rv(send(sv[0], "", 0, 0));
    long f2 = rv(send(sv[0], "ab", 2, 0));
    drain(sv[1], got, sizeof got);
    snprintf(want, sizeof want, "0;2;%d;", -EAGAIN);
    snprintf(msg, sizeof msg, "F: seqpacket send(\"\", 0) %ld then \"ab\" %ld, received '%s' (socketpair %d; 0 2, '%s')", f1, f2, got, sp, want);
    check(sp == 0 && f1 == 0 && f2 == 2 && strcmp(got, want) == 0, msg);
    close(sv[0]);
    close(sv[1]);

    sp = socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    long g1 = rv(send(sv[0], "", 0, 0));
    long g2 = wr(sv[0], "", 0);
    drain(sv[1], got, sizeof got);
    snprintf(want, sizeof want, "%d;", -EAGAIN);
    snprintf(msg, sizeof msg, "G: stream send %ld, write %ld, received '%s' (socketpair %d; 0 0, '%s')", g1, g2, got, sp, want);
    check(sp == 0 && g1 == 0 && g2 == 0 && strcmp(got, want) == 0, msg);
    close(sv[0]);
    close(sv[1]);

    int r = socket(AF_UNIX, SOCK_DGRAM, 0), s = socket(AF_UNIX, SOCK_DGRAM, 0);
    unsigned char un[16] = {AF_UNIX, 0, 0, 'h', '5', '5', '2'}; /* abstract "\0h552" */
    int br = bind(r, (void *)un, 7);
    long h = rv(sendto(s, "", 0, 0, (void *)un, 7));
    drain(r, got, sizeof got);
    snprintf(want, sizeof want, "0;%d;", -EAGAIN);
    snprintf(msg, sizeof msg, "H: sendto a bound path with 0 bytes %ld, received '%s' (bind %d; 0, '%s')", h, got, br, want);
    check(br == 0 && h == 0 && strcmp(got, want) == 0, msg);
    close(r);
    close(s);

    print(failures ? "hello552: FAIL\n" : "hello552: PASS\n");
    return failures ? 1 : 0;
}
