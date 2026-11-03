/* hello207: realloc, reallocarray, posix_memalign, aligned_alloc, memalign and the ENOMEM errno of the allocator, on the
 * real heap (brk) in the freestanding user build. The exhaustive checks against glibc's behavior are on the host. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello207:   ok   " : "hello207:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int filled(const unsigned char *p, size_t n, unsigned char v) {
    for (size_t i = 0; i < n; i++) if (p[i] != v) return 0;
    return 1;
}

static void *thread_main(void *arg) {
    int bad = 0;
    unsigned char *p = 0;
    for (int i = 1; i <= 400; i++) {
        p = realloc(p, (size_t)i * 37);
        if (!p) { bad = 1; break; }
        memset(p, (int)(i & 0xff), (size_t)i * 37);
    }
    free(p);
    *(int *)arg = bad;
    return (void *)0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello207: libc realloc / aligned allocation / allocation errno\n");

    unsigned char *p = realloc((void *)0, 100);
    check(p != 0, "A: realloc(NULL, n) allocates");
    memset(p, 0xA1, 100);
    unsigned char *q = realloc(p, 100000);
    check(q != 0 && filled(q, 100, 0xA1), "A: growing 100 bytes to 100000 keeps the data");
    memset(q, 0xB2, 100000);
    q = realloc(q, 50);
    check(q != 0 && filled(q, 50, 0xB2), "A: shrinking to 50 keeps the first 50 bytes");
    check(realloc(q, 0) == (void *)0, "A: realloc(p, 0) frees and returns NULL");

    unsigned char *grow = 0;
    int ok = 1;
    for (int i = 1; i <= 200; i++) {
        grow = realloc(grow, (size_t)i * 64);
        if (!grow) { ok = 0; break; }
        if (i > 1 && !filled(grow, (size_t)(i - 1) * 64, (unsigned char)(i - 1))) { ok = 0; break; }
        memset(grow, i, (size_t)i * 64);
    }
    check(ok, "B: 200 successive growths (up to 12800 bytes) never lose data");
    free(grow);

    errno = 0;
    check(malloc((size_t)-1) == (void *)0 && errno == ENOMEM, "C: malloc of an impossible size is NULL with ENOMEM");
    errno = 0;
    void *keep = malloc(64);
    memset(keep, 0xC3, 64);
    check(realloc(keep, (size_t)-1) == (void *)0 && errno == ENOMEM && filled(keep, 64, 0xC3), "C: a failing realloc leaves the original alone");
    errno = 0;
    check(realloc(keep, (size_t)1 << 40) == (void *)0 && errno == ENOMEM && filled(keep, 64, 0xC3), "C: also when the kernel refuses to grow the heap");
    errno = 0;
    check(calloc((size_t)1 << 40, (size_t)1 << 40) == (void *)0 && errno == ENOMEM, "C: calloc overflow is ENOMEM");
    errno = 0;
    check(reallocarray((void *)0, (size_t)1 << 40, (size_t)1 << 40) == (void *)0 && errno == ENOMEM, "C: reallocarray overflow is ENOMEM");
    errno = 99;
    void *fine = malloc(16);
    check(fine != 0 && errno == 99, "C: success leaves errno alone");
    free(fine);
    free(keep);

    int rc_ok = 1, al_ok = 1;
    static const size_t aligns[] = {8, 16, 32, 64, 256, 4096, 65536};
    for (unsigned i = 0; i < sizeof aligns / sizeof aligns[0]; i++) {
        void *m = (void *)0;
        if (posix_memalign(&m, aligns[i], 100) != 0 || !m || ((unsigned long)m & (aligns[i] - 1))) rc_ok = 0;
        else { memset(m, 0x5A, 100); free(m); }
        void *a = aligned_alloc(aligns[i], 128);
        if (!a || ((unsigned long)a & (aligns[i] - 1))) al_ok = 0;
        else { memset(a, 0x5B, 128); free(a); }
    }
    check(rc_ok, "D: posix_memalign gives properly aligned memory for 8 .. 65536");
    check(al_ok, "D: and so does aligned_alloc");
    void *bad = (void *)5;
    check(posix_memalign(&bad, 3, 10) == EINVAL && bad == (void *)5, "D: a bad alignment is EINVAL and *memptr is left alone");
    check(posix_memalign(&bad, 4, 10) == EINVAL, "D: smaller than a pointer is EINVAL for posix_memalign");
    errno = 0;
    check(aligned_alloc(48, 10) == (void *)0 && errno == EINVAL, "D: aligned_alloc with a non power of two is EINVAL");
    void *m5 = memalign(5, 10);
    check(m5 != 0 && ((unsigned long)m5 & 7) == 0, "D: memalign rounds 5 up to 8");
    free(m5);

    unsigned char *neigh[40];
    int clean = 1;
    for (int i = 0; i < 40; i++) {
        neigh[i] = (i & 1) ? memalign(128, 40 + (size_t)i) : malloc(40 + (size_t)i);
        if (!neigh[i]) { clean = 0; break; }
        memset(neigh[i], i + 1, 40 + (size_t)i);
    }
    for (int i = 0; i < 40 && clean; i++)
        if (!filled(neigh[i], 40 + (size_t)i, (unsigned char)(i + 1))) clean = 0;
    for (int i = 0; i < 40; i += 2) free(neigh[i]);
    for (int i = 1; i < 40; i += 2) if (neigh[i]) free(neigh[i]);
    unsigned char *again = malloc(2000);
    check(clean && again != 0, "E: aligned and plain blocks interleaved do not overwrite each other, and freeing them leaves a usable heap");
    free(again);

    pthread_t th[4];
    int res[4] = {1, 1, 1, 1};
    int created = 1;
    for (int i = 0; i < 4; i++) if (pthread_create(&th[i], (void *)0, thread_main, &res[i]) != 0) created = 0;
    for (int i = 0; i < 4; i++) if (created) pthread_join(th[i], (void *)0);
    check(created && !res[0] && !res[1] && !res[2] && !res[3], "F: four threads growing their own buffers 400 times each");

    print(failures == 0 ? "hello207: PASS\n" : "hello207: FAIL\n");
    return failures;
}
