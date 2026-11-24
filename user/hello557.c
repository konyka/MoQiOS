/* hello557: zero-byte sends on an IPv4 ping socket (Linux 7.x ping_v4_sendmsg, measured with -DHOST): a message shorter than the
 * 8-byte ICMP header is EINVAL, so write(fd, "", 0) on an unconnected and on a connected ping socket, send("", 0) and
 * sendto(127.0.0.1, "", 0) are all EINVAL. A: unconnected write; B: connected write; C: send; D: sendto. The test sets
 * net.ipv4.ping_group_range to "0 0" and puts the old value back at the end. Needs root. Each case prints what it saw; the expected
 * value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long wr(int fd, const void *b, unsigned long n) { long r = write(fd, b, n); return r < 0 ? -errno : r; }
static long sn(int fd, const void *b, unsigned long n, int f) { long r = send(fd, b, n, f); return r < 0 ? -errno : r; }
static long st(int fd, const void *b, unsigned long n, const void *a, unsigned al) { long r = sendto(fd, b, n, 0, a, al); return r < 0 ? -errno : r; }
static int sk(void) { int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP); return s < 0 ? -errno : s; }
static int cn(int s, const void *a, unsigned al) { return connect(s, a, al) == 0 ? 0 : -errno; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#define EINVAL 22
static long wr(int fd, const void *b, unsigned long n) { return write(fd, b, n); }
static long sn(int fd, const void *b, unsigned long n, int f) { return syscall6(44, fd, (long)b, (long)n, f, 0, 0); }
static long st(int fd, const void *b, unsigned long n, const void *a, unsigned al) { return syscall6(44, fd, (long)b, (long)n, 0, (long)a, al); }
static int sk(void) { return (int)syscall3(41, 2, 2, 1); }
static int cn(int s, const void *a, unsigned al) { return (int)syscall3(42, s, (long)a, al); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello557:   ok   " : "hello557:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
#define RANGE "/proc/sys/net/ipv4/ping_group_range"
static long set_range(const char *text) {
    int fd = (int)open(RANGE, 1, 0);
    if (fd < 0) return fd;
    long n = (long)write(fd, text, strlen(text));
    close(fd);
    return n;
}
int main(void) {
    print("hello557: zero-byte sends on a ping socket\n");
    char saved[64];
    memset(saved, 0, sizeof saved);
    int rf = (int)open(RANGE, 0, 0);
    long rn = rf >= 0 ? (long)read(rf, saved, sizeof saved - 1) : -1;
    if (rf >= 0) close(rf);
    long sr = set_range("0 0");
    int s = sk();
    unsigned char sa[16] = {2, 0, 0, 0, 127, 0, 0, 1};
    long a = wr(s, "", 0);
    snprintf(msg, sizeof msg, "A: unconnected write of 0 bytes %ld (range read %ld set %ld socket %d; %d)", a, rn, sr, s, -EINVAL);
    check(s >= 0 && a == -EINVAL, msg);
    int c = cn(s, sa, 16);
    long b = wr(s, "", 0);
    snprintf(msg, sizeof msg, "B: connected write of 0 bytes %ld (connect %d; %d)", b, c, -EINVAL);
    check(c == 0 && b == -EINVAL, msg);
    long d1 = sn(s, "", 0, 0);
    snprintf(msg, sizeof msg, "C: send of 0 bytes %ld (%d)", d1, -EINVAL);
    check(d1 == -EINVAL, msg);
    long d2 = st(s, "", 0, sa, 16);
    snprintf(msg, sizeof msg, "D: sendto of 0 bytes %ld (%d)", d2, -EINVAL);
    check(d2 == -EINVAL, msg);
    if (s >= 0) close(s);
    if (rn > 0) set_range(saved);
    print(failures ? "hello557: FAIL\n" : "hello557: PASS\n");
    return failures ? 1 : 0;
}
