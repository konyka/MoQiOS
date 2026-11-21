/* hello485: TIOCGPGRP answers only on the caller's controlling terminal (Linux tiocgpgrp: tty == real_tty and current->signal->tty
 * != real_tty is ENOTTY). Measured on the host (build with -DHOST, run on a pseudo-terminal: python3 -c 'import pty; pty.spawn(...)'):
 *   A. in the session that owns the terminal, TIOCGPGRP on fd 0 returns 0 and the foreground process group (> 0);
 *   B. a child that called setsid (a new session without a controlling terminal) gets ENOTTY from TIOCGPGRP on the same fd 0;
 *   C. TIOCGPGRP on a pipe is ENOTTY. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long io(int fd, unsigned long cmd, void *a) { return rc(ioctl(fd, cmd, a)); }
static long setsid_(void) { return rc(setsid()); }
static long fork_(void) { return fork(); }
static int wait_(long c) { int st = 0; waitpid((pid_t)c, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 100; }
static long pipe_(int *p) { return rc(pipe(p)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
static long io(int fd, unsigned long cmd, void *a) { return syscall3(SYS_ioctl, fd, (long)cmd, (long)a); }
static long setsid_(void) { return syscall0(206); }
static long fork_(void) { return syscall0(57); }
static int wait_(long c) { int st = 0; syscall3(6, c, (long)&st, 0); return (st & 0x7f) ? 100 : (st >> 8) & 0xff; }
static long pipe_(int *p) { return syscall2(SYS_pipe2, (long)p, 0); }
#endif
static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello485:   ok   " : "hello485:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello485: TIOCGPGRP only on the controlling terminal\n");
    int pg = -1;
    long a = io(0, 0x540F, &pg);
    snprintf(msg, sizeof msg, "A: TIOCGPGRP on fd 0 %ld, pgrp %d (0, > 0)", a, pg);
    check(a == 0 && pg > 0, msg);
    long c = fork_();
    if (c == 0) {
        long s = setsid_();
        int pg2 = -1;
        long r = io(0, 0x540F, &pg2);
        _exit(s > 0 && r == -25 && pg2 == -1 ? 0 : (r == 0 ? 2 : 1));
    }
    int st = wait_(c);
    snprintf(msg, sizeof msg, "B: after setsid TIOCGPGRP on fd 0: child exit %d (0: ENOTTY; 2: answered)", st);
    check(st == 0, msg);
    int p[2];
    pipe_(p);
    long pr = io(p[0], 0x540F, &pg);
    snprintf(msg, sizeof msg, "C: on a pipe %ld (-25)", pr);
    check(pr == -25, msg);
    print(failures ? "hello485: FAIL\n" : "hello485: PASS\n");
    return failures ? 1 : 0;
}
