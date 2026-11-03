/* hello205: qsort, bsearch, rand_r, memmem, strcasestr and strsignal in the freestanding user build, with qsort running on
 * the real heap. The exhaustive comparison against glibc is on the host. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello205:   ok   " : "hello205:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

struct item { int key; int seq; };
static int by_key(const void *a, const void *b) { return ((const struct item *)a)->key - ((const struct item *)b)->key; }
static int by_int(const void *a, const void *b) { int x = *(const int *)a, y = *(const int *)b; return (x > y) - (x < y); }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello205: libc qsort / bsearch / rand_r / memmem / strsignal\n");

    int a[] = {5, 3, 9, 1, 5, 7};
    qsort(a, 6, sizeof a[0], by_int);
    check(a[0] == 1 && a[1] == 3 && a[2] == 5 && a[3] == 5 && a[4] == 7 && a[5] == 9, "A: qsort sorts a small array");
    int k7 = 7, k4 = 4, k5 = 5;
    check(bsearch(&k7, a, 6, sizeof a[0], by_int) == &a[4], "A: bsearch finds an element");
    check(bsearch(&k4, a, 6, sizeof a[0], by_int) == (void *)0, "A: and reports a missing one");
    check(bsearch(&k5, a, 6, sizeof a[0], by_int) == &a[3], "A: with duplicates it returns the same one glibc does (index 3)");

    /* A big array on the real heap: sorted, and stable on equal keys. */
    enum { N = 3000 };
    struct item *big = (struct item *)malloc(N * sizeof *big);
    check(big != (struct item *)0, "B: the heap gives 24000 bytes");
    unsigned s = 12345;
    for (int i = 0; i < N; i++) { big[i].key = (int)(rand_r(&s) % 100); big[i].seq = i; }
    qsort(big, N, sizeof *big, by_key);
    int sorted = 1, stable = 1;
    for (int i = 1; i < N; i++) {
        if (big[i - 1].key > big[i].key) sorted = 0;
        if (big[i - 1].key == big[i].key && big[i - 1].seq > big[i].seq) stable = 0;
    }
    check(sorted, "B: 3000 elements come out sorted");
    check(stable, "B: and equal keys keep their input order");
    free(big);
    int *ints = (int *)malloc(N * sizeof *ints);
    for (int i = 0; i < N; i++) ints[i] = i * 3;
    int hit = 1;
    for (int i = 0; i < N; i += 97) { int key = i * 3; if (bsearch(&key, ints, N, sizeof *ints, by_int) != &ints[i]) hit = 0; }
    int missing = 1;
    for (int i = 0; i < N; i += 101) { int key = i * 3 + 1; if (bsearch(&key, ints, N, sizeof *ints, by_int) != (void *)0) missing = 0; }
    check(hit && missing, "B: bsearch over 3000 elements: every probed element found, every absent one reported absent");
    free(ints);

    unsigned r = 1;
    check(rand_r(&r) == 476707713 && rand_r(&r) == 1186278907 && rand_r(&r) == 505671508, "C: rand_r with seed 1 gives glibc's sequence");
    for (int i = 0; i < 9; i++) rand_r(&r);
    check(r == 3397090333u, "C: and its state after 12 calls is glibc's");
    unsigned r0 = 0;
    check(rand_r(&r0) == 1012484, "C: and with seed 0 (rand_r does not special-case it, unlike srand)");

    const char *h = "Hello World";
    check(memmem(h, 11, "wor", 3) == (void *)0 && memmem(h, 11, "Wor", 3) == h + 6, "D: memmem is case sensitive");
    check(memmem(h, 11, "", 0) == h && memmem(h, 3, "Hello", 5) == (void *)0, "D: an empty needle matches at the start, a longer one never");
    check(strcasestr(h, "WORLD") == h + 6 && strcasestr(h, "xyz") == (char *)0 && strcasestr(h, "") == h, "D: strcasestr ignores case");

    check(strcmp(strsignal(2), "Interrupt") == 0 && strcmp(strsignal(11), "Segmentation fault") == 0 && strcmp(strsignal(9), "Killed") == 0, "E: strsignal for common signals");
    check(strcmp(strsignal(15), "Terminated") == 0 && strcmp(strsignal(17), "Child exited") == 0, "E: SIGTERM and SIGCHLD");
    check(strcmp(strsignal(34), "Real-time signal 0") == 0 && strcmp(strsignal(64), "Real-time signal 30") == 0, "E: real-time signals count from SIGRTMIN");
    check(strcmp(strsignal(0), "Unknown signal 0") == 0 && strcmp(strsignal(65), "Unknown signal 65") == 0 && strcmp(strsignal(-1), "Unknown signal -1") == 0, "E: unknown signals");

    print(failures == 0 ? "hello205: PASS\n" : "hello205: FAIL\n");
    return failures;
}
