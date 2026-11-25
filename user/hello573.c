/* hello573: /proc/<pid>/stat carries real values for pid(1), comm(2), state(3), ppid(4), num_threads(20), vsize(23, bytes) and
 * rss(24, pages). The kernel filled only the first four and left a run of zeros, so monitoring tools saw a thread count and memory
 * size of 0. A: the line has at least 24 space-separated fields, field 1 is this pid and field 2 is "(comm)"; B: state is a single
 * letter, ppid is the real parent; C: num_threads is 1 for a single-threaded process; D: vsize > 0 and rss > 0, and vsize/4096 is
 * at least rss (the resident pages are a subset of the mapped size). */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *what) {
    print(ok ? "hello573:   ok   " : "hello573:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello573: /proc/<pid>/stat real fields\n");
    static char buf[1024];
    int fd = (int)open("/proc/self/stat", O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, buf, sizeof buf - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) { check(0, "A: /proc/self/stat opens and reads"); print("hello573: FAIL\n"); return 1; }
    buf[n] = 0;

    long mypid = getpid();

    /* Field 1: pid. Field 2: "(comm)" which may contain spaces — Linux parses comm between the first '(' and the last ')'. */
    long f1 = 0;
    const char *p = buf;
    while (*p >= '0' && *p <= '9') { f1 = f1 * 10 + (*p - '0'); p++; }
    const char *lp = strchr(buf, '(');
    const char *rp = strrchr(buf, ')');
    int comm_ok = lp && rp && rp > lp;
    snprintf(msg, sizeof msg, "A: field1 pid %ld == %ld, comm parens %d", f1, mypid, comm_ok);
    check(f1 == mypid && comm_ok, msg);
    if (!comm_ok) { print("hello573: FAIL\n"); return 1; }

    /* Parse the fields after ")": state(3) ppid(4) ... */
    const char *q = rp + 1;
    /* collect up to 24 fields starting at field 3 */
    long fld[40];
    int nf = 0;
    char state = 0;
    while (nf < 40) {
        while (*q == ' ') q++;
        if (*q == 0 || *q == '\n') break;
        if (nf == 0) { state = *q; /* field 3 is a letter */ }
        long sign = 1, x = 0;
        int got = 0;
        const char *s = q;
        if (*s == '-') { sign = -1; s++; }
        while (*s >= '0' && *s <= '9') { x = x * 10 + (*s - '0'); s++; got = 1; }
        fld[nf++] = got ? sign * x : -999; /* -999 marks a non-numeric field (e.g. the state letter) */
        while (*q != ' ' && *q != 0 && *q != '\n') q++;
    }
    /* fld[0]=field3(state,non-numeric), fld[1]=field4(ppid), ... fld[k]=field(3+k) */
    int have = nf >= 22; /* need up to field 24 => index 21 */
    snprintf(msg, sizeof msg, "B: state '%c' is a letter, ppid field present (nf=%d)", state ? state : '?', nf);
    check(((state >= 'A' && state <= 'Z')) && have, msg);
    if (!have) { print("hello573: FAIL\n"); return 1; }

    long num_threads = fld[20 - 3]; /* field 20 */
    long vsize = fld[23 - 3];       /* field 23 */
    long rss = fld[24 - 3];         /* field 24 */
    snprintf(msg, sizeof msg, "C: num_threads %ld == 1", num_threads);
    check(num_threads == 1, msg);

    snprintf(msg, sizeof msg, "D: vsize %ld > 0, rss %ld > 0, vsize/4096 %ld >= rss", vsize, rss, vsize / 4096);
    check(vsize > 0 && rss > 0 && vsize / 4096 >= rss, msg);

    print(failures ? "hello573: FAIL\n" : "hello573: PASS\n");
    return failures ? 1 : 0;
}
