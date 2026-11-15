/* hello338: TCFLSH and TCSBRK on the console tty (Linux drivers/tty/tty_ioctl.c tty_perform_flush, tty_mode_ioctl; tty_io.c
 * send_break / tty_wait_until_sent for TCSBRK).
 * Measured on the host (build with -DHOST: a pty slave in raw mode stands in for /dev/tty, master writes stand in for TIOCSTI):
 *   A. TCFLSH TCOFLUSH (1) succeeds and keeps the queued input;
 *   B. TCFLSH TCIFLUSH (0) succeeds and discards it;
 *   C. TCFLSH TCIOFLUSH (2) succeeds and discards it; a character queued afterwards is read;
 *   D. TCFLSH 3 and -1 are EINVAL;
 *   E. TCSBRK 1 (tcdrain) and TCSBRK 0 (a break) succeed;
 *   F. on a pipe both are ENOTTY. */
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
static long io(long fd, unsigned long cmd, long a) { long r = ioctl((int)fd, cmd, a); return r == -1 ? -errno : r; }
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
static long io(long fd, unsigned long cmd, long a) { return syscall3(165, fd, (long)cmd, a); }
static int open_tty(void) { return (int)open("/dev/tty", 2, 0); }
static void inj(int fd, char c) { io(fd, 0x5412, (long)&c); }
static void settle(void) {}
#endif

#define T_SBRK 0x5409
#define T_FLSH 0x540B

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello338:   ok   " : "hello338:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static void drain(int t) {
    char b[64];
    while (read(t, b, sizeof b) > 0) {}
}

int main(void) {
    print("hello338: TCFLSH and TCSBRK on the console tty\n");
    int t = open_tty();
    drain(t);
    char b[16];

    inj(t, 'a');
    inj(t, 'b');
    settle();
    long a0 = io(t, T_FLSH, 1);
    long a1 = read(t, b, sizeof b);
    snprintf(msg, sizeof msg, "A: TCFLSH TCOFLUSH %ld keeps the queued input (read %ld)", a0, a1);
    check(a0 == 0 && a1 == 2, msg);
    drain(t);

    inj(t, 'a');
    inj(t, 'b');
    settle();
    long b0 = io(t, T_FLSH, 0);
    long b1 = read(t, b, sizeof b);
    snprintf(msg, sizeof msg, "B: TCFLSH TCIFLUSH %ld discards it (read %ld)", b0, b1);
    check(b0 == 0 && b1 <= 0, msg);
    drain(t);

    inj(t, 'c');
    inj(t, 'd');
    settle();
    long c0 = io(t, T_FLSH, 2);
    inj(t, 'e');
    settle();
    memset(b, 0, sizeof b);
    long c1 = read(t, b, sizeof b);
    snprintf(msg, sizeof msg, "C: TCFLSH TCIOFLUSH %ld discards it, a later character is read (%ld '%c')", c0, c1, b[0] ? b[0] : '-');
    check(c0 == 0 && c1 == 1 && b[0] == 'e', msg);
    drain(t);

    long d0 = io(t, T_FLSH, 3);
    long d1 = io(t, T_FLSH, -1);
    snprintf(msg, sizeof msg, "D: TCFLSH 3 %ld, TCFLSH -1 %ld", d0, d1);
    check(d0 == -22 && d1 == -22, msg);

    long e0 = io(t, T_SBRK, 1);
    long e1 = io(t, T_SBRK, 0);
    snprintf(msg, sizeof msg, "E: TCSBRK 1 %ld, TCSBRK 0 %ld", e0, e1);
    check(e0 == 0 && e1 == 0, msg);

    int p[2];
    pipe(p);
    long f0 = io(p[0], T_FLSH, 0);
    long f1 = io(p[0], T_SBRK, 1);
    snprintf(msg, sizeof msg, "F: on a pipe TCFLSH %ld, TCSBRK %ld", f0, f1);
    check(f0 == -25 && f1 == -25, msg);
    close(p[0]);
    close(p[1]);

    close(t);
    print(failures ? "hello338: FAIL\n" : "hello338: PASS\n");
    return failures ? 1 : 0;
}
