/* hello565: long execve arguments and long system() command lines. The kernel used to copy every argv/envp string into its own
 * 128-byte buffer, so any string over 127 bytes was E2BIG and system() could run at most 127 bytes of shell. The strings now share
 * the one 4 KiB page of the initial stack: one string may be as long as the page allows. A: system() of a 200-byte line ending in
 * "exit 3" is 3; B: a 1000-byte line too; C: execve of hello232 with a 1000-byte argument arrives intact (exit 0); D: twelve
 * 250-byte arguments arrive intact; E: an argument of 5000 bytes cannot fit the page and is E2BIG, the caller keeps running
 * (Linux takes it: the host branch expects success); F: a shell command line longer than the shell's 1024-byte buffer is refused
 * with status 2 instead of being run cut short (bash runs it: the host branch expects 3). */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define CHECKER "./h232"
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#define CHECKER "hello232"
#endif

static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello565:   ok   " : "hello565:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int code(int st) { return st == -1 || (st & 0x7f) ? -1 : (st >> 8) & 0xff; }

/* A command line of exactly len bytes: blanks, then "exit 3". */
static int run_line(int len) {
    static char line[1200];
    memset(line, ' ', (size_t)len);
    memcpy(line + len - 6, "exit 3", 6);
    line[len] = 0;
    return code(system(line));
}

/* fork, execve the checker with n arguments of len bytes each (letters 'a', 'b', ...), and return the child's exit code, or 77
 * when execve itself failed with E2BIG (78 for any other failure). */
static int exec_args(int n, int len) {
    static char store[16][5100];
    static char cnt[8];
    char *av[20];
    av[0] = (char *)CHECKER;
    snprintf(cnt, sizeof cnt, "%d", n + 1); /* hello232 counts its own count argument */
    av[1] = cnt;
    for (int i = 0; i < n; i++) {
        memset(store[i], 'a' + i, (size_t)len);
        store[i][len] = 0;
        av[2 + i] = store[i];
    }
    av[2 + n] = (char *)0;
    char *ev[1] = { (char *)0 };
    long pid = fork();
    if (pid == 0) {
        execve(CHECKER, av, ev);
        _exit(78);
    }
    int st = -1;
    waitpid(pid, &st, 0);
    return code(st);
}

#ifndef HOST
/* The same, but the child reports the raw execve result: 77 for E2BIG. */
static int exec_raw(int len) {
    static char big[5100];
    memset(big, 'q', (size_t)len);
    big[len] = 0;
    char *av[4] = { (char *)CHECKER, (char *)"2", big, (char *)0 };
    long pid = fork();
    if (pid == 0) {
        long r = syscall3(SYS_execve, (long)CHECKER, (long)av, 0);
        _exit(r == -7 ? 77 : 78);
    }
    int st = -1;
    waitpid(pid, &st, 0);
    return code(st);
}
#endif

int main(void) {
    print("hello565: long execve arguments and long system() lines\n");
    int r;

    r = run_line(200);
    snprintf(msg, sizeof msg, "A: a 200-byte command line: status %d (3)", r);
    check(r == 3, msg);

    r = run_line(1000);
    snprintf(msg, sizeof msg, "B: a 1000-byte command line: status %d (3)", r);
    check(r == 3, msg);

    r = exec_args(1, 1000);
    snprintf(msg, sizeof msg, "C: one 1000-byte argument: checker exit %d (0)", r);
    check(r == 0, msg);

    r = exec_args(12, 250);
    snprintf(msg, sizeof msg, "D: twelve 250-byte arguments: checker exit %d (0)", r);
    check(r == 0, msg);

#ifdef HOST
    r = exec_args(1, 5000);
    snprintf(msg, sizeof msg, "E: a 5000-byte argument: checker exit %d (Linux: 0)", r);
    check(r == 0, msg);
#else
    r = exec_raw(5000);
    snprintf(msg, sizeof msg, "E: a 5000-byte argument: %d (77 = E2BIG, the caller runs on)", r);
    check(r == 77, msg);
#endif

    r = run_line(1100);
#ifdef HOST
    snprintf(msg, sizeof msg, "F: a 1100-byte command line: status %d (bash: 3)", r);
    check(r == 3, msg);
#else
    snprintf(msg, sizeof msg, "F: a 1100-byte command line: status %d (2: refused, not run cut short)", r);
    check(r == 2, msg);
#endif

    print(failures ? "hello565: FAIL\n" : "hello565: PASS\n");
    return failures ? 1 : 0;
}
