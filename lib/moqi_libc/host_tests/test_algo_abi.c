/* test_algo_abi.c — qsort, bsearch and rand_r, checked against glibc: exhaustive small arrays (every array over a
 * three-value alphabet up to length 7, all element sizes that matter), random larger ones, and rand_r values measured with
 * glibc. qsort must be stable (glibc's is), bsearch must find the same element as glibc's when there are duplicates. */
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/errno.h"
#include "../include/stdlib.h"

static int errno_slot;

/* qsort allocates its scratch copy with malloc. The test supplies malloc/free (the host libc's are not linked in this
 * -fno-builtin build), and malloc can be told to fail, so the stable in-place fallback is reached. */
static int fail_malloc;
static int malloc_calls;
static unsigned char heap[1 << 16];
static size_t heap_used;
void *malloc(size_t n) {
    malloc_calls++;
    if (fail_malloc) return (void *)0;
    n = (n + 15) & ~(size_t)15;
    if (heap_used + n > sizeof heap) return (void *)0;
    void *p = heap + heap_used;
    heap_used += n;
    return p;
}
/* Freeing rewinds the bump allocator to the freed block, so a sort that frees its scratch copy never runs the pool dry. A
 * sort that leaked would exhaust the pool; malloc then fails, the fallback sort runs, and the comparison-count check
 * below catches the O(n^2) behavior. */
void free(void *p) { if (p) heap_used = (size_t)((unsigned char *)p - heap); }

int *__errno_location(void) { return &errno_slot; }

struct rrow { unsigned seed; int vals[12]; unsigned final_state; };
static const struct rrow rrows[] = {
    {0U, {1012484, 1716955679, 1792309082, 229610924, 1639479903, 1362739833, 918811664, 2146985903, 1443394820, 717935133, 539012422, 1200475962}, 1194991756U},
    {1U, {476707713, 1186278907, 505671508, 2137716191, 936145377, 1215825599, 589265238, 924859463, 1182112391, 899065992, 1942841066, 1701072507}, 3397090333U},
    {2U, {952403967, 656651735, 1367566158, 1899386387, 230714723, 1069960966, 258670236, 1851267296, 919781386, 1079148274, 1197087886, 55233980}, 1304221614U},
    {42U, {681191333, 928546885, 1457394273, 941445650, 2129613237, 1661015563, 2071432601, 222443696, 1189133431, 1855709077, 1461119535, 777974771}, 3488818774U},
    {4294967295U, {1670702726, 99100226, 931463008, 467940729, 196379357, 1508605490, 1249408713, 1220578070, 1705725826, 537853875, 1284765602, 698829816}, 3287860475U},
    {123456789U, {1561111752, 731231783, 888595850, 2034629601, 686971243, 548941610, 642741380, 1613127949, 561541, 1701659201, 1113122335, 1030709620}, 3849633905U},
    {2147483648U, {1012484, 1716955679, 1792309082, 229610924, 1639479903, 1362739833, 918811664, 2146985903, 1443394820, 717935133, 539012422, 1200475962}, 3342475404U},
    {65536U, {1725503417, 1466408472, 455146087, 1983441373, 260103428, 1967682850, 1981364621, 58816784, 450075289, 299582582, 1047704115, 1981457099}, 2731221132U},
};

struct item { int key; int seq; };
static int by_key(const void *a, const void *b) { return ((const struct item *)a)->key - ((const struct item *)b)->key; }
static int by_int(const void *a, const void *b) { int x = *(const int *)a, y = *(const int *)b; return (x > y) - (x < y); }
static int cmp_first(const void *a, const void *b) { return *(const unsigned char *)a - *(const unsigned char *)b; }
static int calls;
static int counting(const void *a, const void *b) { calls++; return by_int(a, b); }

static unsigned long long rng = 88172645463325252ULL;
static unsigned rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (unsigned)(rng >> 11); }

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

int main(void) {
    /* Every array of length 0..7 over {0,1,2}: sorted, stable (equal keys keep their input order), a permutation. */
    for (int n = 0; n <= 7; n++) {
        int total = 1;
        for (int i = 0; i < n; i++) total *= 3;
        for (int code = 0; code < total; code++) {
            struct item a[8];
            int c = code;
            for (int i = 0; i < n; i++) { a[i].key = c % 3; a[i].seq = i; c /= 3; }
            qsort(a, (size_t)n, sizeof a[0], by_key);
            for (int i = 1; i < n; i++) {
                CHECK(a[i - 1].key <= a[i].key);
                if (a[i - 1].key == a[i].key) CHECK(a[i - 1].seq < a[i].seq);
            }
            int seen[8] = {0};
            for (int i = 0; i < n; i++) seen[a[i].seq]++;
            for (int i = 0; i < n; i++) CHECK(seen[i] == 1);
        }
    }
    /* Larger random arrays with many duplicates: sorted and stable. */
    for (int trial = 0; trial < 400; trial++) {
        int n = 1 + (int)(rnd() % 300);
        struct item a[300];
        for (int i = 0; i < n; i++) { a[i].key = (int)(rnd() % (unsigned)(1 + n / 3)); a[i].seq = i; }
        qsort(a, (size_t)n, sizeof a[0], by_key);
        for (int i = 1; i < n; i++) {
            CHECK(a[i - 1].key <= a[i].key);
            if (a[i - 1].key == a[i].key) CHECK(a[i - 1].seq < a[i].seq);
        }
    }
    /* Already sorted, reversed, all equal. */
    { int a[100]; for (int i = 0; i < 100; i++) a[i] = i; qsort(a, 100, sizeof a[0], by_int); for (int i = 0; i < 100; i++) CHECK(a[i] == i);
      for (int i = 0; i < 100; i++) a[i] = 99 - i; qsort(a, 100, sizeof a[0], by_int); for (int i = 0; i < 100; i++) CHECK(a[i] == i);
      for (int i = 0; i < 100; i++) a[i] = 7; qsort(a, 100, sizeof a[0], by_int); for (int i = 0; i < 100; i++) CHECK(a[i] == 7); }
    /* Element sizes that are not a power of two, and one bigger than a word: sort 50 records by their first byte. */
    {
        static const size_t sizes[] = {1, 2, 3, 5, 7, 8, 9, 12, 16, 24, 33, 100};
        for (unsigned si = 0; si < sizeof sizes / sizeof sizes[0]; si++) {
            size_t sz = sizes[si];
            unsigned char buf[50 * 100], expect[50 * 100];
            for (int i = 0; i < 50; i++) {
                for (size_t k = 0; k < sz; k++) buf[i * sz + k] = (unsigned char)(i * 31 + k);
                buf[i * sz] = (unsigned char)(rnd() % 6); /* only 6 distinct keys: many ties */
            }
            memcpy(expect, buf, 50 * sz);
            /* reference: stable insertion sort on the first byte */
            for (int i = 1; i < 50; i++) {
                unsigned char tmp[100];
                memcpy(tmp, expect + i * sz, sz);
                int j = i - 1;
                while (j >= 0 && expect[j * sz] > tmp[0]) { memcpy(expect + (j + 1) * sz, expect + j * sz, sz); j--; }
                memcpy(expect + (j + 1) * sz, tmp, sz);
            }
            /* The comparison only looks at byte 0, so the other bytes show whether equal elements kept their order. */
            qsort(buf, 50, sz, cmp_first);
            CHECK(memcmp(buf, expect, 50 * sz) == 0);
        }
    }
    /* With no memory for the scratch copy qsort still sorts, stably, in place; with memory it asks malloc exactly once. */
    {
        struct item a[40];
        for (int i = 0; i < 40; i++) { a[i].key = (int)(rnd() % 7); a[i].seq = i; }
        fail_malloc = 1;
        qsort(a, 40, sizeof a[0], by_key);
        fail_malloc = 0;
        for (int i = 1; i < 40; i++) {
            CHECK(a[i - 1].key <= a[i].key);
            if (a[i - 1].key == a[i].key) CHECK(a[i - 1].seq < a[i].seq);
        }
        for (int i = 0; i < 40; i++) { a[i].key = (int)(rnd() % 7); a[i].seq = i; }
        malloc_calls = 0;
        qsort(a, 40, sizeof a[0], by_key);
        CHECK(malloc_calls == 1);
        malloc_calls = 0;
        qsort(a, 1, sizeof a[0], by_key);
        qsort(a, 0, sizeof a[0], by_key);
        CHECK(malloc_calls == 0); /* nothing to sort, nothing allocated */
    }

    /* n = 0 and n = 1 never call the comparison; a NULL base with n = 0 is fine. */
    { calls = 0; int one = 5; qsort(&one, 1, sizeof one, counting); qsort((void *)0, 0, sizeof one, counting); CHECK(calls == 0 && one == 5); }
    /* The number of comparisons stays n log n-ish (a merge sort does at most n*ceil(log2 n)). */
    { int a[1000]; for (int i = 0; i < 1000; i++) a[i] = (int)(rnd() % 1000); calls = 0; qsort(a, 1000, sizeof a[0], counting);
      CHECK(calls <= 1000 * 10); for (int i = 1; i < 1000; i++) CHECK(a[i - 1] <= a[i]); }

    /* bsearch: found / not found / n = 0, and which duplicate it returns (glibc's probe order: mid = (lo + hi) / 2). */
    { int a[] = {1, 3, 5, 5, 7, 9};
      int k7 = 7, k4 = 4, k5 = 5, k1 = 1, k9 = 9, k0 = 0, k10 = 10;
      CHECK(bsearch(&k7, a, 6, sizeof a[0], by_int) == &a[4]);
      CHECK(bsearch(&k4, a, 6, sizeof a[0], by_int) == (void *)0);
      CHECK(bsearch(&k5, a, 6, sizeof a[0], by_int) == &a[3]); /* measured: index 3 of the two 5s */
      CHECK(bsearch(&k1, a, 6, sizeof a[0], by_int) == &a[0]);
      CHECK(bsearch(&k9, a, 6, sizeof a[0], by_int) == &a[5]);
      CHECK(bsearch(&k0, a, 6, sizeof a[0], by_int) == (void *)0);
      CHECK(bsearch(&k10, a, 6, sizeof a[0], by_int) == (void *)0);
      CHECK(bsearch(&k5, a, 0, sizeof a[0], by_int) == (void *)0);
      CHECK(bsearch(&k5, (void *)0, 0, sizeof a[0], by_int) == (void *)0); }
    /* With duplicates, bsearch returns the probe the halving finds first: every array of length 1..7 over {0,1,2}. */
    for (int n = 1; n <= 7; n++) {
        int total = 1;
        for (int i = 0; i < n; i++) total *= 3;
        for (int code = 0; code < total; code++) {
            int a[8], c = code;
            for (int i = 0; i < n; i++) { a[i] = c % 3; c /= 3; }
            qsort(a, (size_t)n, sizeof a[0], by_int);
            for (int key = -1; key <= 3; key++) {
                size_t lo = 0, hi = (size_t)n;
                const int *want = (const int *)0;
                while (lo < hi) {
                    size_t mid = (lo + hi) / 2;
                    int cmp = key - a[mid];
                    if (cmp < 0) hi = mid;
                    else if (cmp > 0) lo = mid + 1;
                    else { want = &a[mid]; break; }
                }
                CHECK(bsearch(&key, a, (size_t)n, sizeof a[0], by_int) == want);
            }
        }
    }
    /* bsearch on a big array does at most ceil(log2(n + 1)) comparisons. */
    { static int big[100000]; for (int i = 0; i < 100000; i++) big[i] = i * 2; int key = 77778; calls = 0;
      CHECK(bsearch(&key, big, 100000, sizeof big[0], counting) == &big[38889] && calls <= 17); }

    /* rand_r: the POSIX example generator, with glibc's three-step combination. */
    for (unsigned i = 0; i < sizeof rrows / sizeof rrows[0]; i++) {
        unsigned s = rrows[i].seed;
        for (int k = 0; k < 12; k++) {
            int got = rand_r(&s);
            if (got != rrows[i].vals[k]) { fprintf(stderr, "rand_r seed %u value %d: want %d got %d\n", rrows[i].seed, k, rrows[i].vals[k], got); bad++; break; }
        }
        if (s != rrows[i].final_state) { fprintf(stderr, "rand_r seed %u final state: want %u got %u\n", rrows[i].seed, rrows[i].final_state, s); bad++; }
    }

    assert(bad == 0);
    return 0;
}
