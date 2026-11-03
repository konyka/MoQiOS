/* numconv.c — strtol family, atol/atoll, abs and div families, rand/srand (see include/stdlib.h). */
#include "../include/errno.h"
#include "../include/stdlib.h"

static int digit_value(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return 99;
}

static int is_space_c(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'; }

/* One implementation for both signednesses. Returns the magnitude and sets *neg, *overflow; *used is the position after
 * the last digit consumed, or -1 when nothing was converted (the caller then reports the start of the string). */
static unsigned long long parse_magnitude(const char *s, int base, int *neg, int *overflow, long *used) {
    const char *p = s;
    while (is_space_c((unsigned char)*p)) p++;
    *neg = 0;
    if (*p == '-' || *p == '+') {
        *neg = *p == '-';
        p++;
    }
    /* A 0x / 0b prefix counts only when a digit of that base follows it (glibc: "0x" alone is the number 0). */
    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') && digit_value((unsigned char)p[2]) < 16) {
        p += 2;
        base = 16;
    } else if ((base == 0 || base == 2) && p[0] == '0' && (p[1] == 'b' || p[1] == 'B') && digit_value((unsigned char)p[2]) < 2) {
        p += 2;
        base = 2;
    } else if (base == 0) {
        base = p[0] == '0' ? 8 : 10;
    }
    unsigned long long acc = 0;
    int any = 0;
    *overflow = 0;
    for (;; p++) {
        int d = digit_value((unsigned char)*p);
        if (d >= base) break;
        any = 1;
        unsigned long long limit = ~0ULL / (unsigned)base;
        if (acc > limit || (acc == limit && (unsigned)d > (unsigned)(~0ULL % (unsigned)base))) {
            *overflow = 1;
        } else {
            acc = acc * (unsigned)base + (unsigned)d;
        }
    }
    *used = any ? (long)(p - s) : -1;
    return acc;
}

static int base_valid(int base) { return base == 0 || (base >= 2 && base <= 36); }

unsigned long long strtoull(const char *s, char **end, int base) {
    if (!base_valid(base)) {
        errno = EINVAL;
        return 0;
    }
    int neg, over;
    long used;
    unsigned long long v = parse_magnitude(s, base, &neg, &over, &used);
    if (end) *end = (char *)(used < 0 ? s : s + used);
    if (over) {
        errno = ERANGE;
        return ~0ULL;
    }
    return neg ? 0ULL - v : v;
}

unsigned long strtoul(const char *s, char **end, int base) {
    return (unsigned long)strtoull(s, end, base);
}

long long strtoll(const char *s, char **end, int base) {
    if (!base_valid(base)) {
        errno = EINVAL;
        return 0;
    }
    int neg, over;
    long used;
    unsigned long long v = parse_magnitude(s, base, &neg, &over, &used);
    if (end) *end = (char *)(used < 0 ? s : s + used);
    const unsigned long long max = 9223372036854775807ULL;
    if (over || (!neg && v > max) || (neg && v > max + 1)) {
        errno = ERANGE;
        return neg ? (-9223372036854775807LL - 1) : 9223372036854775807LL;
    }
    return neg ? (long long)(0ULL - v) : (long long)v;
}

long strtol(const char *s, char **end, int base) {
    return (long)strtoll(s, end, base);
}

long atol(const char *s) { return strtol(s, (char **)0, 10); }
long long atoll(const char *s) { return strtoll(s, (char **)0, 10); }

int abs(int x) { return x < 0 ? (int)(0u - (unsigned)x) : x; }
long labs(long x) { return x < 0 ? (long)(0ul - (unsigned long)x) : x; }
long long llabs(long long x) { return x < 0 ? (long long)(0ull - (unsigned long long)x) : x; }

div_t div(int num, int den) {
    div_t r;
    r.quot = num / den;
    r.rem = num % den;
    return r;
}
ldiv_t ldiv(long num, long den) {
    ldiv_t r;
    r.quot = num / den;
    r.rem = num % den;
    return r;
}
lldiv_t lldiv(long long num, long long den) {
    lldiv_t r;
    r.quot = num / den;
    r.rem = num % den;
    return r;
}

/* glibc random(3), TYPE_3 ("r[i] = r[i-31] + r[i-3]"): 34 words are seeded (31 from a Lehmer LCG, then r[31..33] =
 * r[0..2]), the recurrence is run for 310 more words that are discarded, and every later word is returned shifted right
 * by one bit. The state is the last 34 words kept as a ring so that r[i-31] and r[i-3] are both available. */
#define RAND_LAG 31
#define RAND_TAP 3
#define RAND_WORDS 34
static unsigned rand_ring[RAND_WORDS];
static int rand_head; /* index of the oldest word, r[i-34] */
static int rand_seeded;

static unsigned rand_next_word(void) {
    /* r[i-31] is 3 after the oldest, r[i-3] is 31 after it, within a ring of 34. */
    unsigned a = rand_ring[(rand_head + (RAND_WORDS - RAND_LAG)) % RAND_WORDS];
    unsigned b = rand_ring[(rand_head + (RAND_WORDS - RAND_TAP)) % RAND_WORDS];
    unsigned w = a + b;
    rand_ring[rand_head] = w; /* the oldest word is replaced by the newest */
    rand_head = (rand_head + 1) % RAND_WORDS;
    return w;
}

void srand(unsigned seed) {
    if (seed == 0) seed = 1;
    int words[RAND_WORDS];
    words[0] = (int)seed;
    for (int i = 1; i < RAND_LAG; i++) {
        long long hi = words[i - 1] / 127773;
        long long lo = words[i - 1] % 127773;
        long long word = 16807 * lo - 2836 * hi;
        if (word < 0) word += 2147483647;
        words[i] = (int)word;
    }
    for (int i = RAND_LAG; i < RAND_WORDS; i++) words[i] = words[i - RAND_LAG];
    for (int i = 0; i < RAND_WORDS; i++) rand_ring[i] = (unsigned)words[i];
    rand_head = 0;
    rand_seeded = 1;
    for (int i = 0; i < 310; i++) rand_next_word();
}

int rand(void) {
    if (!rand_seeded) srand(1);
    return (int)(rand_next_word() >> 1);
}
