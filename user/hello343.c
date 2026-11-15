/* hello343: a connect stuck in SYN-SENT (the listener's accept queue is full, so its SYN is dropped) keeps its SYN outstanding:
 * TCP_INFO reports tcpi_unacked 1 until the SYN is acknowledged, and the retransmitted SYN still completes the connection once the
 * queue has room. Linux never runs the tail loss probe before a connection is established (tcp_schedule_loss_probe), so nothing
 * moves SND.NXT back over the SYN.
 * Measured on the host (build with -DHOST, listen backlog 32):
 *   A. 40 non-blocking connects to one listener on 127.0.0.1 return EINPROGRESS (or 0);
 *   B. after 1.5 s at least one of them is still in SYN-SENT (tcpi_state 2);
 *   C. sampled every 100 ms for 4 s, every client in SYN-SENT reports tcpi_unacked 1;
 *   D. accepting as connections arrive, all 40 are accepted within 12 s (the dropped SYNs are retransmitted). */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static void mk(struct sockaddr_in *a, int port) { memset(a, 0, sizeof *a); a->sin_family = AF_INET; a->sin_port = htons(port); a->sin_addr.s_addr = htonl(0x7f000001); }
static long sock(int type) { return rc(socket(AF_INET, type, 0)); }
static long bind4(long s, int port) { struct sockaddr_in a; mk(&a, port); return rc(bind((int)s, (void *)&a, sizeof a)); }
static long connect4(long s, int port) { struct sockaddr_in a; mk(&a, port); return rc(connect((int)s, (void *)&a, sizeof a)); }
static long sendto4(long s, int port, const char *b, int n) { struct sockaddr_in a; mk(&a, port); return rc(sendto((int)s, b, n, 0, (void *)&a, sizeof a)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long accept_(long s) { return rc(accept4((int)s, 0, 0, SOCK_NONBLOCK)); }
static long write_(long s, const char *b, int n) { return rc(write((int)s, b, n)); }
static long tcpinfo(long s, unsigned char *b, int n) { socklen_t l = (socklen_t)n; return rc(getsockopt((int)s, 6, 11, b, &l)); }
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define SOCK_NONBLOCK 0x800
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
static void mk(unsigned char *a, int port) { for (int i = 0; i < 16; i++) a[i] = 0; a[0] = 2; a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port; a[4] = 127; a[7] = 1; }
static long sock(int type) { return syscall3(117, 2, type, 0); }
static long bind4(long s, int port) { unsigned char a[16]; mk(a, port); return syscall3(118, s, (long)a, 16); }
static long connect4(long s, int port) { unsigned char a[16]; mk(a, port); return syscall3(124, s, (long)a, 16); }
static long sendto4(long s, int port, const char *b, int n) { unsigned char a[16]; mk(a, port); return syscall6(121, s, (long)b, n, 0, (long)a, 16); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long listen_(long s) { return syscall2(119, s, 4); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0x800); }
static long write_(long s, const char *b, int n) { return syscall3(1, s, (long)b, n); }
static long tcpinfo(long s, unsigned char *b, int n) { int l = n; return syscall5(133, s, 6, 11, (long)b, (long)&l); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello343:   ok   " : "hello343:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
#ifdef HOST
    struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000 };
    nanosleep(&t, 0);
#else
    long t[2] = { ms / 1000, (long)(ms % 1000) * 1000000 };
    syscall2(35, (long)t, 0);
#endif
}
static unsigned u32at(const unsigned char *b, int off) { return (unsigned)b[off] | (unsigned)b[off + 1] << 8 | (unsigned)b[off + 2] << 16 | (unsigned)b[off + 3] << 24; }

#define N 40
int main(void) {
    print("hello343: a connect stuck in SYN-SENT keeps its SYN outstanding\n");
    long l = sock(SOCK_STREAM);
    long lb = bind4(l, 18895);
#ifdef HOST
    long ll = rc(listen((int)l, 32));
#else
    long ll = syscall2(119, l, 32);
#endif
    long c[N];
    int started = 0;
    for (int i = 0; i < N; i++) {
        c[i] = sock(SOCK_STREAM | SOCK_NONBLOCK);
        long r = connect4(c[i], 18895);
        if (c[i] >= 0 && (r == -115 || r == 0)) started++;
        pump();
    }
    snprintf(msg, sizeof msg, "A: listener bind %ld listen %ld; %d of %d non-blocking connects started", lb, ll, started, N);
    check(lb == 0 && ll == 0 && started == N, msg);

    int syn_sent = 0, outstanding = 0, bad_unacked = -1, samples = 0;
    long info_rc = 0;
    for (int round = 0; round < 40; round++) {
        sleep_ms(100);
        for (int i = 0; i < N; i++) {
            unsigned char ti[104];
            for (int k = 0; k < 104; k++) ti[k] = 0;
            long r = tcpinfo(c[i], ti, sizeof ti);
            if (r < 0) { info_rc = r; continue; }
            if (ti[0] != 2) continue;
            samples++;
            if (round == 14) syn_sent++;
            if (u32at(ti, 24) == 1) outstanding++;
            else if (bad_unacked < 0) bad_unacked = (int)u32at(ti, 24);
        }
    }
    snprintf(msg, sizeof msg, "B: after 1.5 s %d clients are still in SYN-SENT (TCP_INFO rc %ld)", syn_sent, info_rc);
    check(syn_sent >= 1 && info_rc == 0, msg);
    snprintf(msg, sizeof msg, "C: sampled every 100 ms for 4 s, %d of %d SYN-SENT readings report tcpi_unacked 1 (another value: %d)", outstanding, samples, bad_unacked);
    check(samples >= 1 && outstanding == samples, msg);

    int accepted = 0;
    for (int t = 0; t < 12000 && accepted < N; t += 10) {
        long a = accept_(l);
        if (a >= 0) { accepted++; close_(a); continue; }
        pump();
    }
    snprintf(msg, sizeof msg, "D: %d of %d connections accepted within 12 s", accepted, N);
    check(accepted == N, msg);

    for (int i = 0; i < N; i++) close_(c[i]);
    close_(l);
    print(failures ? "hello343: FAIL\n" : "hello343: PASS\n");
    return failures ? 1 : 0;
}
