/* hello501: writing /proc/<pid>/comm renames the task (Linux comm_write): at most 15 bytes are taken into a zeroed name, the write
 * returns the whole count; the writer must be in the target's thread group, else EINVAL. A: own comm via /proc/self; B: a long name
 * is cut to 15 bytes and the write still returns its full length; C: writing a child's comm is EINVAL and leaves its name.
 * Measured with -DHOST. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long read_(long fd, void *b, int n) { return rc(read((int)fd, b, (size_t)n)); }
static long write_(long fd, const void *b, int n) { return rc(write((int)fd, b, (size_t)n)); }
static void close_(long s) { close((int)s); }
static long getname(char *b) { return rc(prctl(PR_GET_NAME, b, 0, 0, 0)); }
static long fork_(void) { return fork(); }
static void exit_(int c) { _exit(c); }
static void wait_(long pid) { int st; waitpid((pid_t)pid, &st, 0); }
static void nap(void) { usleep(20000); }
static long getpid_(void) { return getpid(); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr, 0); }
static long read_(long fd, void *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const void *b, int n) { return syscall3(1, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
static long getname(char *b) { return syscall5(241, 16, (long)b, 0, 0, 0); }
static long fork_(void) { return syscall0(57); }
static void exit_(int c) { syscall1(2, c); }
static void wait_(long pid) { int st = 0; syscall3(6, pid, (long)&st, 0); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall2(35, (long)t, 0); }
static long getpid_(void) { return syscall0(SYS_getpid); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello501:   ok   " : "hello501:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long write_file(const char *path, const char *s) {
    long fd = open_(path, 1);
    if (fd < 0) return fd;
    long r = write_(fd, s, (int)strlen(s));
    close_(fd);
    return r;
}
static long read_file(const char *path, char *out, int cap) {
    long fd = open_(path, 0);
    if (fd < 0) return fd;
    long n = read_(fd, out, cap - 1);
    close_(fd);
    if (n >= 0) out[n] = 0;
    return n;
}
int main(void) {
    print("hello501: writing /proc/<pid>/comm renames the task\n");
    char name[32] = { 0 }, text[64] = { 0 };
    long w = write_file("/proc/self/comm", "renamed501");
    long g = getname(name);
    long r = read_file("/proc/self/comm", text, sizeof text);
    snprintf(msg, sizeof msg, "A: write %ld, PR_GET_NAME %ld '%s', comm %ld '%s' (10 0 renamed501 11)", w, g, name, r, text);
    check(w == 10 && g == 0 && strcmp(name, "renamed501") == 0 && r == 11 && strcmp(text, "renamed501\n") == 0, msg);
    memset(name, 0, sizeof name);
    w = write_file("/proc/self/comm", "abcdefghijklmnopqrstuvwxyz");
    g = getname(name);
    snprintf(msg, sizeof msg, "B: long write %ld, name '%s' (26 abcdefghijklmno)", w, name);
    check(w == 26 && g == 0 && strcmp(name, "abcdefghijklmno") == 0, msg);
    long child = fork_();
    if (child == 0) {
        for (int i = 0; i < 100; i++) nap();
        exit_(0);
    }
    char path[48];
    snprintf(path, sizeof path, "/proc/%ld/comm", child);
    long cw = write_file(path, "other");
    char ctext[64] = { 0 };
    long cr = read_file(path, ctext, sizeof ctext);
    snprintf(msg, sizeof msg, "C: child %ld comm write %ld, still '%s' (>0 -22 abcdefghijklmno)", child, cw, ctext);
    check(child > 0 && cw == -22 && cr > 0 && strcmp(ctext, "abcdefghijklmno\n") == 0, msg);
    (void)getpid_;
    wait_(child);
    print(failures ? "hello501: FAIL\n" : "hello501: PASS\n");
    return failures ? 1 : 0;
}
