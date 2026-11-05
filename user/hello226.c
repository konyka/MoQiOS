/* hello226: atexit/exit, abort, raise, assert, signal(), sigset_t, sigprocmask, perror, remove, rename, isatty and the id
 * calls of moqi_libc on the real kernel. Each process-ending case runs in a forked child and the parent checks the wait status. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#undef NDEBUG /* zig cc -O2 defines it; this probe is about assert firing */
#include "../lib/moqi_libc/include/assert.h"
#include "../lib/moqi_libc/include/getopt.h"
#include "../lib/moqi_libc/include/dirent.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello226:   ok   " : "hello226:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

/* Runs f in a child with stderr and stdout redirected to a pipe; returns the wait status and fills out. */
static int run_child(void (*f)(void), char *out, size_t cap) {
    int p[2];
    if (pipe(p) != 0) return -1;
    long pid = fork();
    if (pid == 0) {
        dup2(p[1], 1);
        dup2(p[1], 2);
        close(p[0]);
        close(p[1]);
        f();
        _exit(99);
    }
    close(p[1]);
    size_t n = 0;
    for (;;) {
        long r = read(p[0], out + n, cap - 1 - n);
        if (r <= 0) break;
        n += (size_t)r;
        if (n >= cap - 1) break;
    }
    out[n] = 0;
    close(p[0]);
    int st = -1;
    waitpid(pid, &st, 0);
    return st;
}
static int exited(int st, int code) { return (st & 0x7f) == 0 && ((st >> 8) & 0xff) == code; }
static int killed_by(int st, int sig) { return (st & 0x7f) == sig; }

static void h1(void) { write(1, "1", 1); }
static void h2(void) { write(1, "2", 1); }
static void h3(void) { write(1, "3", 1); }
static void h_exit(void) { write(1, "X", 1); exit(77); }
static void h_reg(void) { write(1, "R", 1); atexit(h1); }

static void c_order(void) { atexit(h1); atexit(h2); atexit(h3); exit(4); }
static void c_exit_in_handler(void) { atexit(h1); atexit(h_exit); atexit(h2); exit(5); }
static void c_register(void) { atexit(h2); atexit(h_reg); exit(0); }
static void c_many(void) {
    int ok = 1;
    for (int i = 0; i < 100; i++) ok &= (atexit(h1) == 0);
    write(1, ok ? "ok" : "no", 2);
    exit(0);
}
static void c_flush(void) { printf("before"); fprintf(stdout, "-buffered"); exit(0); }
static void c__exit(void) { atexit(h1); _Exit(9); }
static void c_return_main_like(void) { atexit(h3); exit(0); }

static void c_abort(void) { atexit(h1); abort(); }
static void c_abort_blocked(void) {
    sigset_t s; sigemptyset(&s); sigaddset(&s, SIGABRT);
    sigprocmask(SIG_BLOCK, &s, (sigset_t *)0);
    abort();
}
static void c_abort_ignored(void) { signal(SIGABRT, SIG_IGN); abort(); }
static void on_abrt(int s) { (void)s; write(1, "H", 1); }
static void c_abort_handler(void) { signal(SIGABRT, on_abrt); abort(); }
static void c_abort_flush(void) { fprintf(stdout, "unflushed"); abort(); }

static void c_assert_fail(void) { int x = 0; assert(x == 1); }
static void c_assert_ok(void) { int x = 1; assert(x == 1); write(1, "fine", 4); exit(0); }

static volatile int hits;
static void on_usr1(int s) { (void)s; hits++; }
static void c_raise(void) {
    signal(SIGUSR1, on_usr1);
    int r = raise(SIGUSR1);
    char b[2] = { (char)('0' + hits), 0 };
    write(1, r == 0 ? "r0:" : "rE:", 3);
    write(1, b, 1);
    exit(0);
}
static void c_raise_default(void) { raise(SIGTERM); write(1, "alive", 5); exit(0); }

static void c_perror(void) {
    errno = ENOENT;
    perror("prog");
    errno = EINVAL;
    perror((const char *)0);
    exit(0);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello226: exit/abort/raise/assert/signal and POSIX file calls\n");
    char out[512];
    int st;

    /* A: atexit and exit */
    st = run_child(c_order, out, sizeof out);
    check(exited(st, 4) && strcmp(out, "321") == 0, "A: handlers run last-registered first and exit keeps its status");
    st = run_child(c_exit_in_handler, out, sizeof out);
    check(exited(st, 77) && strcmp(out, "2X1") == 0, "A: exit() inside a handler continues with the remaining handlers and its status wins");
    st = run_child(c_register, out, sizeof out);
    check(exited(st, 0) && strcmp(out, "R12") == 0, "A: a handler may register another, which runs next");
    st = run_child(c_many, out, sizeof out);
    check(exited(st, 0) && strncmp(out, "ok", 2) == 0, "A: a hundred registrations succeed");
    st = run_child(c_flush, out, sizeof out);
    check(exited(st, 0) && strcmp(out, "before-buffered") == 0, "A: exit flushes the buffered FILE streams");
    st = run_child(c__exit, out, sizeof out);
    check(exited(st, 9) && strcmp(out, "") == 0, "A: _Exit runs no handler");
    st = run_child(c_return_main_like, out, sizeof out);
    check(exited(st, 0) && strcmp(out, "3") == 0, "A: a registered function runs at exit");
    check(atexit((void (*)(void))0) == -1 && errno == EINVAL, "A: atexit(NULL) fails with EINVAL");

    /* B: abort */
    st = run_child(c_abort, out, sizeof out);
    check(killed_by(st, SIGABRT) && strcmp(out, "") == 0, "B: abort ends the process with SIGABRT and runs no atexit function");
    st = run_child(c_abort_blocked, out, sizeof out);
    check(killed_by(st, SIGABRT), "B: abort works although SIGABRT was blocked");
    st = run_child(c_abort_ignored, out, sizeof out);
    check(killed_by(st, SIGABRT), "B: abort works although SIGABRT was ignored");
    st = run_child(c_abort_handler, out, sizeof out);
    check(killed_by(st, SIGABRT) && strcmp(out, "H") == 0, "B: a SIGABRT handler runs once, then the process still dies of SIGABRT");
    st = run_child(c_abort_flush, out, sizeof out);
    check(killed_by(st, SIGABRT) && strcmp(out, "") == 0, "B: abort does not flush FILE buffers");

    /* C: assert */
    st = run_child(c_assert_fail, out, sizeof out);
    check(killed_by(st, SIGABRT), "C: a failed assert ends the process with SIGABRT");
    check(strstr(out, "hello226: ") == out && strstr(out, ": c_assert_fail: Assertion `x == 1' failed.\n") != (char *)0,
          "C: and names the program, the function and the expression on stderr");
    check(strstr(out, "hello226.c:") != (char *)0, "C: and the source file");
    st = run_child(c_assert_ok, out, sizeof out);
    check(exited(st, 0) && strcmp(out, "fine") == 0, "C: a true assert does nothing");

    /* D: raise and signal */
    st = run_child(c_raise, out, sizeof out);
    check(exited(st, 0) && strcmp(out, "r0:1") == 0, "D: raise() runs the handler before it returns");
    st = run_child(c_raise_default, out, sizeof out);
    check(killed_by(st, SIGTERM) && strcmp(out, "") == 0, "D: raise(SIGTERM) with the default action ends the process");
    check(signal(SIGKILL, on_usr1) == SIG_ERR && errno == EINVAL, "D: signal(SIGKILL) fails with EINVAL");
    check(signal(0, on_usr1) == SIG_ERR && signal(65, on_usr1) == SIG_ERR && signal(32, on_usr1) == SIG_ERR, "D: signals 0, 32 and 65 are refused");
    sighandler_t old = signal(SIGUSR2, SIG_IGN);
    check(old == SIG_DFL, "D: signal returns the previous (default) action");
    check(signal(SIGUSR2, on_usr1) == SIG_IGN, "D: and then the ignore it replaced");
    check(signal(SIGUSR2, SIG_DFL) == on_usr1, "D: and then the handler it replaced");
    errno = 0;
    check(raise(65) == -1 && errno == EINVAL, "D: raise(65) fails with EINVAL");
    check(raise(0) == 0, "D: raise(0) only checks");

    /* E: sigset_t and sigprocmask */
    sigset_t s, o;
    sigemptyset(&s);
    check(sigismember(&s, SIGUSR1) == 0 && sigaddset(&s, SIGUSR1) == 0 && sigismember(&s, SIGUSR1) == 1, "E: add and test a signal");
    sigfillset(&s);
    check(sigismember(&s, SIGKILL) == 1 && sigismember(&s, 32) == 0 && sigismember(&s, 64) == 1, "E: fillset has everything but the reserved 32 and 33");
    errno = 0;
    check(sigaddset(&s, 0) == -1 && errno == EINVAL, "E: signal 0 is EINVAL");
    sigemptyset(&s);
    sigaddset(&s, SIGUSR1);
    check(sigprocmask(SIG_BLOCK, &s, &o) == 0 && sigismember(&o, SIGUSR1) == 0, "E: block SIGUSR1, the old mask did not have it");
    hits = 0;
    signal(SIGUSR1, on_usr1);
    raise(SIGUSR1);
    check(hits == 0, "E: a blocked signal does not run its handler");
    check(sigprocmask(SIG_UNBLOCK, &s, (sigset_t *)0) == 0 && hits == 1, "E: unblocking delivers it");
    errno = 0;
    check(sigprocmask(99, &s, (sigset_t *)0) == -1 && errno == EINVAL, "E: a bad 'how' is EINVAL");
    sigemptyset(&o);
    sigprocmask(SIG_BLOCK, (const sigset_t *)0, &o);
    check(sigismember(&o, SIGUSR1) == 0, "E: reading the mask leaves it alone");

    /* E2: sigpending and sigsuspend on the real kernel */
    sigemptyset(&s);
    sigaddset(&s, SIGUSR1);
    sigprocmask(SIG_BLOCK, &s, (sigset_t *)0);
    hits = 0;
    raise(SIGUSR1);
    sigemptyset(&o);
    check(sigpending(&o) == 0 && sigismember(&o, SIGUSR1) == 1 && hits == 0, "E: a blocked, raised signal shows up in sigpending");
    sigset_t none;
    sigemptyset(&none);
    errno = 0;
    check(sigsuspend(&none) == -1 && errno == EINTR && hits == 1, "E: sigsuspend with an empty mask runs the pending handler and fails with EINTR");
    sigemptyset(&o);
    sigprocmask(SIG_BLOCK, (const sigset_t *)0, &o);
    check(sigismember(&o, SIGUSR1) == 1, "E: and the mask from before sigsuspend is back");
    sigprocmask(SIG_UNBLOCK, &s, (sigset_t *)0);

    /* F: perror */
    st = run_child(c_perror, out, sizeof out);
    check(exited(st, 0) && strcmp(out, "prog: No such file or directory\nInvalid argument\n") == 0, "F: perror writes the message with and without a prefix");
    errno = ERANGE;
    int saved = errno;
    perror("");
    check(errno == saved, "F: perror leaves errno alone");

    /* G: remove, rename, isatty, ids */
    unlink("/tmp/h226_a"); unlink("/tmp/h226_b"); rmdir("/tmp/h226_d");
    FILE *f = fopen("/tmp/h226_a", "w");
    fputs("alpha", f); fclose(f);
    check(rename("/tmp/h226_a", "/tmp/h226_b") == 0, "G: rename a file");
    errno = 0;
    check(rename("/tmp/h226_a", "/tmp/h226_c") == -1 && errno == ENOENT, "G: renaming a missing file is ENOENT");
    f = fopen("/tmp/h226_a", "w"); fputs("beta", f); fclose(f);
    check(rename("/tmp/h226_a", "/tmp/h226_b") == 0, "G: rename over an existing file replaces it");
    f = fopen("/tmp/h226_b", "r");
    char b[16] = { 0 };
    fread(b, 1, 15, f); fclose(f);
    check(strcmp(b, "beta") == 0, "G: and the content is the source's");
    check(remove("/tmp/h226_b") == 0, "G: remove deletes a file");
    errno = 0;
    check(remove("/tmp/h226_b") == -1 && errno == ENOENT, "G: removing it again is ENOENT");
    mkdir("/tmp/h226_d", 0777);
    check(remove("/tmp/h226_d") == 0, "G: remove deletes an empty directory");
    mkdir("/tmp/h226_d", 0777);
    f = fopen("/tmp/h226_d/x", "w"); fclose(f);
    errno = 0;
    check(remove("/tmp/h226_d") == -1 && errno == ENOTEMPTY, "G: a directory that is not empty is ENOTEMPTY");
    unlink("/tmp/h226_d/x"); rmdir("/tmp/h226_d");
    int pp[2];
    pipe(pp);
    errno = 0;
    check(isatty(pp[0]) == 0 && errno == ENOTTY, "G: a pipe is not a terminal (ENOTTY)");
    errno = 0;
    check(isatty(999) == 0 && errno == EBADF, "G: a bad descriptor is EBADF");
    check(getuid() == geteuid() && getgid() == getegid(), "G: real and effective ids agree");
    check(getppid() > 0, "G: getppid names a parent");

    /* H: setbuf family, fgetpos/fsetpos, freopen and tmpfile on the real kernel */
    {
        unlink("/tmp/h226_s");
        FILE *sf = fopen("/tmp/h226_s", "w");
        setbuf(sf, (char *)0);
        fputs("abc", sf);
        long fd = open("/tmp/h226_s", O_RDONLY, 0);
        char rb[8] = { 0 };
        long got = read((int)fd, rb, 7);
        close((int)fd);
        check(got == 3, "H: setbuf(f, NULL) makes the stream unbuffered (the data is in the file at once)");
        fclose(sf);

        sf = fopen("/tmp/h226_s", "w+");
        fputs("0123456789", sf);
        rewind(sf);
        char c3[4] = { 0 };
        fread(c3, 1, 3, sf);
        fpos_t pos;
        check(fgetpos(sf, &pos) == 0, "H: fgetpos works");
        fread(c3, 1, 3, sf);
        check(fsetpos(sf, &pos) == 0 && fgetc(sf) == '3', "H: fsetpos returns to the saved position");
        fclose(sf);

        sf = fopen("/tmp/h226_s", "r");
        int fd0 = fileno(sf);
        FILE *rf = freopen("/tmp/h226_s2", "w", sf);
        check(rf == sf && fileno(rf) == fd0, "H: freopen keeps the stream object and the descriptor number");
        fputs("zz", rf);
        fclose(rf);
        sf = fopen("/tmp/h226_s2", "r");
        char zb[4] = { 0 };
        check(fread(zb, 1, 3, sf) == 2 && zb[0] == 'z', "H: and the new file got the data");
        fclose(sf);
        errno = 0;
        sf = fopen("/tmp/h226_s2", "r");
        check(freopen("/tmp/nonexistent/x", "r", sf) == (FILE *)0 && errno == ENOENT, "H: freopen of a missing file fails with ENOENT");
        unlink("/tmp/h226_s"); unlink("/tmp/h226_s2");

        FILE *tf = tmpfile();
        check(tf != (FILE *)0, "H: tmpfile creates a stream");
        if (tf) {
            fputs("scratch", tf);
            rewind(tf);
            char tb[16] = { 0 };
            check(fread(tb, 1, 15, tf) == 7 && strcmp(tb, "scratch") == 0, "H: and it reads back what was written");
            fclose(tf);
        }
    }

    /* I: directory streams on the real kernel (tmpfs) */
    {
        mkdir("/tmp/h226_dir", 0777);
        close((int)open("/tmp/h226_dir/a", O_WRONLY | O_CREAT, 0644));
        close((int)open("/tmp/h226_dir/b", O_WRONLY | O_CREAT, 0644));
        mkdir("/tmp/h226_dir/sub", 0777);
        DIR *dd = opendir("/tmp/h226_dir");
        check(dd != (DIR *)0, "I: opendir on a directory");
        int seen_a = 0, seen_b = 0, seen_sub = 0, seen_dot = 0, count = 0, dir_ok = 1;
        if (dd) {
            struct dirent *de;
            while ((de = readdir(dd)) != (struct dirent *)0) {
                count++;
                if (strcmp(de->d_name, "a") == 0) { seen_a = 1; dir_ok &= de->d_type == DT_REG; }
                if (strcmp(de->d_name, "b") == 0) { seen_b = 1; dir_ok &= de->d_type == DT_REG; }
                if (strcmp(de->d_name, "sub") == 0) { seen_sub = 1; dir_ok &= de->d_type == DT_DIR; }
                if (strcmp(de->d_name, ".") == 0) seen_dot = 1;
            }
            check(seen_a && seen_b && seen_sub, "I: readdir lists the three entries");
            check(dir_ok, "I: with the right d_type (DT_REG for files, DT_DIR for the subdirectory)");
            check(count >= 3 && count <= 5, "I: and nothing else besides the dot entries");
            (void)seen_dot;
            rewinddir(dd);
            int again = 0;
            while (readdir(dd)) again++;
            check(again == count, "I: rewinddir lists the same entries again");
            check(dirfd(dd) > 2, "I: dirfd names a descriptor");
            check(closedir(dd) == 0, "I: closedir succeeds");
        }
        errno = 0;
        check(opendir("/tmp/h226_dir/a") == (DIR *)0 && errno == ENOTDIR, "I: opendir on a file is ENOTDIR");
        errno = 0;
        check(opendir("/tmp/h226_nonexistent") == (DIR *)0 && errno == ENOENT, "I: opendir on a missing path is ENOENT");
        unlink("/tmp/h226_dir/a"); unlink("/tmp/h226_dir/b"); rmdir("/tmp/h226_dir/sub"); rmdir("/tmp/h226_dir");
    }

    print(failures == 0 ? "hello226: PASS\n" : "hello226: FAIL\n");
    return failures;
}
