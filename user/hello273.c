/* hello273: one process holds more than 64 descriptors at once. Linux's default soft RLIMIT_NOFILE is far higher; this kernel's
 * descriptor table was 64 entries, so the 62nd pipe end failed with EMFILE. 100 descriptors are opened here (pipes and tmpfs files), each is
 * used, the soft limit reported by getrlimit is at least 100, /proc/self/status FDSize covers them, and dup2 to fd 120 works. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/resource.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello273:   ok   " : "hello273:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello273: more than 64 descriptors in one process\n");
    char what[160];
    struct rlimit rl;
    check(getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur >= 100, "getrlimit(RLIMIT_NOFILE) soft limit is at least 100");
    static int fds[100];
    int opened = 0;
    for (int i = 0; i < 50; i++) {
        int p[2];
        if (pipe2(p, 0) != 0) break;
        fds[opened++] = p[0];
        fds[opened++] = p[1];
    }
    snprintf(what, sizeof what, "100 descriptors (50 pipes) can be open at once (got %d, errno %d)", opened, errno);
    check(opened == 100, what);
    int hi = 0, works = 0;
    for (int i = 0; i + 1 < opened; i += 2) {
        if (fds[i + 1] > hi) hi = fds[i + 1];
        char c = (char)('a' + i % 26), g = 0;
        if (write(fds[i + 1], &c, 1) == 1 && read(fds[i], &g, 1) == 1 && g == c) works++;
    }
    snprintf(what, sizeof what, "every pipe carries its byte (%d of %d), highest descriptor %d", works, opened / 2, hi);
    check(opened == 100 && works == 50, what);
    char st[2048];
    int sf = open("/proc/self/status", O_RDONLY, 0);
    long n = sf >= 0 ? read(sf, st, sizeof st - 1) : -1;
    if (sf >= 0) close(sf);
    long fdsize = 0;
    if (n > 0) {
        st[n] = 0;
        char *p = strstr(st, "FDSize:");
        if (p) { p += 7; while (*p == ' ' || *p == '\t') p++; while (*p >= '0' && *p <= '9') fdsize = fdsize * 10 + (*p++ - '0'); }
    }
    snprintf(what, sizeof what, "/proc/self/status FDSize covers the highest open descriptor (FDSize %ld, highest %d)", fdsize, hi);
    check(fdsize > hi, what);
    int d = dup2(fds[0], 120);
    snprintf(what, sizeof what, "dup2 to descriptor 120 works (got %d)", d);
    check(d == 120, what);
    if (d == 120) close(120);
    for (int i = 0; i < opened; i++) close(fds[i]);
    print(failures == 0 ? "hello273: PASS\n" : "hello273: FAIL\n");
    return failures;
}
