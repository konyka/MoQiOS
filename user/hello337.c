/* hello337: TCSETSW and TCSETSF on the console tty (Linux drivers/tty/tty_ioctl.c set_termios: TERMIOS_WAIT drains output first,
 * TERMIOS_FLUSH also discards the pending input with tty_ldisc_flush).
 * Measured on the host (build with -DHOST: a pty slave in raw mode stands in for /dev/tty, master writes stand in for TIOCSTI):
 *   A. TCSETSW succeeds and TCGETS reads the new VMIN back;
 *   B. TCSETSW keeps the input already queued: two queued characters are still read;
 *   C. TCSETSF succeeds, sets VMIN, and discards the queued input: after it only a character queued later is read;
 *   D. TCSETSW on a pipe is ENOTTY, TCSETSF with a NULL argument is EFAULT. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long io(long fd, unsigned long cmd, void *a) { long r = ioctl((int)fd, cmd, a); return r == -1 ? -errno : r; }
static int master;
static int open_tty(void) {
    master = posix_openpt(O_RDWR | O_NOCTTY);
    grantpt(master);
    unlockpt(master);
    int s = open(ptsname(master), O_RDWR | O_NOCTTY | O_NONBLOCK);
    struct termios t;
    tcgetattr(s, &t);
    cfmakeraw(&t);
    tcsetattr(s, TCSANOW, &t);
    return s;
}
static void inj(int fd, char c) { (void)fd; write(master, &c, 1); }
static void settle(void) { usleep(50000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long io(long fd, unsigned long cmd, void *a) { return syscall3(165, fd, (long)cmd, (long)a); }
static int open_tty(void) { return (int)open("/dev/tty", 2, 0); }
static void inj(int fd, char c) { io(fd, 0x5412, &c); }
static void settle(void) {}
#endif

#define T_GETS 0x5401
#define T_SETS 0x5402
#define T_SETSW 0x5403
#define T_SETSF 0x5404
/* struct termios as the kernel sees it: four 32-bit flag words, c_line, then c_cc; VMIN is c_cc[6]. */
#define VMIN_AT (17 + 6)

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello337:   ok   " : "hello337:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static void drain(int t) {
    char b[64];
    while (read(t, b, sizeof b) > 0) {}
}

int main(void) {
    print("hello337: TCSETSW and TCSETSF on the console tty\n");
    int t = open_tty();
    unsigned char saved[64], u[64], g[64];
    memset(saved, 0, sizeof saved);
    io(t, T_GETS, saved);
    drain(t);
    char b[16];

    memcpy(u, saved, sizeof u);
    u[VMIN_AT] = 3;
    long a0 = io(t, T_SETSW, u);
    memset(g, 0, sizeof g);
    long a1 = io(t, T_GETS, g);
    snprintf(msg, sizeof msg, "A: TCSETSW %ld, TCGETS %ld reads VMIN %d", a0, a1, g[VMIN_AT]);
    check(a0 == 0 && a1 == 0 && g[VMIN_AT] == 3, msg);

    inj(t, 'a');
    inj(t, 'b');
    settle();
    u[VMIN_AT] = 4;
    long b0 = io(t, T_SETSW, u);
    long b1 = read(t, b, sizeof b);
    snprintf(msg, sizeof msg, "B: TCSETSW %ld keeps the queued input (read %ld)", b0, b1);
    check(b0 == 0 && b1 == 2 && b[0] == 'a' && b[1] == 'b', msg);
    drain(t);

    inj(t, 'c');
    inj(t, 'd');
    settle();
    u[VMIN_AT] = 5;
    long c0 = io(t, T_SETSF, u);
    memset(g, 0, sizeof g);
    io(t, T_GETS, g);
    inj(t, 'e');
    settle();
    memset(b, 0, sizeof b);
    long c1 = read(t, b, sizeof b);
    snprintf(msg, sizeof msg, "C: TCSETSF %ld, VMIN %d, then only the later character is read (%ld '%c')", c0, g[VMIN_AT], c1,
             b[0] ? b[0] : '-');
    check(c0 == 0 && g[VMIN_AT] == 5 && c1 == 1 && b[0] == 'e', msg);
    drain(t);

    int p[2];
    pipe(p);
    long d0 = io(p[0], T_SETSW, u);
    long d1 = io(t, T_SETSF, (void *)0);
    snprintf(msg, sizeof msg, "D: TCSETSW on a pipe %ld, TCSETSF with NULL %ld", d0, d1);
    check(d0 == -25 && d1 == -14, msg);
    close(p[0]);
    close(p[1]);

    io(t, T_SETS, saved);
    close(t);
    print(failures ? "hello337: FAIL\n" : "hello337: PASS\n");
    return failures ? 1 : 0;
}
