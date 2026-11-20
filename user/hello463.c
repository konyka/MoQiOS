/* hello463: net.ipv6.auto_flowlabels (Linux /proc/sys/net/ipv6/auto_flowlabels, proc_dou8vec_minmax 0..3; ip6_make_flowlabel and
 * ip6_autoflowlabel). Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up):
 *   A. the file reads "1\n"; writes of 0, 3 and " 2" are taken (the length returned) and read back; 4, -1 and "abc" are EINVAL and
 *      leave the value;
 *   B. mode 0: a UDP datagram to [::1] carries no label even with IPV6_AUTOFLOWLABEL 1; getsockopt of a socket that set nothing
 *      reads 0;
 *   C. mode 2 (opt-in): a socket that set nothing sends no label and reads IPV6_AUTOFLOWLABEL 0; one that set 1 sends a label;
 *   D. mode 3 (forced): even a socket with IPV6_AUTOFLOWLABEL 0 sends a label; a socket that set nothing reads 1;
 *   E. mode 1 again: a socket that set nothing sends a label. The test puts the original value back. */
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
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getint(long s, int lv, int o) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, lv, o, &v, &l)); return r < 0 ? r : v; }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void nap(void) { usleep(20000); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long io_(long fd, char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getint(long s, int lv, int o) { int v = -1; int l = 4; long r = syscall5(133, s, lv, o, (long)&v, (long)&l); return r < 0 ? r : v; }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr ? 1 : 0, 0); }
static long io_(long fd, char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello463:   ok   " : "hello463:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char *path = "/proc/sys/net/ipv6/auto_flowlabels";
static long rd(char *b) {
    long fd = open_(path, 0);
    if (fd < 0) return fd;
    long n = io_(fd, b, 15, 0);
    close_(fd);
    if (n >= 0) b[n] = 0;
    return n;
}
static long wr(const char *v) {
    long fd = open_(path, 1);
    if (fd < 0) return fd;
    long n = io_(fd, (char *)v, (int)strlen(v), 1);
    close_(fd);
    return n;
}
static long rcv;
/* The flow label of the next datagram on `rcv` (from its IPV6_FLOWINFO message, 0 without one), -1 with nothing. */
static long next_flow(void) {
    nap();
    static unsigned char ctl[128];
    char d[8];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    memset(ctl, 0, sizeof ctl);
    long iov[2] = { (long)d, 8 };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    long r = recvmsg_(rcv, mh, 0x40);
    if (r < 0) return -1;
    long used;
    memcpy(&used, mh + 40, 8);
    if (used >= 20 && ctl[8] == 41 && ctl[12] == 11) return (ctl[17] & 0x0f) << 16 | ctl[18] << 8 | ctl[19];
    return 0;
}
static unsigned char a[28];
/* A label from a new socket: `set` < 0 leaves IPV6_AUTOFLOWLABEL alone, else sets it; `got` receives its getsockopt. */
static long label_of(int set, long *got) {
    long u = sock(10, 2, 0);
    if (set >= 0) setopt_(u, 41, 70, &set, 4);
    *got = getint(u, 41, 70);
    sendto_(u, "x", 1, a, 28);
    long l = next_flow();
    close_(u);
    return l;
}
int main(void) {
    print("hello463: net.ipv6.auto_flowlabels\n");
    char saved[16] = { 0 }, b[16] = { 0 };
    long n0 = rd(saved);
    memset(a, 0, 28);
    a[0] = 10; a[2] = 4630 >> 8; a[3] = 4630 & 0xff; a[23] = 1;
    rcv = sock(10, 2, 0);
    bind_(rcv, a, 28);
    int one = 1;
    setopt_(rcv, 41, 11, &one, 4);

    long w0 = wr("0");
    rd(b);
    int r0 = b[0] == '0';
    long w3 = wr("3");
    rd(b);
    int r3 = b[0] == '3';
    long w4 = wr("4"), wm = wr("-1"), wa = wr("abc");
    rd(b);
    int still3 = b[0] == '3';
    long w2 = wr(" 2");
    rd(b);
    int r2 = b[0] == '2';
    snprintf(msg, sizeof msg, "A: reads \"%c\" (%ld bytes); 0 %ld %d, 3 %ld %d; 4 %ld, -1 %ld, abc %ld, still 3 %d; \" 2\" %ld %d (1 2; 1 1 1 1; -22 -22 -22 1; 2 1)", saved[0], n0, w0,
             r0, w3, r3, w4, wm, wa, still3, w2, r2);
    check(saved[0] == '1' && n0 == 2 && w0 == 1 && r0 && w3 == 1 && r3 && w4 == -22 && wm == -22 && wa == -22 && still3 && w2 == 2 && r2, msg);

    long g;
    wr("0");
    long b1 = label_of(1, &g);
    long bg;
    long b2 = label_of(-1, &bg);
    snprintf(msg, sizeof msg, "B: mode 0: label with IPV6_AUTOFLOWLABEL 1 %lx; unset socket label %lx reads %ld (0 0 0)", b1, b2, bg);
    check(b1 == 0 && b2 == 0 && bg == 0, msg);

    wr("2");
    long cg, cg1;
    long c1 = label_of(-1, &cg);
    long c2 = label_of(1, &cg1);
    snprintf(msg, sizeof msg, "C: mode 2: unset socket label %lx reads %ld; set 1 label %lx (0 0 >0)", c1, cg, c2);
    check(c1 == 0 && cg == 0 && c2 > 0, msg);

    wr("3");
    long dg, dg0;
    long d1 = label_of(0, &dg0);
    long d2 = label_of(-1, &dg);
    snprintf(msg, sizeof msg, "D: mode 3: IPV6_AUTOFLOWLABEL 0 label %lx; unset socket label %lx reads %ld (>0 >0 1)", d1, d2, dg);
    check(d1 > 0 && d2 > 0 && dg == 1, msg);

    wr("1");
    long eg;
    long e1 = label_of(-1, &eg);
    snprintf(msg, sizeof msg, "E: mode 1: unset socket label %lx reads %ld (>0 1)", e1, eg);
    check(e1 > 0 && eg == 1, msg);

    if (n0 > 0) {
        int k = 0;
        while (saved[k] && saved[k] != '\n') k++;
        saved[k] = 0;
        wr(saved);
    }
    print(failures ? "hello463: FAIL\n" : "hello463: PASS\n");
    return failures ? 1 : 0;
}
