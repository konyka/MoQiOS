/* hello219: FILE streams in the freestanding user build, on the real kernel: fopen modes, buffered output reaching the
 * file system, line reading, block reads and writes, positioning, the standard streams, exit() flushing, and several
 * threads each using their own stream. The exact buffering and EOF/error behavior (measured on glibc) is checked on the
 * host against an in-memory file system with fault injection. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello219:   ok   " : "hello219:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long disk_size(const char *path) {
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return -1;
    long n = 0, r;
    char b[512];
    while ((r = read(fd, b, sizeof b)) > 0) n += r;
    close(fd);
    return n;
}

static char blk[10000];
static char got[10000];

static volatile int worker_bad;
static void *worker(void *arg) {
    long id = (long)arg;
    char path[32] = "/tmp/h219_t0";
    path[11] = (char)('0' + id);
    FILE *f = fopen(path, "w");
    if (!f) {
        worker_bad++;
        return (void *)0;
    }
    for (int i = 0; i < 400; i++) {
        fprintf(f, "t%ld line %d\n", id, i);
        if ((i & 31) == 0) yield();
    }
    if (fclose(f) != 0) worker_bad++;
    f = fopen(path, "r");
    if (!f) {
        worker_bad++;
        return (void *)0;
    }
    char line[64], want[64];
    for (int i = 0; i < 300; i++) {
        char tmp[32] = "/tmp/h219_c0";
        tmp[11] = (char)('0' + id);
        FILE *g = fopen(tmp, "w");
        if (!g) {
            worker_bad++;
            break;
        }
        fputs("x", g);
        if (fclose(g) != 0) worker_bad++;
        if ((i & 15) == 0) yield();
    }
    for (int i = 0; i < 400; i++) {
        snprintf(want, sizeof want, "t%ld line %d\n", id, i);
        if (!fgets(line, sizeof line, f) || strcmp(line, want) != 0) {
            worker_bad++;
            break;
        }
        if ((i & 63) == 0) yield();
    }
    if (fgets(line, sizeof line, f) != (char *)0 || !feof(f)) worker_bad++;
    fclose(f);
    unlink(path);
    return (void *)1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello219: FILE streams\n");

    mkdir("/tmp", 0777);
    unlink("/tmp/h219_a");

    /* A: buffered output is invisible until the flush, then reading it back line by line */
    FILE *f = fopen("/tmp/h219_a", "w");
    check(f != (FILE *)0, "A: fopen for writing creates the file");
    check(fputs("alpha\n", f) >= 0 && fprintf(f, "%s=%d\n", "beta", 42) == 8 && fputc('g', f) == 'g', "A: fputs, fprintf and fputc succeed");
    check(disk_size("/tmp/h219_a") == 0, "A: nothing reached the file system yet (fully buffered)");
    check(fflush(f) == 0 && disk_size("/tmp/h219_a") == 15, "A: fflush writes all 15 bytes");
    check(fclose(f) == 0, "A: fclose");
    f = fopen("/tmp/h219_a", "r");
    char line[64];
    check(f && fgets(line, sizeof line, f) && strcmp(line, "alpha\n") == 0, "A: first line reads back");
    check(f && fgets(line, sizeof line, f) && strcmp(line, "beta=42\n") == 0, "A: second line reads back");
    check(f && fgets(line, sizeof line, f) && strcmp(line, "g") == 0 && !fgets(line, sizeof line, f) && feof(f) && !ferror(f), "A: the last line has no newline, then end of file");
    check(fgetc(f) == -1 && feof(f), "A: reading past the end keeps returning EOF");
    fclose(f);

    /* B: modes and errors */
    errno = 0;
    check(fopen("/tmp/h219_missing", "r") == (FILE *)0 && errno == ENOENT, "B: fopen of a missing file for reading fails with ENOENT");
    errno = 0;
    check(fopen("/tmp/h219_a", "q") == (FILE *)0 && errno == EINVAL, "B: a bad mode fails with EINVAL");
    f = fopen("/tmp/h219_a", "a");
    check(f && ftell(f) == 15, "B: append mode starts at the end of the file");
    fputs("more", f);
    fclose(f);
    check(disk_size("/tmp/h219_a") == 19, "B: appended 4 bytes");
    f = fopen("/tmp/h219_a", "r");
    errno = 0;
    check(f && fputc('x', f) == -1 && errno == EBADF && ferror(f), "B: writing to a read-only stream fails with EBADF and sets the error flag");
    clearerr(f);
    check(!ferror(f), "B: clearerr clears it");
    fclose(f);
    f = fopen("/tmp/h219_a", "w");
    fclose(f);
    check(disk_size("/tmp/h219_a") == 0, "B: 'w' truncates");

    /* C: block writes and reads, positioning */
    for (int i = 0; i < (int)sizeof blk; i++) blk[i] = (char)('a' + (i * 7) % 26);
    f = fopen("/tmp/h219_a", "w+");
    check(f && fwrite(blk, 1, sizeof blk, f) == sizeof blk, "C: fwrite of 10000 bytes");
    check(ftell(f) == 10000, "C: ftell counts buffered bytes");
    check(fseek(f, 0, SEEK_SET) == 0 && disk_size("/tmp/h219_a") == 10000, "C: fseek flushes the output");
    memset(got, 0, sizeof got);
    check(fread(got, 1, sizeof got, f) == sizeof got && memcmp(got, blk, sizeof blk) == 0, "C: fread returns the same 10000 bytes");
    check(fread(got, 1, 1, f) == 0 && feof(f), "C: and then end of file");
    check(fseek(f, 5000, SEEK_SET) == 0 && !feof(f) && ftell(f) == 5000 && fgetc(f) == (unsigned char)blk[5000], "C: seek to 5000 clears EOF and reads the right byte");
    check(fseek(f, -10, SEEK_END) == 0 && ftell(f) == 9990 && fread(got, 1, 20, f) == 10 && memcmp(got, blk + 9990, 10) == 0, "C: seek from the end, a short read returns the 10 bytes left");
    check(fseek(f, 100, SEEK_SET) == 0 && fread(got, 4, 5, f) == 5 && ftell(f) == 120 && fseek(f, 3, SEEK_CUR) == 0 && ftell(f) == 123, "C: SEEK_CUR follows the logical position, not the read-ahead");
    check(fseek(f, 0, SEEK_SET) == 0 && fwrite("XY", 1, 2, f) == 2 && fseek(f, 0, SEEK_SET) == 0 && fgetc(f) == 'X' && fgetc(f) == 'Y' && fgetc(f) == (unsigned char)blk[2], "C: overwrite in place, then read it back");
    rewind(f);
    check(ftell(f) == 0, "C: rewind");
    fclose(f);

    /* D: ungetc and getline */
    f = fopen("/tmp/h219_a", "w");
    fputs("one\ntwo\nthree", f);
    fclose(f);
    f = fopen("/tmp/h219_a", "r");
    check(f && fgetc(f) == 'o' && ungetc('Z', f) == 'Z' && fgetc(f) == 'Z' && fgetc(f) == 'n', "D: ungetc pushes a byte back");
    char *lp = (char *)0;
    size_t cap = 0;
    long r = getline(&lp, &cap, f);
    check(r == 2 && strcmp(lp, "e\n") == 0, "D: getline returns the rest of the first line");
    r = getline(&lp, &cap, f);
    check(r == 4 && strcmp(lp, "two\n") == 0, "D: next line, newline included");
    r = getline(&lp, &cap, f);
    check(r == 5 && strcmp(lp, "three") == 0, "D: last line without a newline");
    check(getline(&lp, &cap, f) == -1 && feof(f), "D: then -1 at end of file");
    free(lp);
    fclose(f);

    /* E: exit() flushes open streams; _exit() does not */
    unlink("/tmp/h219_e1");
    unlink("/tmp/h219_e2");
    long pid = fork();
    if (pid == 0) {
        FILE *g = fopen("/tmp/h219_e1", "w");
        fputs("flushed by exit", g);
        exit(0);
    }
    int status = 0;
    check(pid > 0 && waitpid(pid, &status, 0) == pid && ((status >> 8) & 0xff) == 0, "E: child using exit() finished");
    check(disk_size("/tmp/h219_e1") == 15, "E: exit() wrote the buffered 15 bytes");
    pid = fork();
    if (pid == 0) {
        FILE *g = fopen("/tmp/h219_e2", "w");
        fputs("lost", g);
        _exit(0);
    }
    status = 0;
    check(pid > 0 && waitpid(pid, &status, 0) == pid && disk_size("/tmp/h219_e2") == 0, "E: _exit() leaves buffered bytes unwritten (as POSIX says)");
    pid = fork();
    if (pid == 0) {
        FILE *g = fopen("/tmp/h219_e2", "w");
        fputs("main returns", g);
        return 0;
    }
    status = 0;
    check(pid > 0 && waitpid(pid, &status, 0) == pid && disk_size("/tmp/h219_e2") == 12, "E: returning from main flushes too");

    /* F: standard streams: stderr is unbuffered, stdout is line buffered */
    int fds[2];
    pid = fork();
    if (pid == 0) {
        int ok = 1;
        char c[16];
        if (pipe(fds) != 0) _exit(2);
        dup2(fds[1], 2);
        fputs("e", stderr);
        ok &= read(fds[0], c, sizeof c) == 1 && c[0] == 'e';
        dup2(fds[1], 1);
        fputs("o", stdout);
        fflush(stdout);
        ok &= read(fds[0], c, sizeof c) == 1 && c[0] == 'o';
        fputs("p\nq", stdout);
        ok &= read(fds[0], c, sizeof c) == 2 && c[0] == 'p' && c[1] == '\n';
        fflush(stdout);
        ok &= read(fds[0], c, sizeof c) == 1 && c[0] == 'q';
        _exit(ok ? 0 : 1);
    }
    status = 0;
    check(pid > 0 && waitpid(pid, &status, 0) == pid && ((status >> 8) & 0xff) == 0, "F: stderr writes at once; stdout writes through the last newline and keeps the rest until the flush");

    /* G: fdopen */
    int fd = (int)open("/tmp/h219_a", O_RDWR, 0);
    f = fdopen(fd, "r+");
    check(f && fileno(f) == fd && fgetc(f) == 'o', "G: fdopen wraps an open descriptor");
    errno = 0;
    int wfd = (int)open("/tmp/h219_a", O_WRONLY, 0);
    check(fdopen(wfd, "r") == (FILE *)0 && errno == EINVAL, "G: a mode that the descriptor does not allow is rejected with EINVAL");
    close(wfd);
    fclose(f);

    /* H: threads, each with its own stream */
    pthread_t t[4];
    int created = 0;
    for (long i = 0; i < 4; i++) {
        int tries = 0;
        while (pthread_create(&t[i], (void *)0, worker, (void *)i) != 0 && tries++ < 1000) yield();
        if (tries < 1000) created++;
    }
    long ok_workers = 0;
    for (int i = 0; i < created; i++) {
        void *rv = (void *)0;
        pthread_join(t[i], &rv);
        ok_workers += (long)rv;
    }
    check(created == 4 && ok_workers == 4 && worker_bad == 0, "H: four threads writing and re-reading their own files saw no wrong line");

    check(fflush((FILE *)0) == 0, "H: fflush(NULL) walks the list of open streams and returns (it was left intact by the concurrent fopen/fclose)");
    pid = fork();
    if (pid == 0) {
        FILE *g = fopen("/tmp/h219_e2", "w");
        fputs("after threads", g);
        exit(0);
    }
    status = 0;
    check(pid > 0 && waitpid(pid, &status, 0) == pid && disk_size("/tmp/h219_e2") == 13, "H: exit() after the churn still flushes and terminates");
    for (int i = 0; i < 4; i++) {
        char tmp[32] = "/tmp/h219_c0";
        tmp[11] = (char)('0' + i);
        unlink(tmp);
    }

    unlink("/tmp/h219_a");
    unlink("/tmp/h219_e1");
    unlink("/tmp/h219_e2");
    print(failures == 0 ? "hello219: PASS\n" : "hello219: FAIL\n");
    return failures;
}
