/* hello421: the IPv4 receive control messages of a UDP socket (Linux ip_setsockopt IP_PKTINFO / IP_RECVTTL / IP_RECVTOS,
 * ip_cmsg_recv_offset, ip_cmsg_recv_pktinfo / _ttl / _tos, put_cmsg). Each option is an on/off flag read back as 0 or 1; while it is
 * on, recvmsg appends a control message: IP_PKTINFO a struct in_pktinfo (interface index, local address the datagram should be
 * answered from, header destination), IP_TTL an int, IP_TOS one byte; in that order. A control buffer too small sets MSG_CTRUNC.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   V. the three options read 0 by default, 1 after setting 1 (and 5), 0 after setting 0;
 *   N. with none set, recvmsg returns msg_controllen 0 and msg_flags 0;
 *   P. IP_PKTINFO on, a datagram to 127.0.0.1 from a socket with IP_TTL 33 and IP_TOS 0x28: one message of length 28 (level 0, type
 *      8), ifindex 1, spec_dst 127.0.0.1, addr 127.0.0.1; msg_controllen 32;
 *   A. all three on: IP_PKTINFO, then IP_TTL (length 20, value 33), then IP_TOS (length 17, value 0x28); msg_controllen 80;
 *   T. all three on, a 40-byte control buffer: only IP_PKTINFO fits whole, MSG_CTRUNC is set, msg_controllen 32;
 *   D. a datagram to 127.0.0.5 (lo answers the whole 127/8) reports addr 127.0.0.5 and spec_dst 127.0.0.5. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void close_(long s) { close((int)s); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recvmsg_(long s, long *m, int fl) { return rc(recvmsg((int)s, (struct msghdr *)m, fl)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvmsg_(long s, long *m, int fl) { return syscall3(130, s, (long)m, fl); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
#define PKTINFO 8
#define RECVTTL 12
#define RECVTOS 13
static int failures;
static char msg[1200];
static void check(int ok, const char *w) {
    print(ok ? "hello421:   ok   " : "hello421:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static void mk4(unsigned char *a, int port, int last) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = (unsigned char)last;
}
static unsigned long rd64(const unsigned char *p) { unsigned long v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static int rd32(const unsigned char *p) { return (int)(p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24); }
static unsigned char ctl[256];
static long m[7];
static long ctl_len, ctl_flags;
/* Send "ping" from `tx` to `dst` and recvmsg it on `rx` with a control buffer of `cap` bytes: the recvmsg result. */
static long roundtrip(long tx, long rx, const unsigned char *dst, long cap) {
    static char data[16];
    sendto_(tx, "ping", 4, dst, 16);
    for (int i = 0; i < 3; i++) nap();
    unsigned char name[16];
    long iov[2] = { (long)data, sizeof data };
    memset(ctl, 0xee, sizeof ctl);
    memset(m, 0, sizeof m);
    m[0] = (long)name; m[1] = 16; m[2] = (long)iov; m[3] = 1; m[4] = cap ? (long)ctl : 0; m[5] = cap;
    long r = recvmsg_(rx, m, 0x40);
    ctl_len = m[5];
    ctl_flags = (int)m[6];
    return r;
}
/* The control message at offset `off` of ctl: its length, level and type (and the next offset in *next). */
static void cm_at(long off, long *len, int *lv, int *ty, long *next) {
    *len = (long)rd64(ctl + off);
    *lv = rd32(ctl + off + 8);
    *ty = rd32(ctl + off + 12);
    *next = off + ((*len + 7) & ~7L);
    if (*len < 16 || *next > 200) *next = 200;
}
int main(void) {
    print("hello421: IPv4 UDP receive control messages\n");
    unsigned char ra[16], d1[16], d5[16];
    mk4(ra, 40421, 0);
    ra[4] = 0;
    mk4(d1, 40421, 1);
    mk4(d5, 40421, 5);
    long rx = sock(2, 2, 0);
    long b = bind_(rx, ra, 16);
    long tx = sock(2, 2, 0);
    seti(tx, 0, 2, 33);
    seti(tx, 0, 1, 0x28);

    int o[3] = { PKTINFO, RECVTTL, RECVTOS };
    int d[3], one[3], five[3], zero[3];
    for (int i = 0; i < 3; i++) {
        d[i] = geti(rx, 0, o[i]);
        seti(rx, 0, o[i], 1); one[i] = geti(rx, 0, o[i]);
        seti(rx, 0, o[i], 5); five[i] = geti(rx, 0, o[i]);
        seti(rx, 0, o[i], 0); zero[i] = geti(rx, 0, o[i]);
    }
    snprintf(msg, sizeof msg, "V: bind %ld; PKTINFO RECVTTL RECVTOS default %d %d %d, 1 reads %d %d %d, 5 reads %d %d %d, 0 reads %d %d %d (0; 0 0 0; 1 1 1; 1 1 1; 0 0 0)",
             b, d[0], d[1], d[2], one[0], one[1], one[2], five[0], five[1], five[2], zero[0], zero[1], zero[2]);
    check(b == 0 && d[0] == 0 && d[1] == 0 && d[2] == 0 && one[0] == 1 && one[1] == 1 && one[2] == 1 && five[0] == 1 && five[1] == 1 && five[2] == 1 &&
          zero[0] == 0 && zero[1] == 0 && zero[2] == 0, msg);

    long nr = roundtrip(tx, rx, d1, 128);
    snprintf(msg, sizeof msg, "N: recvmsg %ld, controllen %ld, flags 0x%lx (4, 0, 0)", nr, ctl_len, ctl_flags);
    check(nr == 4 && ctl_len == 0 && ctl_flags == 0, msg);

    seti(rx, 0, PKTINFO, 1);
    long pr = roundtrip(tx, rx, d1, 128);
    long l0, n0; int lv0, ty0;
    cm_at(0, &l0, &lv0, &ty0, &n0);
    int pif = rd32(ctl + 16);
    snprintf(msg, sizeof msg, "P: recvmsg %ld, controllen %ld, flags 0x%lx; len %ld level %d type %d, ifindex %d spec_dst %d.%d.%d.%d addr %d.%d.%d.%d (4, 32, 0; 28 0 8, 1 127.0.0.1 127.0.0.1)",
             pr, ctl_len, ctl_flags, l0, lv0, ty0, pif, ctl[20], ctl[21], ctl[22], ctl[23], ctl[24], ctl[25], ctl[26], ctl[27]);
    check(pr == 4 && ctl_len == 32 && ctl_flags == 0 && l0 == 28 && lv0 == 0 && ty0 == 8 && pif == 1 &&
          !memcmp(ctl + 20, "\x7f\0\0\x01", 4) && !memcmp(ctl + 24, "\x7f\0\0\x01", 4), msg);

    seti(rx, 0, RECVTTL, 1);
    seti(rx, 0, RECVTOS, 1);
    long ar = roundtrip(tx, rx, d1, 128);
    long l1, n1, l2, n2, l3, n3; int lv1, ty1, lv2, ty2, lv3, ty3;
    cm_at(0, &l1, &lv1, &ty1, &n1);
    cm_at(n1, &l2, &lv2, &ty2, &n2);
    int ttl = rd32(ctl + n1 + 16);
    cm_at(n2, &l3, &lv3, &ty3, &n3);
    int tos = ctl[n2 + 16];
    snprintf(msg, sizeof msg, "A: recvmsg %ld, controllen %ld, flags 0x%lx; %ld/%d/%d, %ld/%d/%d ttl %d, %ld/%d/%d tos 0x%x (4, 80, 0; 28/0/8, 20/0/2 33, 17/0/1 0x28)",
             ar, ctl_len, ctl_flags, l1, lv1, ty1, l2, lv2, ty2, ttl, l3, lv3, ty3, tos);
    check(ar == 4 && ctl_len == 80 && ctl_flags == 0 && l1 == 28 && ty1 == 8 && l2 == 20 && lv2 == 0 && ty2 == 2 && ttl == 33 &&
          l3 == 17 && lv3 == 0 && ty3 == 1 && tos == 0x28, msg);

    long tr = roundtrip(tx, rx, d1, 40);
    snprintf(msg, sizeof msg, "T: 40-byte buffer: recvmsg %ld, controllen %ld, flags 0x%lx, first len %ld (4, 32, 0x8, 28)", tr, ctl_len, ctl_flags, (long)rd64(ctl));
    check(tr == 4 && ctl_len == 32 && ctl_flags == 8 && rd64(ctl) == 28, msg);

    seti(rx, 0, RECVTTL, 0);
    seti(rx, 0, RECVTOS, 0);
    long dr = roundtrip(tx, rx, d5, 128);
    snprintf(msg, sizeof msg, "D: to 127.0.0.5: recvmsg %ld, controllen %ld; spec_dst %d.%d.%d.%d addr %d.%d.%d.%d (4, 32; 127.0.0.5 127.0.0.5)",
             dr, ctl_len, ctl[20], ctl[21], ctl[22], ctl[23], ctl[24], ctl[25], ctl[26], ctl[27]);
    check(dr == 4 && ctl_len == 32 && !memcmp(ctl + 20, "\x7f\0\0\x05", 4) && !memcmp(ctl + 24, "\x7f\0\0\x05", 4), msg);

    close_(tx);
    close_(rx);
    print(failures == 0 ? "hello421: PASS\n" : "hello421: FAIL\n");
    return failures == 0 ? 0 : 1;
}
