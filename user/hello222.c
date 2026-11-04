/* hello222: the current directory is shared by every thread of a process, and one thread's chdir() can run while another's
 * getcwd() or a relative open() reads it. The path is up to 255 bytes, copied in several steps, so without mutual exclusion a
 * reader can see half of the old path and half of the new one. Two directories whose absolute paths have the same length and
 * differ in every byte make such a mixture visible: a reader must only ever see one complete path or the other. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"
#include "../lib/moqi_libc/include/time.h"

#define O_RDONLY_ 0

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello222:   ok   " : "hello222:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static char dir_a[256], dir_b[256];
static volatile int stop;
static volatile long torn_getcwd, torn_open, chdirs_done, reads_done, opens_done, chdir_errors;

static void make_dir_path(char *out, char letter) {
    strcpy(out, "/tmp/h222");
    size_t n = strlen(out);
    for (int level = 0; level < 3; level++) {
        out[n++] = '/';
        for (int i = 0; i < 55; i++) out[n++] = letter;
    }
    out[n] = 0;
}

static int make_tree(const char *path) {
    char part[256];
    size_t n = strlen(path);
    for (size_t i = 1; i <= n; i++) {
        if (path[i] == '/' || path[i] == 0) {
            memcpy(part, path, i);
            part[i] = 0;
            long r = mkdir(part, 0777);
            if (r != 0 && r != -EEXIST) return -1;
        }
    }
    return 0;
}

static void *flipper(void *arg) {
    (void)arg;
    long n = 0;
    while (!stop) {
        if (chdir((n & 1) ? dir_a : dir_b) != 0) chdir_errors++;
        n++;
    }
    chdirs_done = n;
    return (void *)0;
}

static void *getcwd_reader(void *arg) {
    (void)arg;
    char buf[300];
    long n = 0, torn = 0;
    size_t want = strlen(dir_a);
    while (!stop) {
        long r = getcwd(buf, sizeof buf);
        if (r > 0) {
            if (strlen(buf) != want || (strcmp(buf, dir_a) != 0 && strcmp(buf, dir_b) != 0)) torn++;
        }
        n++;
    }
    torn_getcwd += torn;
    reads_done += n;
    return (void *)0;
}

/* A relative open() joins the name onto the current directory: a torn directory makes it fail with ENOENT or open a
 * file in a directory that was never current. Each directory holds a file with its own letter as the name's content. */
static void *open_reader(void *arg) {
    (void)arg;
    long n = 0, torn = 0;
    while (!stop) {
        int fd = (int)open("marker", O_RDONLY_, 0);
        if (fd < 0) {
            torn++;
        } else {
            char c = 0;
            long r = read(fd, &c, 1);
            if (r != 1 || (c != 'a' && c != 'b')) torn++;
            close(fd);
        }
        n++;
    }
    torn_open += torn;
    opens_done += n;
    return (void *)0;
}

static int write_marker(const char *dir, char letter) {
    char path[300];
    strcpy(path, dir);
    strcat(path, "/marker");
    int fd = (int)open(path, O_CREAT | O_WRONLY | O_TRUNC, 0666);
    if (fd < 0) return -1;
    long r = write(fd, &letter, 1);
    close(fd);
    return r == 1 ? 0 : -1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello222: current directory shared by threads\n");

    make_dir_path(dir_a, 'a');
    make_dir_path(dir_b, 'b');
    mkdir("/tmp", 0777);
    check(make_tree(dir_a) == 0 && make_tree(dir_b) == 0, "A: two directories with 182-byte paths that differ in every byte after /tmp/h222/");
    check(write_marker(dir_a, 'a') == 0 && write_marker(dir_b, 'b') == 0, "A: each holds a file named marker with its own letter");
    check(chdir(dir_a) == 0, "A: chdir to the first one");
    char buf[300];
    check(getcwd(buf, sizeof buf) > 0 && strcmp(buf, dir_a) == 0, "A: and getcwd returns exactly that path");
    check(chdir(dir_b) == 0 && getcwd(buf, sizeof buf) > 0 && strcmp(buf, dir_b) == 0, "A: then the second");
    check(chdir(dir_a) == 0, "A: back to the first, in which the relative open of marker finds an a");

    pthread_t t[5];
    int created = 0;
    void *(*fns[5])(void *) = { flipper, getcwd_reader, getcwd_reader, open_reader, open_reader };
    for (int i = 0; i < 5; i++) {
        int tries = 0;
        while (pthread_create(&t[i], (void *)0, fns[i], (void *)0) != 0 && tries++ < 1000) yield();
        if (tries < 1000) created++;
    }
    /* run for a fixed number of scheduler rounds of the main thread, not wall-clock time, so the load is similar everywhere */
    for (int i = 0; i < 400; i++) {
        yield();
        usleep(5000);
    }
    stop = 1;
    for (int i = 0; i < created; i++) {
        void *rv;
        pthread_join(t[i], &rv);
    }
    check(created == 5, "B: one thread flipping the directory and four readers ran");
    check(chdirs_done > 1000 && reads_done > 1000 && opens_done > 1000 && chdir_errors == 0, "B: and did a good number of operations each, with no chdir failing");
    check(torn_getcwd == 0, "B: getcwd never returned a path that was half one directory and half the other");
    check(torn_open == 0, "B: a relative open never failed or opened a file from a directory that was not current");

    char line[160];
    snprintf(line, sizeof line, "hello222:   .. chdirs %ld, getcwd calls %ld (torn %ld), relative opens %ld (torn %ld)\n", chdirs_done, reads_done,
             torn_getcwd, opens_done, torn_open);
    print(line);

    print(failures == 0 ? "hello222: PASS\n" : "hello222: FAIL\n");
    return failures;
}
