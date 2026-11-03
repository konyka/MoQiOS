/* algo.c — qsort, bsearch, rand_r (see include/stdlib.h). */
#include "../include/stdlib.h"
#include "../include/string.h"

/* Stable merge sort of `n` elements in `base`, using `tmp` (n * size bytes) as scratch. Bottom-up on runs of width 1, 2,
 * 4 ...; on a tie the left element is taken first, which is what makes it stable. */
static void merge_sort(char *base, char *tmp, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
    char *src = base, *dst = tmp;
    for (size_t width = 1; width < n; width *= 2) {
        for (size_t lo = 0; lo < n; lo += 2 * width) {
            size_t mid = lo + width < n ? lo + width : n;
            size_t hi = lo + 2 * width < n ? lo + 2 * width : n;
            size_t i = lo, j = mid, k = lo;
            while (i < mid && j < hi) {
                if (cmp(src + j * size, src + i * size) < 0) {
                    memcpy(dst + k * size, src + j * size, size);
                    j++;
                } else {
                    memcpy(dst + k * size, src + i * size, size);
                    i++;
                }
                k++;
            }
            if (i < mid) memcpy(dst + k * size, src + i * size, (mid - i) * size);
            else if (j < hi) memcpy(dst + k * size, src + j * size, (hi - j) * size);
        }
        char *swap = src;
        src = dst;
        dst = swap;
    }
    if (src != base) memcpy(base, src, n * size);
}

/* Used when no scratch memory is available: stable, O(n^2) moves, no allocation. */
static void insertion_sort(char *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
    for (size_t i = 1; i < n; i++) {
        size_t j = i;
        while (j > 0 && cmp(base + (j - 1) * size, base + j * size) > 0) {
            for (size_t k = 0; k < size; k++) {
                char t = base[(j - 1) * size + k];
                base[(j - 1) * size + k] = base[j * size + k];
                base[j * size + k] = t;
            }
            j--;
        }
    }
}

void qsort(void *base, size_t nmemb, size_t size, int (*cmp)(const void *, const void *)) {
    if (nmemb < 2 || size == 0) return;
    if (size != 0 && nmemb > (size_t)-1 / size) {
        insertion_sort((char *)base, nmemb, size, cmp);
        return;
    }
    char *tmp = (char *)malloc(nmemb * size);
    if (!tmp) {
        insertion_sort((char *)base, nmemb, size, cmp);
        return;
    }
    merge_sort((char *)base, tmp, nmemb, size, cmp);
    free(tmp);
}

void *bsearch(const void *key, const void *base, size_t nmemb, size_t size, int (*cmp)(const void *, const void *)) {
    size_t lo = 0, hi = nmemb;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        const char *p = (const char *)base + mid * size;
        int c = cmp(key, p);
        if (c < 0) hi = mid;
        else if (c > 0) lo = mid + 1;
        else return (void *)p;
    }
    return (void *)0;
}

/* glibc's rand_r: three steps of the 1103515245 LCG, taking 11 bits, 10 bits and 10 bits from successive states. */
int rand_r(unsigned *seed) {
    unsigned next = *seed;
    unsigned result;
    next *= 1103515245;
    next += 12345;
    result = (next / 65536) % 2048;
    next *= 1103515245;
    next += 12345;
    result <<= 10;
    result ^= (next / 65536) % 1024;
    next *= 1103515245;
    next += 12345;
    result <<= 10;
    result ^= (next / 65536) % 1024;
    *seed = next;
    return (int)result;
}
