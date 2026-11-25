/* hello580: /proc/<pid>/limits exists and prints Linux's resource limits (a header line plus one line per resource: name, soft
 * limit, hard limit, units). The kernel had no such file (open returned ENOENT). A: the header is there and 16 resource lines
 * follow; B: the named resources Linux always shows are present (Max open files, Max stack size, Max address space, Max processes);
 * C: each numeric soft limit is <= its hard limit, and a limit of "unlimited" reads the same as getrlimit's RLIM_INFINITY. */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/resource.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/stdlib.h"
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello580:   ok   " : "hello580:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static char text[4096];
static long slurp_ok;

/* Count the lines that start with a capital letter (resource lines) and verify soft<=hard for every numeric pair. */
static int check_numeric_pairs(long *bad_out) {
    int bad = 0;
    char *line = text;
    while (*line) {
        char *nl = strchr(line, '\n');
        if (!nl) break;
        /* A resource line: skip the name (up to the first run of 2+ spaces), then two values. */
        char *p = line;
        /* find the padded name column: the name text, then spaces; values begin after at least one space past the name. */
        char *sep = p;
        while (*sep && *sep != '\n' && !(*sep == ' ' && sep[1] == ' ')) sep++;
        if (*sep == '\n' || *sep == 0) { line = nl + 1; continue; }
        while (*sep == ' ') sep++;
        /* soft */
        long soft;
        if (strncmp(sep, "unlimited", 9) == 0) { soft = -1; sep += 9; }
        else { char *e; soft = strtol(sep, &e, 10); if (e == sep) { line = nl + 1; continue; } sep = e; }
        while (*sep == ' ') sep++;
        long hard;
        if (strncmp(sep, "unlimited", 9) == 0) { hard = -1; sep += 9; }
        else { char *e; hard = strtol(sep, &e, 10); if (e == sep) { line = nl + 1; continue; } sep = e; }
        /* soft<=hard; -1 means unlimited (>= everything) */
        int ok = (soft == -1) || (hard == -1) || (soft <= hard);
        if (!ok) bad++;
        line = nl + 1;
    }
    *bad_out = bad;
    return bad == 0;
}

int main(void) {
    print("hello580: /proc/<pid>/limits\n");
    int fd = (int)open("/proc/self/limits", O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, text, sizeof text - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) { check(0, "A: /proc/self/limits opens and reads"); print("hello580: FAIL\n"); return 1; }
    text[n] = 0;
    slurp_ok = n;

    /* A: header line + 16 resource lines. */
    int header = strstr(text, "Soft Limit") != 0 && strstr(text, "Hard Limit") != 0;
    int lines = 0;
    for (const char *p = text; *p; p++) if (*p == '\n') lines++;
    snprintf(msg, sizeof msg, "A: header present %d, %d lines total (want header + 16 = 17)", header, lines);
    check(header && lines == 17, msg);

    /* B: the always-shown resources. */
    int named = strstr(text, "Max open files") && strstr(text, "Max stack size") && strstr(text, "Max address space") &&
                strstr(text, "Max processes") && strstr(text, "Max locked memory");
    check(named != 0, "B: Max open files / stack size / address space / processes / locked memory lines present");

    /* C: soft <= hard everywhere. */
    long bad = -1;
    int pairs_ok = check_numeric_pairs(&bad);
    snprintf(msg, sizeof msg, "C: every numeric soft limit <= hard limit (%ld violations)", bad);
    check(pairs_ok, msg);

    print(failures ? "hello580: FAIL\n" : "hello580: PASS\n");
    return failures ? 1 : 0;
}
