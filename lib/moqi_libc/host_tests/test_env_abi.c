/* test_env_abi.c — setenv, unsetenv, putenv and clearenv, checked against glibc: a sequence of operations run on the
 * same starting environment, with the return value, errno and the whole resulting environ recorded from glibc. On top of
 * that: environ entries are the caller's string for putenv and a private copy for setenv, the starting (stack) array is
 * never grown in place, and allocation failures leave the environment alone. */
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/errno.h"
#include "../include/stdlib.h"
#include "../include/unistd.h"

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }
long yield(void) { return 0; }

/* env.c takes its memory from malloc/free. The test supplies them so allocations can be made to fail. */
static int fail_at;      /* fail the Nth malloc from now (1 = the next one), 0 = never */
static int fail_always;
static int malloc_calls;
static void *last_freed;
static int free_calls;
static unsigned char heap[1 << 22];
static size_t heap_used;
void *malloc(size_t n) {
    malloc_calls++;
    if (fail_always) return (void *)0;
    if (fail_at && --fail_at == 0) return (void *)0;
    n = (n + 15) & ~(size_t)15;
    if (heap_used + n > sizeof heap) return (void *)0;
    void *p = heap + heap_used;
    heap_used += n;
    memset(p, 0xA5, n);
    return p;
}
void free(void *p) { if (p) { last_freed = p; free_calls++; } }

#include "../src/env.c"

static char *dupstr(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    memcpy(p, s, n);
    return p;
}

/* Strings for putenv that need no allocation (the allocator may be failing). */
static char *dupstr_static(const char *s) {
    static char pool[16][64];
    static int next;
    char *p = pool[next++ % 16];
    strcpy(p, s);
    return p;
}

/* The environment as one string, entries joined by '|'. */
static const char *flat(void) {
    static char buf[4096];
    buf[0] = 0;
    if (!environ) return "(null)";
    for (char **p = environ; *p; p++) {
        if (p != environ) strcat(buf, "|");
        strcat(buf, *p);
    }
    return buf;
}

struct envrow { char kind; const char *a; const char *b; int over; int ret; int err; const char *after; };

static const struct envrow envrows[] = {
    {'S', "A", "1", 1, 0, 0, "HOME=/root|PATH=/bin|DUP=1|X=2|DUP=3|A=1"},
    {'S', "B", "2", 1, 0, 0, "HOME=/root|PATH=/bin|DUP=1|X=2|DUP=3|A=1|B=2"},
    {'S', "A", "3", 0, 0, 0, "HOME=/root|PATH=/bin|DUP=1|X=2|DUP=3|A=1|B=2"},
    {'S', "A", "4", 1, 0, 0, "HOME=/root|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2"},
    {'S', "HOME", "/home/u", 0, 0, 0, "HOME=/root|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2"},
    {'S', "HOME", "/home/u", 1, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2"},
    {'S', "", "x", 1, -1, 22, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2"},
    {'S', "A=B", "x", 1, -1, 22, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2"},
    {'S', "=", "x", 1, -1, 22, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2"},
    {'S', "E", "", 1, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2|E="},
    {'S', "E", "", 0, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2|E="},
    {'S', "E", "v", 0, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2|E="},
    {'S', "K", "a=b=c", 1, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2|E=|K=a=b=c"},
    {'S', "PATH", "/usr/bin", 0, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2|E=|K=a=b=c"},
    {'S', "PAT", "p", 1, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2|E=|K=a=b=c|PAT=p"},
    {'S', "PATHX", "q", 1, 0, 0, "HOME=/home/u|PATH=/bin|DUP=1|X=2|DUP=3|A=4|B=2|E=|K=a=b=c|PAT=p|PATHX=q"},
    {'S', "DUP", "9", 1, 0, 0, "HOME=/home/u|PATH=/bin|DUP=9|X=2|DUP=3|A=4|B=2|E=|K=a=b=c|PAT=p|PATHX=q"},
    {'U', "", 0, 0, -1, 22, "HOME=/home/u|PATH=/bin|DUP=9|X=2|DUP=3|A=4|B=2|E=|K=a=b=c|PAT=p|PATHX=q"},
    {'U', "A=B", 0, 0, -1, 22, "HOME=/home/u|PATH=/bin|DUP=9|X=2|DUP=3|A=4|B=2|E=|K=a=b=c|PAT=p|PATHX=q"},
    {'U', "ZZ", 0, 0, 0, 0, "HOME=/home/u|PATH=/bin|DUP=9|X=2|DUP=3|A=4|B=2|E=|K=a=b=c|PAT=p|PATHX=q"},
    {'U', "DUP", 0, 0, 0, 0, "HOME=/home/u|PATH=/bin|X=2|A=4|B=2|E=|K=a=b=c|PAT=p|PATHX=q"},
    {'U', "PAT", 0, 0, 0, 0, "HOME=/home/u|PATH=/bin|X=2|A=4|B=2|E=|K=a=b=c|PATHX=q"},
    {'U', "PATH", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|PATHX=q"},
    {'U', "PATHX", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c"},
    {'P', "C=5", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|C=5"},
    {'P', "C=6", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|C=6"},
    {'P', "D", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|C=6"},
    {'P', "C", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c"},
    {'P', "=x", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|=x"},
    {'P', "=y", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|=y"},
    {'P', "Q=", 0, 0, 0, 0, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|=y|Q="},
    {'P', "", 0, 0, 0, 22, "HOME=/home/u|X=2|A=4|B=2|E=|K=a=b=c|=y|Q="},
    {'P', "A=put", 0, 0, 0, 0, "HOME=/home/u|X=2|A=put|B=2|E=|K=a=b=c|=y|Q="},
    {'S', "A", "after", 1, 0, 0, "HOME=/home/u|X=2|A=after|B=2|E=|K=a=b=c|=y|Q="},
    {'P', "A=put2", 0, 0, 0, 0, "HOME=/home/u|X=2|A=put2|B=2|E=|K=a=b=c|=y|Q="},
    {'S', "A", "kept", 0, 0, 0, "HOME=/home/u|X=2|A=put2|B=2|E=|K=a=b=c|=y|Q="},
    {'C', 0, 0, 0, 0, 0, "(null)"},
    {'U', "A", 0, 0, 0, 0, "(null)"},
    {'S', "N", "1", 1, 0, 0, "N=1"},
    {'C', 0, 0, 0, 0, 0, "(null)"},
    {'P', "Z=1", 0, 0, 0, 0, "Z=1"},
    {'P', "Z=2", 0, 0, 0, 0, "Z=2"},
    {'U', "Z", 0, 0, 0, 0, ""},
    {'U', "Z", 0, 0, 0, 0, ""},
    {'S', "Z", "3", 0, 0, 0, "Z=3"},
    {'S', "a", "lower", 1, 0, 0, "Z=3|a=lower"},
    {'S', "A", "upper", 1, 0, 0, "Z=3|a=lower|A=upper"},
    {'S', "LONGNAME_ABCDEFGHIJKLMNOPQRSTUVWXYZ", "value with spaces", 1, 0, 0, "Z=3|a=lower|A=upper|LONGNAME_ABCDEFGHIJKLMNOPQRSTUVWXYZ=value with spaces"},
    {'U', "a", 0, 0, 0, 0, "Z=3|A=upper|LONGNAME_ABCDEFGHIJKLMNOPQRSTUVWXYZ=value with spaces"},
};


#define START_N 6
static char *start_src[START_N] = {"HOME=/root", "PATH=/bin", "DUP=1", "X=2", "DUP=3", (char *)0};

static void reset_env(char **start) {
    for (int i = 0; i < START_N; i++) start[i] = start_src[i];
    environ = start;
}

int main(void) {
    char *start[START_N];

    /* 1. The recorded sequence. */
    reset_env(start);
    for (size_t i = 0; i < sizeof envrows / sizeof envrows[0]; i++) {
        const struct envrow *r = &envrows[i];
        int ret = 0;
        errno = 0;
        if (r->kind == 'S') ret = setenv(r->a, r->b, r->over);
        else if (r->kind == 'U') ret = unsetenv(r->a);
        else if (r->kind == 'P') ret = putenv(dupstr(r->a));
        else ret = clearenv();
        if (ret != r->ret || errno != r->err || strcmp(flat(), r->after) != 0) {
            printf("row %zu (%c %s %s %d): ret want %d got %d, errno want %d got %d\n  want [%s]\n  got  [%s]\n", i, r->kind,
                   r->a ? r->a : "-", r->b ? r->b : "-", r->over, r->ret, ret, r->err, errno, r->after, flat());
            return 1;
        }
    }

    /* 2. The array that came with the process is copied, not grown in place: it has exactly six slots. */
    reset_env(start);
    assert(setenv("NEW", "1", 1) == 0);
    assert(environ != start);
    assert(start[5] == (char *)0 && start[0] == start_src[0] && start[4] == start_src[4]);
    assert(environ[0] == start_src[0] && strcmp(environ[5], "NEW=1") == 0 && environ[6] == (char *)0);
    for (int i = 0; i < 5; i++) assert(environ[i] == start_src[i]);

    /* 3. putenv keeps the caller's string, setenv makes its own copy. */
    reset_env(start);
    char mine[] = "C=5";
    assert(putenv(mine) == 0);
    assert(environ[5] == mine);
    assert(environ != start && start[5] == (char *)0);
    mine[2] = '8';
    assert(strcmp(flat(), "HOME=/root|PATH=/bin|DUP=1|X=2|DUP=3|C=8") == 0);
    char mine2[] = "C=6";
    assert(putenv(mine2) == 0 && environ[5] == mine2 && environ[6] == (char *)0);
    char name[] = "S", value[] = "v1";
    assert(setenv(name, value, 1) == 0);
    name[0] = 'T';
    value[1] = '9';
    assert(strcmp(environ[6], "S=v1") == 0);
    /* An override replaces the entry with a fresh copy and does not modify the old string in place. */
    char *old = environ[6];
    assert(setenv("S", "v2", 1) == 0 && environ[6] != old && strcmp(old, "S=v1") == 0 && strcmp(environ[6], "S=v2") == 0);
    /* Overriding with the value already there keeps the same string (a pointer from getenv stays valid) and allocates nothing. */
    char *keep = environ[6];
    malloc_calls = 0;
    assert(setenv("S", "v2", 1) == 0 && malloc_calls == 0 && environ[6] == keep);
    /* A NULL value is refused (glibc would crash). */
    errno = 0;
    assert(setenv("S", (const char *)0, 1) == -1 && errno == EINVAL && environ[6] == keep);
    /* No override: nothing is allocated. */
    malloc_calls = 0;
    assert(setenv("S", "v3", 0) == 0 && malloc_calls == 0 && strcmp(environ[6], "S=v2") == 0);
    /* putenv of an entry already there, same pointer: still fine. */
    assert(putenv(environ[6]) == 0 && strcmp(environ[6], "S=v2") == 0 && environ[7] == (char *)0);

    /* 4. Allocation failures leave the environment as it was. */
    reset_env(start);
    const char *before = flat();
    char snap[512];
    strcpy(snap, before);
    fail_always = 1;
    errno = 0;
    assert(setenv("NEW", "1", 1) == -1 && errno == ENOMEM && strcmp(flat(), snap) == 0);
    errno = 0;
    assert(setenv("X", "other", 1) == -1 && errno == ENOMEM && strcmp(flat(), snap) == 0);
    assert(setenv("X", "other", 0) == 0 && strcmp(flat(), snap) == 0);
    errno = 0;
    assert(putenv(dupstr_static("NEW=1")) == -1 && errno == ENOMEM && strcmp(flat(), snap) == 0);
    assert(putenv(dupstr_static("X=3")) == 0 && strcmp(environ[3], "X=3") == 0);
    fail_always = 0;
    reset_env(start);
    strcpy(snap, flat());
    /* the string was allocated, then the array cannot be: the string is given back. */
    fail_at = 2;
    errno = 0;
    free_calls = 0;
    assert(setenv("NEW", "1", 1) == -1 && errno == ENOMEM && strcmp(flat(), snap) == 0);
    assert(free_calls == 1 && last_freed != (void *)0);
    fail_at = 0;

    /* 5. Growth: a few hundred entries, all kept, in order, then all removed. */
    reset_env(start);
    assert(clearenv() == 0 && environ == (char **)0);
    char nm[16], vl[16];
    for (int i = 0; i < 300; i++) {
        snprintf(nm, sizeof nm, "V%d", i);
        snprintf(vl, sizeof vl, "%d", i * 7);
        assert(setenv(nm, vl, 1) == 0);
    }
    int n = 0;
    for (char **p = environ; *p; p++) n++;
    assert(n == 300);
    for (int i = 0; i < 300; i++) {
        snprintf(nm, sizeof nm, "V%d=%d", i, i * 7);
        assert(strcmp(environ[i], nm) == 0);
    }
    for (int i = 0; i < 300; i += 2) {
        snprintf(nm, sizeof nm, "V%d", i);
        assert(unsetenv(nm) == 0);
    }
    n = 0;
    for (char **p = environ; *p; p++) n++;
    assert(n == 150 && strcmp(environ[0], "V1=7") == 0 && strcmp(environ[149], "V299=2093") == 0);
    assert(clearenv() == 0 && environ == (char **)0);
    assert(unsetenv("ANY") == 0 && environ == (char **)0);

    /* The first array has room for a handful of entries: ten variables need one array and ten strings, no more. */
    reset_env(start);
    malloc_calls = 0;
    for (int i = 0; i < 10; i++) {
        snprintf(nm, sizeof nm, "W%d", i);
        assert(setenv(nm, "x", 1) == 0);
    }
    assert(malloc_calls == 11);

    /* 6. Names that are only a prefix of another do not collide. */
    reset_env(start);
    assert(setenv("PAT", "p", 1) == 0 && setenv("PATHX", "q", 1) == 0);
    assert(unsetenv("PAT") == 0 && strcmp(flat(), "HOME=/root|PATH=/bin|DUP=1|X=2|DUP=3|PATHX=q") == 0);

    puts("env ok");
    return 0;
}
