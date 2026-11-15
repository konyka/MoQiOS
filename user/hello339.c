/* hello339: TCXONC (tcflow) on the console tty (Linux drivers/tty/tty_ioctl.c n_tty_ioctl_helper TCXONC).
 * Measured on the host (build with -DHOST: a pty slave in raw mode stands in for /dev/tty):
 *   A. TCOOFF (0), TCOON (1), TCIOFF (2) and TCION (3) succeed;
 *   B. selectors 4 and -1 are EINVAL;
 *   C. on a pipe TCXONC is ENOTTY;
 *   D. after TCOON a write to the terminal goes through. */
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
static int open_tty(void) {
    int master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK);
    grantpt(master);
    unlockpt(master);
    int s = open(ptsname(master), O_RDWR | O_NOCTTY | O_NONBLOCK);
    struct termios t;
    tcgetattr(s, &t);
    cfmakeraw(&t);
    tcsetattr(s, TCSANOW, &t);
    return s;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long io(long fd, unsigned long cmd, long a) { return syscall3(165, fd, (long)cmd, a); }
static int open_tty(void) { return (int)open("/dev/tty", 2, 0); }
#endif

#define T_XONC 0x540A

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello339:   ok   " : "hello339:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

int main(void) {
    print("hello339: TCXONC on the console tty\n");
    int t = open_tty();

    long a0 = io(t, T_XONC, 0), a1 = io(t, T_XONC, 1), a2 = io(t, T_XONC, 2), a3 = io(t, T_XONC, 3);
    snprintf(msg, sizeof msg, "A: TCOOFF %ld, TCOON %ld, TCIOFF %ld, TCION %ld", a0, a1, a2, a3);
    check(a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0, msg);

    long b0 = io(t, T_XONC, 4), b1 = io(t, T_XONC, -1);
    snprintf(msg, sizeof msg, "B: selector 4 %ld, selector -1 %ld", b0, b1);
    check(b0 == -22 && b1 == -22, msg);

    int p[2];
    pipe(p);
    long c0 = io(p[0], T_XONC, 1);
    snprintf(msg, sizeof msg, "C: TCXONC on a pipe %ld", c0);
    check(c0 == -25, msg);
    close(p[0]);
    close(p[1]);

    long d0 = write(t, "\n", 1);
    snprintf(msg, sizeof msg, "D: after TCOON a write goes through (%ld)", d0);
    check(d0 == 1, msg);

    close(t);
    print(failures ? "hello339: FAIL\n" : "hello339: PASS\n");
    return failures ? 1 : 0;
}
