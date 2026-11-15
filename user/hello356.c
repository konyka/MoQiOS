/* hello356: read() on a shared POSIX mq description moves its offset atomically (Linux mqueue files are S_IFREG, so a shared
 * description takes f_pos_lock in fdget_pos). Measured on the host (build with -DHOST):
 *   A. a parent and a forked child reading one shared mq descriptor one byte at a time consume each byte of the status line
 *      exactly once, over 200 rounds;
 *   B. lseek(fd, 0, SEEK_CUR) after each round is the length of the status line;
 *   C. a private second open of the same queue keeps its own offset: the shared readers leave it at 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rd(int fd, void *b, long n) { return read(fd, b, (size_t)n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, (size_t)n); }
#endif
#define NAME "/hello356"
#define ROUNDS 200

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello356:   ok   " : "hello356:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int full(int fd, void *b, long n, int w) {
    char *p = b;
    while (n > 0) {
        long r = w ? wr(fd, p, n) : rd(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}
static long fork_together(void) {
    int ready[2], go[2];
    if (pipe(ready) != 0) return -1;
    if (pipe(go) != 0) return -1;
    long child = fork();
    char c = 0;
    if (child == 0) {
        wr(ready[1], &c, 1);
        rd(go[0], &c, 1);
    } else {
        rd(ready[0], &c, 1);
        wr(go[1], &c, 1);
    }
    close(ready[0]); close(ready[1]); close(go[0]); close(go[1]);
    return child;
}
static long mq_open4(const char *n, long flags) {
#ifdef HOST
    mqd_t q = mq_open(n, (int)flags, 0600, 0);
    return q < 0 ? -errno : q;
#else
    return syscall4(186, (long)n, flags, 0600, 0);
#endif
}
static long mq_unlink1(const char *n) {
#ifdef HOST
    return mq_unlink(n) < 0 ? -errno : 0;
#else
    return syscall1(187, (long)n);
#endif
}

int main(void) {
    print("hello356: read on a shared mq description moves its offset atomically\n");
    mq_unlink1(NAME);
    long q = mq_open4(NAME, 2 | 0x40);
    snprintf(msg, sizeof msg, "open %s (fd %ld)", NAME, q);
    check(q >= 0, msg);
    if (q < 0) { print("hello356: FAIL\n"); return 1; }
    long priv = mq_open4(NAME, 2);
    check(priv >= 0, "a second open is a private description");

    char line[128];
    lseek((int)q, 0, 0);
    long n = rd((int)q, line, sizeof line - 1);
    check(n > 0 && n < (long)sizeof line, "the status line fits one read");
    if (n <= 0) { print("hello356: FAIL\n"); return 1; }
    line[n] = 0;
    snprintf(msg, sizeof msg, "status line is %ld bytes", n);
    check(1, msg);

    int bad_rounds = 0, short_rounds = 0, pos_bad = 0;
    for (int k = 0; k < ROUNDS; k++) {
        lseek((int)q, 0, 0);
        int p[2];
        if (pipe(p) != 0) { bad_rounds++; continue; }
        long child = fork_together();
        if (child == 0) {
            close(p[0]);
            char b[128];
            int got = 0;
            while (got < (int)sizeof b) {
                long r = rd((int)q, b + got, 1);
                if (r != 1) break;
                got++;
            }
            full(p[1], &got, sizeof got, 1);
            full(p[1], b, got, 1);
            _exit(0);
        }
        close(p[1]);
        char mine[128];
        int mine_n = 0;
        while (mine_n < (int)sizeof mine) {
            long r = rd((int)q, mine + mine_n, 1);
            if (r != 1) break;
            mine_n++;
        }
        int got = -1;
        char theirs[128];
        if (full(p[0], &got, sizeof got, 0) != 0 || got < 0 || got > (int)sizeof theirs || full(p[0], theirs, got, 0) != 0) {
            bad_rounds++;
            close(p[0]);
            int ws = 0; waitpid(child, &ws, 0);
            continue;
        }
        close(p[0]);
        int ws = 0; waitpid(child, &ws, 0);
        long end = lseek((int)q, 0, 1);
        if (end != n) pos_bad++;
        if (mine_n + got != n) { short_rounds++; continue; }
        char seen[128];
        memset(seen, 0, sizeof seen);
        int clash = 0;
        for (int i = 0; i < mine_n; i++) {
            int okb = 0;
            for (int j = 0; j < n; j++) if (!seen[j] && mine[i] == line[j]) { seen[j] = 1; okb = 1; break; }
            if (!okb) clash++;
        }
        for (int i = 0; i < got; i++) {
            int okb = 0;
            for (int j = 0; j < n; j++) if (!seen[j] && theirs[i] == line[j]) { seen[j] = 1; okb = 1; break; }
            if (!okb) clash++;
        }
        if (clash) bad_rounds++;
    }
    snprintf(msg, sizeof msg, "A: both readers together consume each byte of the status line once (%d bad, %d short of %d rounds)",
             bad_rounds, short_rounds, ROUNDS);
    check(bad_rounds == 0 && short_rounds == 0, msg);
    snprintf(msg, sizeof msg, "B: the shared offset ends at the line length after every round (%d off)", pos_bad);
    check(pos_bad == 0, msg);

    long priv_pos = lseek((int)priv, 0, 1);
    snprintf(msg, sizeof msg, "C: a second open keeps its own offset (%ld, want 0)", priv_pos);
    check(priv_pos == 0, msg);

    close((int)q);
    close((int)priv);
    mq_unlink1(NAME);
    print(failures ? "hello356: FAIL\n" : "hello356: PASS\n");
    return failures ? 1 : 0;
}
