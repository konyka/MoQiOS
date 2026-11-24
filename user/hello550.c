/* hello550: SO_PEEK_OFF on UDP sockets (Linux 7.x udp_recvmsg, measured with -DHOST). A peek at the offset skips whole datagrams the
 * offset reaches past and copies from inside the one it falls in; every receive moves the offset by its result: forward for a peek,
 * back for a read (not below 0), and that result is the datagram's whole length under MSG_TRUNC. A: the option reads -1 and takes 0
 * and 7; B: "abcdef" and "ghij" queued, peeks of 2 give "ab" "cd" "ef" "gh" "ij" (offset 10), then EAGAIN; C: offset 4 with
 * MSG_TRUNC gives "e" and 6, the whole datagram's length, so the offset moves to 10; offset 6 gives "ghij", offset 9 "j", 10 EAGAIN; D: offset 2, a read of 3 takes "abc" of
 * "abcdef" (offset 0), offset 5, a read of 2 takes "gh" (offset 3); E: an offset equal to the first datagram's length peeks the
 * next one; F: the same on IPv6; G: recvmsg moves the offset as recvfrom does; H: a blocking peek at the end
 * waits for the next datagram. Each case prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
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
#define AF_INET6 10
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define MSG_PEEK 0x2
#define MSG_TRUNC 0x20
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
static int setsockopt(int s, int l, int o, const void *v, socklen_t n) { return (int)ret(syscall5(54, s, l, o, (long)v, n)); }
static int getsockopt(int s, int l, int o, void *v, socklen_t *n) { return (int)ret(syscall5(55, s, l, o, (long)v, (long)n)); }
static long sendto(int s, const void *b, unsigned long n, int f, const void *a, socklen_t al) { return ret(syscall6(44, s, (long)b, (long)n, f, (long)a, al)); }
static long recv(int s, void *b, unsigned long n, int f) { return ret(syscall6(45, s, (long)b, (long)n, f, 0, 0)); }
static long recvmsg(int s, struct msghdr *m, int f) { return ret(syscall3(47, s, (long)m, f)); }
#endif
#ifndef SO_PEEK_OFF
#define SO_PEEK_OFF 42
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello550:   ok   " : "hello550:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int u, w;
static unsigned char to[28];
static unsigned to_len;
static int off(void) {
    int v = -99;
    socklen_t l = sizeof v;
    if (getsockopt(u, SOL_SOCKET, SO_PEEK_OFF, &v, &l) != 0) return -100 - errno;
    return v;
}
static int so(int v) { return setsockopt(u, SOL_SOCKET, SO_PEEK_OFF, &v, sizeof v) == 0 ? 0 : -errno; }
static void snd(const char *t) { sendto(w, t, strlen(t), 0, (void *)to, to_len); }
/* One recv, appended as "<P|R>[t]<n>:<result>'<bytes>'/<offset after>;". */
static void rd(int fl, int n, char *out, size_t cap) {
    char b[64];
    memset(b, 0, sizeof b);
    long r = recv(u, b, (unsigned long)n, fl | MSG_DONTWAIT);
    if (r < 0) r = -errno;
    long shown = r > n ? n : r;
    size_t l = strlen(out);
    snprintf(out + l, cap - l, "%c%s%d:%ld'%.*s'/%d;", fl & MSG_PEEK ? 'P' : 'R', fl & MSG_TRUNC ? "t" : "", n, r, shown > 0 ? (int)shown : 0, b, off());
}
static void wait_a_bit(void) { usleep(30000); }
static int setup(int six, unsigned port) {
    u = socket(six ? AF_INET6 : AF_INET, SOCK_DGRAM, 0);
    w = socket(six ? AF_INET6 : AF_INET, SOCK_DGRAM, 0);
    memset(to, 0, sizeof to);
    to[0] = (unsigned char)(six ? AF_INET6 : AF_INET);
    to[2] = (unsigned char)(port >> 8);
    to[3] = (unsigned char)port;
    if (six) {
        to[23] = 1;
        to_len = 28;
    } else {
        to[4] = 127; to[7] = 1;
        to_len = 16;
    }
    return u >= 0 && w >= 0 && bind(u, (void *)to, to_len) == 0 ? 0 : -1;
}
static void queue_two(void) {
    snd("abcdef");
    snd("ghij");
    wait_a_bit();
}
static void peeks_of_two(char *got, size_t cap) {
    so(0);
    for (int i = 0; i < 6; i++) rd(MSG_PEEK, 2, got, cap);
}
int main(void) {
    print("hello550: SO_PEEK_OFF on UDP sockets\n");
    int sr = setup(0, 9550);
    int o0 = off(), s0 = so(0), o1 = off(), s7 = so(7), o7 = off();
    so(-1);
    snprintf(msg, sizeof msg, "A: default %d, set 0 %d -> %d, set 7 %d -> %d (setup %d; -1 0 0 0 7)", o0, s0, o1, s7, o7, sr);
    check(sr == 0 && o0 == -1 && s0 == 0 && o1 == 0 && s7 == 0 && o7 == 7, msg);

    char got[500] = "", want[500];
    queue_two();
    peeks_of_two(got, sizeof got);
    snprintf(want, sizeof want, "P2:2'ab'/2;P2:2'cd'/4;P2:2'ef'/6;P2:2'gh'/8;P2:2'ij'/10;P2:%d''/10;", -EAGAIN);
    snprintf(msg, sizeof msg, "B: peeks of 2: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    got[0] = 0;
    so(4);
    rd(MSG_PEEK | MSG_TRUNC, 1, got, sizeof got);
    so(6);
    rd(MSG_PEEK, 10, got, sizeof got);
    so(9);
    rd(MSG_PEEK, 10, got, sizeof got);
    so(10);
    rd(MSG_PEEK, 10, got, sizeof got);
    snprintf(want, sizeof want, "Pt1:6'e'/10;P10:4'ghij'/10;P10:1'j'/10;P10:%d''/10;", -EAGAIN);
    snprintf(msg, sizeof msg, "C: offsets 4 (MSG_TRUNC), 6, 9, 10: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    got[0] = 0;
    so(2);
    rd(0, 3, got, sizeof got);
    so(5);
    rd(0, 2, got, sizeof got);
    snprintf(want, sizeof want, "R3:3'abc'/0;R2:2'gh'/3;");
    snprintf(msg, sizeof msg, "D: reads pull it back: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    got[0] = 0;
    snd("k");
    snd("qr");
    wait_a_bit();
    so(1);
    rd(MSG_PEEK, 4, got, sizeof got);
    rd(MSG_PEEK, 4, got, sizeof got);
    rd(0, 4, got, sizeof got);
    so(-1);
    rd(0, 4, got, sizeof got);
    snprintf(want, sizeof want, "P4:2'qr'/3;P4:%d''/3;R4:1'k'/2;R4:2'qr'/-1;", -EAGAIN);
    snprintf(msg, sizeof msg, "E: an offset equal to the first datagram's length: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);
    close(u);
    close(w);

    got[0] = 0;
    sr = setup(1, 9551);
    queue_two();
    peeks_of_two(got, sizeof got);
    so(-1);
    rd(0, 10, got, sizeof got);
    rd(0, 10, got, sizeof got);
    snprintf(want, sizeof want, "P2:2'ab'/2;P2:2'cd'/4;P2:2'ef'/6;P2:2'gh'/8;P2:2'ij'/10;P2:%d''/10;R10:6'abcdef'/-1;R10:4'ghij'/-1;", -EAGAIN);
    snprintf(msg, sizeof msg, "F: IPv6: '%s' (setup %d; '%s')", got, sr, want);
    check(sr == 0 && strcmp(got, want) == 0, msg);
    close(u);
    close(w);

    setup(0, 9552);
    queue_two();
    so(3);
    char b[16];
    memset(b, 0, sizeof b);
    struct iovec iv = {b, 2};
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iv;
    m.msg_iovlen = 1;
    long r1 = recvmsg(u, &m, MSG_PEEK | MSG_DONTWAIT);
    int o_a = off();
    long r2 = recvmsg(u, &m, MSG_DONTWAIT);
    int o_b = off();
    snprintf(msg, sizeof msg, "G: recvmsg: peek %ld '%.2s' offset %d, read %ld offset %d (2 de 5, 2 3)", r1, b, o_a, r2, o_b);
    check(r1 == 2 && o_a == 5 && r2 == 2 && o_b == 3, msg);
    close(u);
    close(w);

    setup(0, 9553);
    snd("x");
    wait_a_bit();
    so(1);
    long pid = (long)fork();
    if (pid == 0) {
        usleep(200000);
        snd("yz");
        _exit(0);
    }
    memset(b, 0, sizeof b);
    long r = recv(u, b, sizeof b, MSG_PEEK);
    int st = -1;
    if (pid > 0) waitpid(pid, &st, 0);
    snprintf(msg, sizeof msg, "H: blocking peek at the end: %ld '%.*s' offset %d (2 yz 3)", r, r > 0 ? (int)r : 0, b, off());
    check(r == 2 && memcmp(b, "yz", 2) == 0 && off() == 3, msg);
    close(u);
    close(w);

    print(failures ? "hello550: FAIL\n" : "hello550: PASS\n");
    return failures ? 1 : 0;
}
