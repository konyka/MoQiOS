/* hello266: simultaneous O_APPEND writers (the hello227 B17 flake at SMP=8 left "xx\n\ny\n" where "x\nx\ny\n" was written). On Linux an O_APPEND write is
 * atomic with respect to other appenders: each write() lands whole at the current end. This probe forks several children that each append a 2-byte line
 * with ONE write, many times, to the same file on tmpfs, and then checks that the file is exactly the lines and nothing else (no byte was lost and no line was
 * split). Run with the shell's two-write echo pattern as a second variant to see whether the interleaving comes from the shell or the filesystem. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/time.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello266:   ok   " : "hello266:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

#define KIDS 4
#define LINES 50

static int run(const char *path, int two_writes) {
    unlink(path);
    int creat_fd = (int)open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    close(creat_fd);
    long pids[KIDS];
    for (int k = 0; k < KIDS; k++) {
        long p = fork();
        if (p == 0) {
            int fd = (int)open(path, O_WRONLY | O_APPEND, 0644);
            for (int i = 0; i < LINES; i++) {
                if (two_writes) {
                    write(fd, "x", 1);
                    write(fd, "\n", 1);
                } else {
                    write(fd, "x\n", 2);
                }
            }
            _exit(0);
        }
        pids[k] = p;
    }
    for (int k = 0; k < KIDS; k++) {
        int st;
        waitpid(pids[k], &st, 0);
    }
    static char got[2 * KIDS * LINES + 64];
    int fd = (int)open(path, O_RDONLY, 0);
    long n = read(fd, got, sizeof got - 1);
    close(fd);
    if (n < 0) n = 0;
    got[n] = 0;
    /* Every byte must be there, and with single writes every line must be intact "x\n". */
    int lines_ok = 1;
    for (long i = 0; i + 1 < n; i += 2)
        if (got[i] != 'x' || got[i + 1] != '\n') { lines_ok = 0; break; }
    if (two_writes) return n == 2 * KIDS * LINES ? 1 : 0;
    return n == 2 * KIDS * LINES && lines_ok;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello266: simultaneous O_APPEND writers\n");
    char what[160];
    int single_bad = 0, two_bad = 0;
    for (int round = 0; round < 20; round++) {
        if (!run("/tmp/h266_a", 0)) single_bad++;
        if (!run("/tmp/h266_b", 1)) two_bad++;
    }
    snprintf(what, sizeof what, "A: four writers each appending 50 two-byte lines with one write: the file is exactly the 400 bytes, every line whole (%d of 20 rounds wrong)", single_bad);
    check(single_bad == 0, what);
    snprintf(what, sizeof what, "B: the same with two writes per line loses no bytes (%d of 20 rounds wrong)", two_bad);
    check(two_bad == 0, what);
    print(failures == 0 ? "hello266: PASS\n" : "hello266: FAIL\n");
    return failures;
}
