/* hello342: a retransmitted SYN carries the connection's original ISN (RFC 9293 3.8.1; Linux tcp_retransmit_skb resends the queued
 * SYN unchanged), so the peer's answer to it is still accepted.
 * The test fills MoQiOS's 16-frame loopback queue with UDP datagrams so the first SYN is dropped and only the retransmitted one
 * reaches the peer (the path hello341 opened). On Linux nothing is dropped and the answers come at once. A regression test: the
 * kernel already passed it when it was written (B took about 2 s, one retransmit timeout).
 * Measured on the host (build with -DHOST):
 *   A. 16 datagrams to ourselves, then a non-blocking connect to a closed port on 127.0.0.1 returns EINPROGRESS or ECONNREFUSED;
 *   B. within 8 s the connect fails with ECONNREFUSED (SO_ERROR 111): the RST answering the SYN is accepted;
 *   C. after another 16 datagrams a non-blocking connect to a listener completes within 8 s and is accepted;
 *   D. one byte written by the client reaches the accepted socket. */
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
static long soerror(long s) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, SO_ERROR, &v, &l)); return r < 0 ? r : v; }
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
static long soerror(long s) { int v = -1; int l = 4; long r = syscall5(133, s, 1, 4, (long)&v, (long)&l); return r < 0 ? r : v; }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello342:   ok   " : "hello342:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static long u;
static int fill_queue(void) {
    char got[4];
    for (int i = 0; i < 64 && recv_(u, got, sizeof got) > 0; i++) {}
    pump();
    for (int i = 0; i < 64 && recv_(u, got, sizeof got) > 0; i++) {}
    int n = 0;
    for (int i = 0; i < 16; i++) { char c = 'q'; if (sendto4(u, 18890, &c, 1) == 1) n++; }
    return n;
}

int main(void) {
    print("hello342: a retransmitted SYN carries the original ISN\n");
    u = sock(SOCK_DGRAM);
    long ub = bind4(u, 18890);

    int f1 = fill_queue();
    long c = sock(SOCK_STREAM | SOCK_NONBLOCK);
    long c0 = connect4(c, 18891);
    snprintf(msg, sizeof msg, "A: bind %ld, %d datagrams queued; non-blocking connect to a closed port %ld", ub, f1, c0);
    check(ub == 0 && f1 == 16 && (c0 == -115 || c0 == -111), msg);

    long e = c0 == -111 ? 111 : 0;
    int waited = 0;
    for (; e == 0 && waited < 8000; waited += 10) { pump(); e = soerror(c); }
    snprintf(msg, sizeof msg, "B: the connect fails with ECONNREFUSED: SO_ERROR %ld after %d ms", e, waited);
    check(e == 111, msg);
    close_(c);

    long l = sock(SOCK_STREAM);
    long lb = bind4(l, 18892), ll = listen_(l);
    int f2 = fill_queue();
    long k = sock(SOCK_STREAM | SOCK_NONBLOCK);
    long k0 = connect4(k, 18892);
    long r = k0;
    for (int i = 0; i < 800 && r != 0 && r != -106; i++) {
        pump();
        r = connect4(k, 18892);
        if (r != -114 && r != -115 && r != 0 && r != -106) break;
    }
    long a = -11;
    for (int i = 0; i < 300 && a < 0; i++) { a = accept_(l); if (a < 0) pump(); }
    snprintf(msg, sizeof msg, "C: listener %ld/%ld, %d datagrams queued; connect %ld then %ld; accepted %ld", lb, ll, f2, k0, r, a);
    check(lb == 0 && ll == 0 && f2 == 16 && (r == 0 || r == -106) && a >= 0, msg);

    long w = write_(k, "z", 1);
    char got[4] = { 0 };
    long n = -11;
    for (int i = 0; i < 300 && a >= 0 && n <= 0; i++) { n = recv_(a, got, sizeof got); if (n <= 0) pump(); }
    snprintf(msg, sizeof msg, "D: a byte the client writes (%ld) reaches the accepted socket: %ld '%c'", w, n, n == 1 ? got[0] : '?');
    check(w == 1 && n == 1 && got[0] == 'z', msg);

    if (a >= 0) close_(a);
    close_(k);
    close_(l);
    close_(u);
    print(failures ? "hello342: FAIL\n" : "hello342: PASS\n");
    return failures ? 1 : 0;
}
