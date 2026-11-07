/* hello258: the process name (comm). Measured on Linux: a program's name is its file name cut to 15 bytes (not argv[0]), exec resets it;
 * PR_SET_NAME stores at most 15 bytes and zero-fills the rest of the 16 (a shorter name leaves nothing of the old one behind), the empty
 * name is allowed and a bad pointer is EFAULT; a fork inherits it; /proc/<pid>/comm is the name plus a newline, /proc/<pid>/status starts
 * "Name:\t<name>" and /proc/<pid>/stat has "(<name>)" as its second field. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/dirent.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

#define SYS_PRCTL 241
#define PR_SET_NAME 15
#define PR_GET_NAME 16

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello258:   ok   " : "hello258:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long set_name(const void *p) { return syscall2(SYS_PRCTL, PR_SET_NAME, (long)p); }
static long get_name(char out[16]) {
    memset(out, 0x55, 16);
    return syscall2(SYS_PRCTL, PR_GET_NAME, (long)out);
}

/* Whether the 16 bytes are `text` followed only by zeros. */
static int name_is(const char *text) {
    char b[16];
    if (get_name(b) != 0) return 0;
    char want[16];
    memset(want, 0, 16);
    memcpy(want, text, strlen(text));
    return memcmp(b, want, 16) == 0;
}

static int read_file(const char *path, char *out, size_t cap) {
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return -1;
    long n = read(fd, out, cap - 1);
    close(fd);
    out[n > 0 ? n : 0] = 0;
    return (int)n;
}

static void *thread_main(void *arg) {
    char *out = (char *)arg;
    get_name(out);
    return (void *)0;
}

int main(int argc, char **argv, char **envp) {
    (void)envp;
    if (argc >= 3 && strcmp(argv[1], "--child") == 0) {
        char b[16];
        get_name(b);
        write(atoi(argv[2]), b, 16);
        return 0;
    }

    print("hello258: process name\n");
    char what[240];
    char text[512];

    check(name_is("hello258"), "a program starts with its file name as its name");

    set_name("abcdefghij");
    check(name_is("abcdefghij"), "PR_SET_NAME stores the name, zero-padded");
    set_name("xy");
    check(name_is("xy"), "a shorter name leaves nothing of the previous one behind");
    set_name("abcdefghijklmnopqrstuvwxyz");
    check(name_is("abcdefghijklmno"), "a name over 15 bytes is cut to 15, with a NUL at the end");
    set_name("");
    check(name_is(""), "the empty name is allowed and clears every byte");

    set_name("keep");
    long bad = set_name((const void *)1);
    snprintf(what, sizeof what, "a bad pointer is EFAULT (returned %ld)", bad);
    check(bad == -EFAULT, what);
    check(name_is("keep"), "and the name is unchanged by the failed call");
    char sink[16];
    long badget = syscall2(SYS_PRCTL, PR_GET_NAME, 1);
    snprintf(what, sizeof what, "PR_GET_NAME into a bad pointer is EFAULT (returned %ld)", badget);
    check(badget == -EFAULT, what);
    (void)sink;

    int n = read_file("/proc/self/comm", text, sizeof text);
    snprintf(what, sizeof what, "/proc/self/comm is the name and a newline (read %d: \"%s\")", n, text);
    check(n == 5 && strcmp(text, "keep\n") == 0, what);

    n = read_file("/proc/self/status", text, sizeof text);
    snprintf(what, sizeof what, "/proc/self/status starts \"Name:\\tkeep\" (read %d)", n);
    check(n > 0 && strncmp(text, "Name:\tkeep\n", 11) == 0, what);

    n = read_file("/proc/self/stat", text, sizeof text);
    char want[48];
    snprintf(want, sizeof want, "%ld (keep) ", (long)getpid());
    snprintf(what, sizeof what, "/proc/self/stat's second field is (keep) (read %d)", n);
    check(n > 0 && strncmp(text, want, strlen(want)) == 0, what);

    DIR *d = opendir("/proc/self");
    int comm = 0;
    if (d != (DIR *)0) {
        struct dirent *e;
        while ((e = readdir(d)) != (struct dirent *)0) if (strcmp(e->d_name, "comm") == 0) comm = 1;
        closedir(d);
    }
    check(comm == 1, "/proc/self lists comm");

    /* A fork inherits the name; the child's own change is its own. */
    int up[2], down[2];
    pipe(up);
    pipe(down);
    long kid = fork();
    if (kid == 0) {
        char inherited = name_is("keep") ? 1 : 0;
        set_name("childname");
        write(up[1], &inherited, 1);
        char go;
        read(down[0], &go, 1);
        _exit(0);
    }
    char inherited = 0;
    read(up[0], &inherited, 1);
    check(inherited == 1, "a forked child starts with the parent's name");
    char path[48];
    snprintf(path, sizeof path, "/proc/%ld/comm", kid);
    n = read_file(path, text, sizeof text);
    snprintf(what, sizeof what, "the parent reads the child's changed name from /proc/<pid>/comm (\"%s\")", text);
    check(n == 10 && strcmp(text, "childname\n") == 0, what);
    check(name_is("keep"), "and the parent's own name is untouched by the child's change");
    char go = 1;
    write(down[1], &go, 1);
    int st = 0;
    waitpid(kid, &st, 0);

    /* A thread starts with the name of the process that created it (Linux). */
    char tname[16];
    memset(tname, 0x55, 16);
    pthread_t th;
    int made = pthread_create(&th, (void *)0, thread_main, tname) == 0;
    if (made) pthread_join(th, (void *)0);
    char texp[16];
    memset(texp, 0, 16);
    memcpy(texp, "keep", 4);
    check(made && memcmp(tname, texp, 16) == 0, "a new thread starts with its creator's name");

    /* exec resets the name to the program's file name, whatever argv[0] says. */
    int ep[2];
    pipe(ep);
    long x = fork();
    if (x == 0) {
        set_name("beforeexec");
        char fdtext[16];
        snprintf(fdtext, sizeof fdtext, "%d", ep[1]);
        char *cargv[4] = {"renamed", "--child", fdtext, (char *)0};
        execve("hello258", cargv, environ);
        _exit(99);
    }
    char got[16];
    memset(got, 0x55, 16);
    read(ep[0], got, 16);
    waitpid(x, &st, 0);
    char exp[16];
    memset(exp, 0, 16);
    memcpy(exp, "hello258", 8);
    check(memcmp(got, exp, 16) == 0, "after exec the name is the new program's file name, not argv[0] and not the old name");

    print(failures == 0 ? "hello258: PASS\n" : "hello258: FAIL\n");
    return failures;
}
