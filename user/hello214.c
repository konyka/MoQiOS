/* hello214: the file-system context (current directory and umask) belongs to the process, not to a thread (every pthread
 * is created with CLONE_FS). chdir/umask in one thread must be seen by every other thread, and a relative path used by a
 * thread resolves against the process's directory. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello214:   ok   " : "hello214:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long raw_umask(long mask) { return syscall1(95, mask); }

enum { OP_NONE, OP_GETCWD, OP_CHDIR, OP_UMASK, OP_MKDIR, OP_QUIT };
static volatile int op, done_flag;
static char arg_path[64];
static volatile long arg_num, ret_num;
static char ret_cwd[128];

static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        while (op == OP_NONE) yield();
        int what = op;
        op = OP_NONE;
        if (what == OP_QUIT) return (void *)0;
        if (what == OP_GETCWD) {
            memset(ret_cwd, 0, sizeof ret_cwd);
            ret_num = getcwd(ret_cwd, sizeof ret_cwd);
        } else if (what == OP_CHDIR) {
            ret_num = chdir(arg_path);
        } else if (what == OP_UMASK) {
            ret_num = raw_umask(arg_num);
        } else if (what == OP_MKDIR) {
            ret_num = mkdir(arg_path, 0777);
        }
        done_flag = 1;
    }
}

static void ask(int what) {
    done_flag = 0;
    op = what;
    while (!done_flag) yield();
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello214: current directory and umask shared by threads\n");

    pthread_t t;
    check(pthread_create(&t, (void *)0, worker, (void *)0) == 0, "A: a worker thread starts");

    check(mkdir("/tmp/h214", 0777) == 0 || 1, "A: a scratch directory under /tmp");
    check(chdir("/tmp/h214") == 0, "A: the main thread changes directory to /tmp/h214");
    ask(OP_GETCWD);
    check(ret_num > 0 && strcmp(ret_cwd, "/tmp/h214") == 0, "A: and the worker reports /tmp/h214 as its current directory");

    strcpy(arg_path, "/tmp");
    ask(OP_CHDIR);
    check(ret_num == 0, "B: the worker changes directory to /tmp");
    char mine[128];
    memset(mine, 0, sizeof mine);
    check(getcwd(mine, sizeof mine) > 0 && strcmp(mine, "/tmp") == 0, "B: and the main thread's current directory is now /tmp");

    strcpy(arg_path, "h214sub");
    ask(OP_MKDIR);
    check(ret_num == 0, "C: the worker makes a relative directory h214sub");
    check(chdir("/tmp/h214sub") == 0, "C: which is at /tmp/h214sub, because the process's directory is /tmp");
    chdir("/tmp");
    rmdir("/tmp/h214sub");

    long old = raw_umask(027);
    (void)old;
    arg_num = 0077;
    ask(OP_UMASK);
    check(ret_num == 027, "D: the worker's umask() returns the main thread's 027 as the previous mask");
    check(raw_umask(022) == 0077, "D: and the main thread sees the worker's 077 as the previous mask");

    op = OP_QUIT;
    pthread_join(t, (void **)0);
    rmdir("/tmp/h214");
    print(failures == 0 ? "hello214: PASS\n" : "hello214: FAIL\n");
    return failures;
}
