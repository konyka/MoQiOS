/* hello341: a full loopback queue does not make a send fail (Linux: loopback delivery never refuses a frame; a dropped SYN is resent
 * by the retransmit timer and a datagram the receiver has no room for is dropped there, sendto still succeeds).
 * Measured on the host (build with -DHOST):
 *   A. 40 one-byte datagrams sent to a bound UDP socket on 127.0.0.1 without reading any: every sendto returns 1;
 *   B. right after 16 such datagrams (MoQiOS's loopback queue holds 16 frames) a non-blocking TCP connect to a listener on 127.0.0.1
 *      returns EINPROGRESS or 0, not an error;
 *   C. that connection completes and the listener accepts it within 6 seconds;
 *   D. the UDP socket still receives the first datagram. */
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
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello341:   ok   " : "hello341:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

int main(void) {
    print("hello341: a full loopback queue does not make a send fail\n");
    long u = sock(SOCK_DGRAM);
    long ub = bind4(u, 18870);
    pump();
    int sent = 0;
    long bad = 0;
    for (int i = 0; i < 40; i++) {
        char c = (char)('a' + i % 26);
        long r = sendto4(u, 18870, &c, 1);
        if (r == 1) sent++;
        else if (bad == 0) bad = r;
    }
    snprintf(msg, sizeof msg, "A: bind %ld; 40 datagrams to ourselves without reading: %d sent, first error %ld", ub, sent, bad);
    check(ub == 0 && sent == 40, msg);

    long l = sock(SOCK_STREAM);
    long lb = bind4(l, 18871), ll = listen_(l);
    char got[4];
    for (int i = 0; i < 50 && recv_(u, got, sizeof got) > 0; i++) {}
    pump();
    int filled = 0;
    for (int i = 0; i < 16; i++) { char c = 'x'; if (sendto4(u, 18870, &c, 1) == 1) filled++; }
    long c = sock(SOCK_STREAM | SOCK_NONBLOCK);
    long cr = connect4(c, 18871);
    snprintf(msg, sizeof msg, "B: listener bind %ld listen %ld; after %d more datagrams a non-blocking connect returns %ld", lb, ll, filled, cr);
    check(lb == 0 && ll == 0 && filled == 16 && (cr == -115 || cr == 0), msg);

    long a = -11, again = cr;
    for (int i = 0; i < 600 && a < 0; i++) {
        pump();
        if (again != 0 && again != -106) again = connect4(c, 18871);
        a = accept_(l);
    }
    /* The handshake can finish between that iteration's connect (EALREADY) and accept: ask the connecting side again. */
    for (int i = 0; i < 100 && a >= 0 && again != 0 && again != -106; i++) {
        again = connect4(c, 18871);
        if (again != 0 && again != -106) pump();
    }
    snprintf(msg, sizeof msg, "C: the connection completes (connect again %ld) and is accepted (%ld)", again, a);
    check((again == 0 || again == -106) && a >= 0, msg);

    long n = recv_(u, got, sizeof got);
    snprintf(msg, sizeof msg, "D: the UDP socket still receives a datagram: %ld '%c'", n, n == 1 ? got[0] : '?');
    check(n == 1, msg);

    if (a >= 0) close_(a);
    close_(c);
    close_(l);
    close_(u);
    print(failures ? "hello341: FAIL\n" : "hello341: PASS\n");
    return failures ? 1 : 0;
}
