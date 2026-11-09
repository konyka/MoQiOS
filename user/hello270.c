/* hello270: the cost of the global append lock. Four processes each write 200 records of 4 KiB to their OWN file, once with O_APPEND and once
 * without, on tmpfs, FAT32 and ext2. The files are different, so on Linux the two runs take about as long; here every O_APPEND write takes one
 * lock per file, so writers to different files must not wait for each other: the O_APPEND run may take at most 3x (plus 300 ms) the plain one.
 * (Before the locks were per file, O_APPEND took 15x to 58x longer here.) The per-call lock only matters while a write sleeps, which tmpfs
 * writes never do, so the tmpfs line is a measurement, not a guard: with every file forced onto one stripe tmpfs still passed. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/time.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello270:   ok   " : "hello270:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

#define KIDS 4
#define RECS 200
#define REC 4096

static long now_ms(void) {
    struct timespec t;
    clock_gettime(1, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static long run(const char *prefix, int append) {
    char path[KIDS][48];
    for (int k = 0; k < KIDS; k++) {
        snprintf(path[k], sizeof path[k], "%s%d", prefix, k);
        unlink(path[k]);
        int c = (int)open(path[k], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        close(c);
    }
    long t0 = now_ms();
    long pids[KIDS];
    for (int k = 0; k < KIDS; k++) {
        long p = fork();
        if (p == 0) {
            static char rec[REC];
            memset(rec, 'a' + k, sizeof rec);
            int fd = (int)open(path[k], O_WRONLY | (append ? O_APPEND : 0), 0644);
            for (int i = 0; i < RECS; i++) write(fd, rec, REC);
            close(fd);
            _exit(0);
        }
        pids[k] = p;
    }
    for (int k = 0; k < KIDS; k++) {
        int st;
        waitpid(pids[k], &st, 0);
    }
    long dt = now_ms() - t0;
    int ok = 1;
    for (int k = 0; k < KIDS; k++) {
        int fd = (int)open(path[k], O_RDONLY, 0);
        long sz = lseek(fd, 0, SEEK_END);
        close(fd);
        if (sz != (long)RECS * REC) ok = 0;
        unlink(path[k]);
    }
    return ok ? dt : -1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello270: cost of the global O_APPEND lock (four writers, four different files)\n");
    static const struct { const char *label, *prefix; } fs[3] = { { "tmpfs", "/tmp/h270_" }, { "FAT32", "h270" }, { "ext2", "testdir/h270_" } };
    char what[200];
    for (int f = 0; f < 3; f++) {
        long plain = run(fs[f].prefix, 0);
        long app = run(fs[f].prefix, 1);
        snprintf(what, sizeof what, "%s: four writers, %d x %d bytes each to their own file: plain %ld ms, O_APPEND %ld ms", fs[f].label, RECS, REC, plain, app);
        check(plain >= 0 && app >= 0, what);
        snprintf(what, sizeof what, "%s: writers to different files do not wait for each other (O_APPEND %ld ms <= 3 x plain %ld ms + 300)", fs[f].label, app, plain);
        check(plain >= 0 && app >= 0 && app <= 3 * plain + 300, what);
    }
    print(failures == 0 ? "hello270: PASS\n" : "hello270: FAIL\n");
    return failures;
}
