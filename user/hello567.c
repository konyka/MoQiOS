/* hello567: epoll reports EPOLLPRI for a TCP socket with unread urgent data (Linux tcp_poll: EPOLLPRI is set while an urgent byte
 * waits for recv(MSG_OOB)). poll(2) already reported POLLPRI (hello443), but the epoll path was never checked -- and the shared
 * epoll_policy had no EPOLLPRI constant at all, so nothing tied the two together. A: a socket registered with EPOLLIN|EPOLLPRI
 * reports 0x3 (IN|PRI) once send(MSG_OOB) lands; B: after the urgent byte is read with recv(MSG_OOB), PRI is gone and only IN is
 * left for the rest of the data; C: an EPOLLIN-only registration does not report PRI (the interest mask filters it), yet a
 * registration with EPOLLPRI alone is made ready by the same event. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, int fl) { return rc(send((int)s, b, (size_t)n, fl)); }
static long recv_(long s, void *b, long n, int fl) { return rc(recv((int)s, b, (size_t)n, fl)); }
static long ep_create(void) { return rc(epoll_create1(0)); }
static long ep_ctl(long ep, int op, long fd, uint32_t ev) { struct epoll_event e = { .events = ev, .data = { .u64 = 7 } }; return rc(epoll_ctl((int)ep, op, (int)fd, &e)); }
static long ep_wait(long ep, uint32_t *out_ev) { struct epoll_event e; long n = rc(epoll_wait((int)ep, &e, 1, 100)); *out_ev = n > 0 ? e.events : 0; return n; }
static void close_(long s) { close((int)s); }
static void pause_ms(long ms) { usleep((useconds_t)ms * 1000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/epoll.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long sendto_(long s, const void *b, long n, int fl) { return syscall6(44, s, (long)b, n, fl, 0, 0); }
static long recv_(long s, void *b, long n, int fl) { return syscall6(45, s, (long)b, n, fl, 0, 0); }
static long ep_create(void) { return syscall1(SYS_epoll_create1, 0); }
static long ep_ctl(long ep, int op, long fd, uint32_t ev) { struct epoll_event e; e.events = ev; e.data.u64 = 7; return syscall4(SYS_epoll_ctl, ep, op, fd, (long)&e); }
static long ep_wait(long ep, uint32_t *out_ev) { struct epoll_event e; e.events = 0; long n = syscall4(SYS_epoll_wait, ep, (long)&e, 1, 100); *out_ev = n > 0 ? e.events : 0; return n; }
static void close_(long s) { syscall1(SYS_close, s); }
static void pause_ms(long ms) { long t[2] = { 0, ms * 1000000 }; syscall2(SYS_nanosleep, (long)t, 0); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello567:   ok   " : "hello567:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static int pair(int port, long *c, long *s) {
    unsigned char a[16];
    mk4(a, port);
    int one = 1;
    long l = sock(2, 1, 0);
    setopt(l, 1, 2, &one, 4);
    if (bind_(l, a, 16) != 0 || listen_(l, 4) != 0) return -1;
    *c = sock(2, 1, 0);
    if (connect_(*c, a, 16) != 0) return -1;
    *s = accept_(l);
    close_(l);
    setopt(*c, 6, 1, &one, 4); /* TCP_NODELAY */
    return *s >= 0 ? 0 : -1;
}
int main(void) {
    print("hello567: epoll reports EPOLLPRI for unread urgent data\n");
    long c, s;
    if (pair(47440, &c, &s) != 0) { check(0, "setup: connected pair"); print("hello567: FAIL\n"); return 1; }

    /* A: EPOLLIN|EPOLLPRI registration sees the urgent byte. */
    long ep = ep_create();
    long ac = ep_ctl(ep, EPOLL_CTL_ADD, s, EPOLLIN | EPOLLPRI);
    uint32_t ev = 0;
    long w0 = ep_wait(ep, &ev);
    uint32_t ev0 = ev;
    long r = sendto_(c, "abc", 3, 1 /* MSG_OOB */);
    pause_ms(50);
    long w1 = ep_wait(ep, &ev);
    snprintf(msg, sizeof msg, "A: create %ld, add %ld, idle wait %ld ev 0x%x, send oob %ld, wait %ld ev 0x%x (>=0, 0, 0 0x0, 3, 1 0x3)",
             ep, ac, w0, (unsigned)ev0, r, w1, (unsigned)ev);
    check(ep >= 0 && ac == 0 && w0 == 0 && r == 3 && w1 == 1 && ev == (EPOLLIN | EPOLLPRI), msg);

    /* B: reading the urgent byte clears PRI; the remaining data still reports IN. */
    char b[16];
    memset(b, 0, sizeof b);
    long oob = recv_(s, b, 1, 1 /* MSG_OOB */);
    char oc = b[0];
    long w2 = ep_wait(ep, &ev);
    uint32_t ev2 = ev;
    memset(b, 0, sizeof b);
    long rest = recv_(s, b, 16, 0x40 /* MSG_DONTWAIT */);
    int ab = b[0] == 'a' && b[1] == 'b';
    snprintf(msg, sizeof msg, "B: recv oob %ld '%c', wait %ld ev 0x%x (IN only), rest %ld ab %d (1 c, 1 0x1, 2 1)", oob, oc, w2, (unsigned)ev2, rest, ab);
    check(oob == 1 && oc == 'c' && w2 == 1 && ev2 == EPOLLIN && rest == 2 && ab, msg);

    /* C: an EPOLLPRI-only registration is made ready by the event (0x2); an EPOLLIN-only one reports the readable bytes before the
     * mark (0x1) but never PRI. */
    long c2, s2;
    if (pair(47441, &c2, &s2) != 0) { check(0, "C: second pair"); } else {
        long ep2 = ep_create();
        long ap = ep_ctl(ep2, EPOLL_CTL_ADD, s2, EPOLLPRI);
        sendto_(c2, "xyz", 3, 1);
        pause_ms(50);
        long w3 = ep_wait(ep2, &ev);
        uint32_t ev3 = ev;
        long ep3 = ep_create();
        long ai = ep_ctl(ep3, EPOLL_CTL_ADD, s2, EPOLLIN); /* IN only: PRI must not be reported */
        long w4 = ep_wait(ep3, &ev);
        uint32_t ev4 = ev;
        snprintf(msg, sizeof msg, "C: PRI-only add %ld wait %ld ev 0x%x; IN-only add %ld wait %ld ev 0x%x (0, 1 0x2, 0, 1 0x1)",
                 ap, w3, (unsigned)ev3, ai, w4, (unsigned)ev4);
        check(ap == 0 && w3 == 1 && ev3 == EPOLLPRI && ai == 0 && w4 == 1 && ev4 == EPOLLIN, msg);
        close_(ep2);
        close_(ep3);
        close_(c2);
        close_(s2);
    }

    close_(ep);
    close_(c);
    close_(s);
    print(failures ? "hello567: FAIL\n" : "hello567: PASS\n");
    return failures ? 1 : 0;
}
