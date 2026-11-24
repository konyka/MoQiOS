/* hello549: SO_PEEK_OFF on AF_UNIX sockets (Linux 7.x, measured with -DHOST). The offset is -1 until set; MSG_PEEK then starts at
 * the offset and moves it past what it copied, and a read moves it back by what left the queue (a whole datagram, however much
 * was copied), not below 0. A: the option reads -1, takes 0, reads it back; B: a stream ("abcdef" then "ghij"): peeks of 2 and 3
 * give "ab", "cde" (offset 5), a read of 4 gives "abcd" (offset 1), peeks give "fgh" then "ij" (offset 6), a peek at the end is
 * EAGAIN; C: -1 turns it off (peeks start at the head again), 100 past the end is EAGAIN and a read of 6 leaves 94; D: datagrams
 * ("abcdef", "ghij"): peeks run on across them ("ab" "cd" "ef" "gh", offset 8), a read of 3 takes all of "abcdef" (offset 2), the
 * next peek gives "ij"; E: a peek with the offset inside a datagram gives the rest of that datagram only; F: SOCK_SEQPACKET as D;
 * G: a blocking peek past the end waits for more data. Each case prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
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
/* The Linux numbers; moqi_libc has no socket wrappers. Each returns the result or -1 with errno, like the libc calls. */
typedef unsigned socklen_t;
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_SEQPACKET 5
#define SOL_SOCKET 1
#define MSG_PEEK 0x2
#define MSG_DONTWAIT 0x40
static long ret(long r) {
    if (r < 0) {
        errno = (int)-r;
        return -1;
    }
    return r;
}
static int socketpair(int d, int t, int p, int sv[2]) { return (int)ret(syscall4(53, d, t, p, (long)sv)); }
static int setsockopt(int s, int l, int o, const void *v, socklen_t n) { return (int)ret(syscall5(54, s, l, o, (long)v, n)); }
static int getsockopt(int s, int l, int o, void *v, socklen_t *n) { return (int)ret(syscall5(55, s, l, o, (long)v, (long)n)); }
static long send(int s, const void *b, unsigned long n, int f) { return ret(syscall6(44, s, (long)b, (long)n, f, 0, 0)); }
static long recv(int s, void *b, unsigned long n, int f) { return ret(syscall6(45, s, (long)b, (long)n, f, 0, 0)); }
#endif
#ifndef SO_PEEK_OFF
#define SO_PEEK_OFF 42
#endif
static int failures;
static char msg[800];
static void check(int ok, const char *w) {
    print(ok ? "hello549:   ok   " : "hello549:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int off(int s) {
    int v = -99;
    socklen_t l = sizeof v;
    if (getsockopt(s, SOL_SOCKET, SO_PEEK_OFF, &v, &l) != 0) return -100 - errno;
    return v;
}
static int setoff(int s, int v) { return setsockopt(s, SOL_SOCKET, SO_PEEK_OFF, &v, sizeof v) == 0 ? 0 : -errno; }
/* One recv, appended to `out` as "<P|R><n>:<result>'<bytes>'/<offset after>;". */
static void rd(int s, int peek, int n, char *out, size_t cap) {
    char b[64];
    memset(b, 0, sizeof b);
    long r = recv(s, b, (size_t)n, (peek ? MSG_PEEK : 0) | MSG_DONTWAIT);
    if (r < 0) r = -errno;
    size_t l = strlen(out);
    snprintf(out + l, cap - l, "%c%d:%ld'%.*s'/%d;", peek ? 'P' : 'R', n, r, r > 0 ? (int)r : 0, b, off(s));
}
static void dgrams(const char *tag, int type) {
    int sv[2];
    char got[300] = "";
    if (socketpair(AF_UNIX, type, 0, sv) != 0) {
        snprintf(msg, sizeof msg, "%s: socketpair %d", tag, errno);
        check(0, msg);
        return;
    }
    send(sv[0], "abcdef", 6, 0);
    send(sv[0], "ghij", 4, 0);
    int z = setoff(sv[1], 0);
    rd(sv[1], 1, 2, got, sizeof got);
    rd(sv[1], 1, 2, got, sizeof got);
    rd(sv[1], 1, 10, got, sizeof got);
    rd(sv[1], 1, 2, got, sizeof got);
    rd(sv[1], 0, 3, got, sizeof got);
    rd(sv[1], 1, 10, got, sizeof got);
    rd(sv[1], 0, 10, got, sizeof got);
    const char *want = "P2:2'ab'/2;P2:2'cd'/4;P10:2'ef'/6;P2:2'gh'/8;R3:3'abc'/2;P10:2'ij'/4;R10:4'ghij'/0;";
    snprintf(msg, sizeof msg, "%s: '%s' (set %d; %s)", tag, got, z, want);
    check(z == 0 && strcmp(got, want) == 0, msg);
    close(sv[0]);
    close(sv[1]);
}
int main(void) {
    print("hello549: SO_PEEK_OFF on AF_UNIX sockets\n");
    int sv[2];
    int sp = socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    int o0 = off(sv[1]);
    int z = setoff(sv[1], 0);
    snprintf(msg, sizeof msg, "A: default %d, set 0 -> %d, reads %d (socketpair %d; -1 0 0)", o0, z, off(sv[1]), sp);
    check(sp == 0 && o0 == -1 && z == 0 && off(sv[1]) == 0, msg);

    char got[400] = "";
    send(sv[0], "abcdef", 6, 0);
    send(sv[0], "ghij", 4, 0);
    rd(sv[1], 1, 2, got, sizeof got);
    rd(sv[1], 1, 3, got, sizeof got);
    rd(sv[1], 0, 4, got, sizeof got);
    rd(sv[1], 1, 3, got, sizeof got);
    rd(sv[1], 1, 10, got, sizeof got);
    rd(sv[1], 1, 2, got, sizeof got);
    char want[300];
    snprintf(want, sizeof want, "P2:2'ab'/2;P3:3'cde'/5;R4:4'abcd'/1;P3:3'fgh'/4;P10:2'ij'/6;P2:%d''/6;", -EAGAIN);
    snprintf(msg, sizeof msg, "B: stream: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    got[0] = 0;
    int m1 = setoff(sv[1], -1);
    rd(sv[1], 1, 2, got, sizeof got);
    int m2 = setoff(sv[1], 100);
    rd(sv[1], 1, 2, got, sizeof got);
    rd(sv[1], 0, 10, got, sizeof got);
    snprintf(want, sizeof want, "P2:2'ef'/-1;P2:%d''/100;R10:6'efghij'/94;", -EAGAIN);
    snprintf(msg, sizeof msg, "C: -1 and 100: '%s' (sets %d %d; '%s')", got, m1, m2, want);
    check(m1 == 0 && m2 == 0 && strcmp(got, want) == 0, msg);
    close(sv[0]);
    close(sv[1]);

    dgrams("D: datagrams", SOCK_DGRAM);

    got[0] = 0;
    socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
    send(sv[0], "abcdef", 6, 0);
    send(sv[0], "gh", 2, 0);
    setoff(sv[1], 4);
    rd(sv[1], 1, 10, got, sizeof got);
    rd(sv[1], 1, 10, got, sizeof got);
    rd(sv[1], 1, 10, got, sizeof got);
    rd(sv[1], 0, 3, got, sizeof got);
    snprintf(want, sizeof want, "P10:2'ef'/6;P10:2'gh'/8;P10:%d''/8;R3:3'abc'/2;", -EAGAIN);
    snprintf(msg, sizeof msg, "E: offset inside a datagram: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);
    close(sv[0]);
    close(sv[1]);

    dgrams("F: seqpacket", SOCK_SEQPACKET);

    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    send(sv[0], "abc", 3, 0);
    setoff(sv[1], 3);
    long pid = (long)fork();
    if (pid == 0) {
        usleep(200000);
        send(sv[0], "de", 2, 0);
        _exit(0);
    }
    char b[8] = {0};
    long r = recv(sv[1], b, sizeof b, MSG_PEEK);
    int st = -1;
    if (pid > 0) waitpid(pid, &st, 0);
    snprintf(msg, sizeof msg, "G: blocking peek at the end: %ld '%.*s' offset %d (2 de 5)", r, r > 0 ? (int)r : 0, b, off(sv[1]));
    check(r == 2 && memcmp(b, "de", 2) == 0 && off(sv[1]) == 5, msg);
    close(sv[0]);
    close(sv[1]);

    print(failures ? "hello549: FAIL\n" : "hello549: PASS\n");
    return failures ? 1 : 0;
}
