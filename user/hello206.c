/* hello206: setenv, unsetenv, putenv and clearenv in the freestanding user build, and the changed environment reaching a
 * program started with execve. The comparison against glibc is on the host. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello206:   ok   " : "hello206:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int is(const char *name, const char *want) {
    const char *v = getenv(name);
    return want ? (v && strcmp(v, want) == 0) : v == (const char *)0;
}

int main(int argc, char **argv, char **envp) {
    (void)envp;
    if (argc >= 2 && strcmp(argv[1], "--child") == 0) {
        int ok = is("KEEP", "from-parent") && is("NEWVAR", "a=b=c") && is("EMPTY", "") && is("GONE", (const char *)0) &&
                 is("PUT", "by-putenv") && is("OVER", "second");
        print(ok ? "hello206 child: environment arrived intact\n" : "hello206 child: environment WRONG\n");
        return ok ? 0 : 1;
    }

    print("hello206: libc setenv / unsetenv / putenv / clearenv\n");

    int start_count = 0;
    while (environ && environ[start_count]) start_count++;
    check(setenv("A", "1", 1) == 0 && is("A", "1"), "A: setenv adds a variable");
    check(setenv("A", "2", 0) == 0 && is("A", "1"), "A: overwrite 0 keeps the old value");
    check(setenv("A", "3", 1) == 0 && is("A", "3"), "A: overwrite 1 replaces it");
    check(setenv("", "x", 1) == -1 && errno == EINVAL, "A: an empty name is EINVAL");
    check(setenv("A=B", "x", 1) == -1 && errno == EINVAL, "A: a name with '=' is EINVAL");
    check(unsetenv("A") == 0 && is("A", (const char *)0), "A: unsetenv removes it");
    check(unsetenv("A") == 0 && unsetenv("") == -1 && errno == EINVAL, "A: removing a missing name is fine, an empty one is EINVAL");

    static char kv[] = "P=one";
    check(putenv(kv) == 0 && getenv("P") == kv + 2, "B: putenv keeps the caller's string");
    kv[2] = 'O';
    check(is("P", "One"), "B: and a later change to that string shows in the environment");
    check(putenv("P") == 0 && is("P", (const char *)0), "B: putenv of a bare name removes the variable");

    for (int i = 0; i < 100; i++) {
        char name[16], val[16];
        snprintf(name, sizeof name, "BULK%d", i);
        snprintf(val, sizeof val, "v%d", i);
        setenv(name, val, 1);
    }
    int ok = 1;
    for (int i = 0; i < 100; i++) {
        char name[16], val[16];
        snprintf(name, sizeof name, "BULK%d", i);
        snprintf(val, sizeof val, "v%d", i);
        if (!is(name, val)) ok = 0;
    }
    check(ok, "C: a hundred variables, all found");
    for (int i = 0; i < 100; i++) {
        char name[16];
        snprintf(name, sizeof name, "BULK%d", i);
        unsetenv(name);
    }
    int count = 0;
    while (environ && environ[count]) count++;
    check(count == start_count, "C: removing them leaves the starting set");

    setenv("KEEP", "from-parent", 1);
    setenv("NEWVAR", "a=b=c", 1);
    setenv("EMPTY", "", 1);
    setenv("GONE", "x", 1);
    unsetenv("GONE");
    static char put[] = "PUT=by-putenv";
    putenv(put);
    setenv("OVER", "first", 1);
    setenv("OVER", "second", 1);

    long pid = fork();
    if (pid == 0) {
        char *cargv[3] = {"hello206", "--child", (char *)0};
        execve("hello206", cargv, environ);
        print("hello206: execve failed\n");
        _exit(99);
    }
    int status = 0;
    long w = waitpid(pid, &status, 0);
    check(w == pid && ((status >> 8) & 0xff) == 0 && (status & 0x7f) == 0, "D: a program started with execve(.., environ) sees the changes");

    check(clearenv() == 0 && environ == (char **)0 && getenv("KEEP") == (char *)0, "E: clearenv empties the environment");
    check(setenv("AFTER", "clear", 1) == 0 && is("AFTER", "clear"), "E: and it can be filled again");

    print(failures == 0 ? "hello206: PASS\n" : "hello206: FAIL\n");
    return failures;
}
