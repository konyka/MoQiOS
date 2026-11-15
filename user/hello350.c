/* hello350: read() and write() on a shared open file description move its offset atomically (Linux fdget_pos takes f_pos_lock
 * for a regular file shared between tasks). Measured on the host (build with -DHOST):
 *   A. a parent and a forked child reading one shared description 4 bytes at a time consume each 4-byte record exactly once,
 *      over 6 rounds of 2048 records;
 *   B. a parent and a forked child each writing 1024 tagged 4-byte records through one shared description leave 2048 records
 *      (8192 bytes), none overwritten, over 6 rounds;
 *   C. lseek(fd, 0, SEEK_CUR) after round A is the file size. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long opn(const char *p, long fl) { long r = open(p, (int)fl, 0644); return r < 0 ? -errno : r; }
#define PATH "/tmp/hello350.dat"
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rd(int fd, void *b, long n) { return read(fd, b, (size_t)n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, (size_t)n); }
static long opn(const char *p, long fl) { return open(p, fl, 0644); }
#define PATH "/tmp/hello350.dat"
#endif

#define NREC 2048
#define ROUNDS 6
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello350:   ok   " : "hello350:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static unsigned char seen[NREC / 8];
static unsigned char other[NREC / 8];

/* Read records until EOF, marking each index in `seen`; returns how many reads returned a whole record. */
static int drain(int fd) {
    int n = 0;
    unsigned int v;
    for (;;) {
        long r = rd(fd, &v, 4);
        if (r != 4) break;
        n++;
        if (v < NREC) seen[v / 8] |= (unsigned char)(1u << (v % 8));
    }
    return n;
}
static int write_full(int fd, const void *b, long n) {
    const char *p = b;
    while (n > 0) {
        long w = wr(fd, p, n);
        if (w <= 0) return -1;
        p += w; n -= w;
    }
    return 0;
}
static int read_full(int fd, void *b, long n) {
    char *p = b;
    while (n > 0) {
        long r = rd(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}
static int popcnt(const unsigned char *m) {
    int c = 0;
    for (int i = 0; i < NREC / 8; i++) for (int b = 0; b < 8; b++) c += (m[i] >> b) & 1;
    return c;
}
int main(void) {
    print("hello350: read and write move a shared offset atomically\n");
    long fd = opn(PATH, 2 | 0x40 | 0x200);
    snprintf(msg, sizeof msg, "open %s (rc %ld)", PATH, fd);
    check(fd >= 0, msg);
    if (fd < 0) { print("hello350: FAIL\n"); return 1; }
    static unsigned int recs[NREC];
    for (unsigned int i = 0; i < NREC; i++) recs[i] = i;
    check(write_full((int)fd, recs, sizeof recs) == 0, "write 2048 records");

    /* A: concurrent reads through one description consume each record once. */
    int bad_rounds = 0, dup_total = 0, miss_total = 0;
    long end_pos = -1;
    for (int round = 0; round < ROUNDS; round++) {
        lseek((int)fd, 0, 0);
        memset(seen, 0, sizeof seen);
        int p[2];
        if (pipe(p) != 0) { check(0, "pipe"); break; }
        long child = fork();
        if (child == 0) {
            close(p[0]);
            int n = drain((int)fd);
            write_full(p[1], &n, sizeof n);
            write_full(p[1], seen, sizeof seen);
            _exit(0);
        }
        close(p[1]);
        int mine = drain((int)fd);
        int theirs = -1;
        if (read_full(p[0], &theirs, sizeof theirs) != 0 || read_full(p[0], other, sizeof other) != 0) theirs = -1;
        close(p[0]);
        int ws = 0;
        waitpid(child, &ws, 0);
        int dups = 0;
        for (int i = 0; i < NREC / 8; i++) for (int b = 0; b < 8; b++) dups += (seen[i] >> b) & (other[i] >> b) & 1;
        for (int i = 0; i < NREC / 8; i++) seen[i] |= other[i];
        int miss = NREC - popcnt(seen);
        if (theirs < 0 || mine + theirs != NREC || dups || miss) bad_rounds++;
        dup_total += dups;
        miss_total += miss;
        if (round == 0) end_pos = lseek((int)fd, 0, 1);
    }
    snprintf(msg, sizeof msg, "A: two readers of one description read each record once (%d of %d rounds wrong, %d read twice, %d missed)",
             bad_rounds, ROUNDS, dup_total, miss_total);
    check(bad_rounds == 0, msg);
    snprintf(msg, sizeof msg, "C: the shared offset ends at the file size (%ld, want %d)", end_pos, NREC * 4);
    check(end_pos == NREC * 4, msg);

    /* B: concurrent writes through one description never land on the same offset. */
    int wbad = 0;
    long last_size = -1;
    for (int round = 0; round < ROUNDS; round++) {
        close((int)fd);
        fd = opn(PATH, 2 | 0x40 | 0x200);
        if (fd < 0) { wbad++; break; }
        long child = fork();
        if (child == 0) {
            for (unsigned int i = 0; i < NREC / 2; i++) {
                unsigned int v = 0x10000u | i;
                if (wr((int)fd, &v, 4) != 4) _exit(1);
            }
            _exit(0);
        }
        int werr = 0;
        for (unsigned int i = 0; i < NREC / 2; i++) {
            unsigned int v = 0x20000u | i;
            if (wr((int)fd, &v, 4) != 4) werr = 1;
        }
        int ws = 0;
        waitpid(child, &ws, 0);
        last_size = lseek((int)fd, 0, 2);
        lseek((int)fd, 0, 0);
        int ones = 0, twos = 0;
        unsigned int v;
        while (rd((int)fd, &v, 4) == 4) {
            if ((v >> 16) == 1) ones++;
            else if ((v >> 16) == 2) twos++;
        }
        if (werr || last_size != NREC * 4 || ones != NREC / 2 || twos != NREC / 2) wbad++;
    }
    snprintf(msg, sizeof msg, "B: two writers of one description keep all 2048 records (%d of %d rounds wrong, last size %ld)",
             wbad, ROUNDS, last_size);
    check(wbad == 0, msg);
    close((int)fd);
    unlink(PATH);

    print(failures ? "hello350: FAIL\n" : "hello350: PASS\n");
    return failures ? 1 : 0;
}
