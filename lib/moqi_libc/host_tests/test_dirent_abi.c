/* test_dirent_abi.c — dirent.h (include/dirent.h, src/dirent.c) against a scripted system-call stub.
 * The stub keeps one directory of records in the kernel's getdents64 format; the expectations are what glibc does (measured on
 * glibc 2.43): opendir fails with ENOENT for an empty or missing path and ENOTDIR for a file, the stream is close-on-exec,
 * readdir returns NULL at the end with errno untouched, rewinddir restarts, telldir/seekdir return to a position.
 */
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/moqi_syscalls.h"
#include "../include/dirent.h"
#define DT_DIR_ 4

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static int malloc_fails;
static int live_streams;
void *test_malloc(unsigned long n) { if (malloc_fails) return NULL; live_streams++; return malloc(n); }
void test_free(void *p) { live_streams--; free(p); }

/* ---- the stub: one directory, a cursor, scripted failures ---- */
struct ent { const char *name; unsigned char type; unsigned long ino; };
static struct ent dir_ents[16];
static int dir_n;
static int dir_cursor;                   /* index of the next entry, the kernel's resume cookie */
static int open_ok = 1, open_is_dir = 1; /* script: open result and what fstat reports */
static long open_err;
static long close_reply;
static int closed_calls, opened_flags;
static long getdents_err;                /* nonzero: getdents64 fails with it once */
static int getdents_calls;
static unsigned long max_per_call = 4096;

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a4; (void)a5; (void)a6;
    switch (nr) {
    case SYS_open:
        opened_flags = (int)a2;
        if (!open_ok) return open_err;
        return 7;
    case SYS_fstat: {
        unsigned char *st = (unsigned char *)a2;
        memset(st, 0, 144);
        unsigned int mode = open_is_dir ? 0040755 : 0100644;
        memcpy(st + 24, &mode, 4);
        return 0;
    }
    case SYS_close:
        closed_calls++;
        return close_reply;
    case SYS_lseek:
        if (a1 != 7) return -9;
        dir_cursor = (int)a2;
        return a2;
    case SYS_getdents64: {
        getdents_calls++;
        if (getdents_err) { long e = getdents_err; getdents_err = 0; return e; }
        unsigned char *out = (unsigned char *)a2;
        unsigned long cap = (unsigned long)a3 < max_per_call ? (unsigned long)a3 : max_per_call;
        unsigned long used = 0;
        while (dir_cursor < dir_n) {
            const struct ent *e = &dir_ents[dir_cursor];
            unsigned short reclen = (unsigned short)((19 + strlen(e->name) + 1 + 7) & ~7UL);
            if (used + reclen > cap) break;
            memset(out + used, 0, reclen);
            unsigned long ino = e->ino, off = (unsigned long)dir_cursor + 1;
            memcpy(out + used, &ino, 8);
            memcpy(out + used + 8, &off, 8);
            memcpy(out + used + 16, &reclen, 2);
            out[used + 18] = e->type;
            strcpy((char *)out + used + 19, e->name);
            used += reclen;
            dir_cursor++;
        }
        if (used == 0 && dir_cursor < dir_n) return -22;
        return (long)used;
    }
    }
    (void)a1; (void)a3;
    return -38;
}

static void fill(int n, const char *const *names, const unsigned char *types) {
    dir_n = n;
    dir_cursor = 0;
    for (int i = 0; i < n; i++) { dir_ents[i].name = names[i]; dir_ents[i].type = types[i]; dir_ents[i].ino = 100 + (unsigned long)i; }
}

static void script_reset(void) {
    open_ok = 1; open_is_dir = 1; open_err = 0; close_reply = 0; closed_calls = 0; opened_flags = 0;
    getdents_err = 0; getdents_calls = 0; max_per_call = 4096; malloc_fails = 0; errno_slot = 0; dir_cursor = 0;
}

int main(void) {
    CHECK(sizeof(struct dirent) == 280);
    CHECK(offsetof(struct dirent, d_ino) == 0 && offsetof(struct dirent, d_off) == 8 && offsetof(struct dirent, d_reclen) == 16);
    CHECK(offsetof(struct dirent, d_type) == 18 && offsetof(struct dirent, d_name) == 19);
    CHECK(DT_UNKNOWN == 0 && DT_FIFO == 1 && DT_CHR == 2 && DT_DIR == 4 && DT_BLK == 6 && DT_REG == 8 && DT_LNK == 10 && DT_SOCK == 12);
    CHECK(SYS_getdents64 == 173);

    static const char *const names[] = { ".", "..", "sub", "b", "a" };
    static const unsigned char types[] = { 4, 4, 4, 8, 8 };

    /* a full listing: the records come out in order with their inode, type and offset */
    script_reset(); fill(5, names, types);
    DIR *d = opendir("/tmp/x");
    CHECK(d != NULL && (opened_flags & 0x80000) != 0);                      /* close-on-exec */
    CHECK(dirfd(d) == 7);
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        CHECK(strcmp(e->d_name, names[n]) == 0 && e->d_type == types[n] && e->d_ino == 100UL + (unsigned long)n);
        CHECK(e->d_off == n + 1 && e->d_reclen >= 20);
        n++;
    }
    CHECK(n == 5);
    errno_slot = 0;
    CHECK(readdir(d) == NULL && errno_slot == 0);                           /* the end leaves errno alone */
    CHECK(readdir(d) == NULL && errno_slot == 0);
    CHECK(closedir(d) == 0 && closed_calls == 1 && live_streams == 0);

    /* one buffer fill hands out several records; a small kernel buffer needs several calls but the same result */
    script_reset(); fill(5, names, types); max_per_call = 48;
    d = opendir("/tmp/x");
    n = 0;
    while ((e = readdir(d)) != NULL) { CHECK(strcmp(e->d_name, names[n]) == 0); n++; }
    CHECK(n == 5 && getdents_calls >= 3);
    closedir(d);

    /* every result lives in the stream's one buffer: the pointer is the same, the content is replaced */
    script_reset(); fill(5, names, types);
    d = opendir("/tmp/x");
    struct dirent *e1 = readdir(d);
    char first[16]; strcpy(first, e1->d_name);
    struct dirent *e2 = readdir(d);
    CHECK(e1 == e2 && strcmp(first, ".") == 0 && strcmp(e2->d_name, "..") == 0);
    closedir(d);

    /* rewinddir restarts; telldir/seekdir come back to a position */
    script_reset(); fill(5, names, types);
    d = opendir("/tmp/x");
    while (readdir(d)) {}
    rewinddir(d);
    n = 0; while (readdir(d)) n++;
    CHECK(n == 5);
    rewinddir(d);
    readdir(d);
    rewinddir(d);                                                           /* mid-buffer: the rest of the buffer must be dropped */
    e = readdir(d);
    CHECK(strcmp(e->d_name, ".") == 0);
    readdir(d);
    long pos = telldir(d);
    e = readdir(d);
    CHECK(strcmp(e->d_name, "sub") == 0);
    e = readdir(d);
    CHECK(strcmp(e->d_name, "b") == 0);
    seekdir(d, pos);
    e = readdir(d);
    CHECK(strcmp(e->d_name, "sub") == 0);
    closedir(d);

    /* a directory with only the two dot entries, and an empty one */
    script_reset(); fill(2, names, types);
    d = opendir("/tmp/x"); n = 0; while (readdir(d)) n++; CHECK(n == 2); closedir(d);
    script_reset(); dir_n = 0;
    d = opendir("/tmp/x"); CHECK(readdir(d) == NULL); closedir(d);

    /* opendir errors */
    script_reset();
    errno_slot = 0; CHECK(opendir("") == NULL && errno_slot == ENOENT);
    errno_slot = 0; CHECK(opendir(NULL) == NULL && errno_slot == ENOENT);
    open_ok = 0; open_err = -2; errno_slot = 0;
    CHECK(opendir("/missing") == NULL && errno_slot == ENOENT);
    open_err = -13; errno_slot = 0;
    CHECK(opendir("/secret") == NULL && errno_slot == EACCES);
    script_reset(); open_is_dir = 0; errno_slot = 0; closed_calls = 0;
    CHECK(opendir("/tmp/file") == NULL && errno_slot == ENOTDIR && closed_calls == 1);     /* the descriptor is not leaked */
    script_reset(); malloc_fails = 1; errno_slot = 0; closed_calls = 0;
    CHECK(opendir("/tmp/x") == NULL && errno_slot == ENOMEM && closed_calls == 1);

    /* readdir failure: NULL with the kernel's errno */
    script_reset(); fill(5, names, types);
    d = opendir("/tmp/x");
    getdents_err = -5; errno_slot = 0;
    CHECK(readdir(d) == NULL && errno_slot == EIO);
    CHECK(readdir(d) != NULL);                                              /* the stream recovers */
    closedir(d);

    /* closedir passes the close error on, and still frees */
    script_reset(); fill(5, names, types);
    d = opendir("/tmp/x");
    close_reply = -5; errno_slot = 0;
    CHECK(closedir(d) == -1 && errno_slot == EIO && live_streams == 0);

    /* a name longer than the record is cut at the record, a name longer than 255 bytes at 255 */
    script_reset();
    {
        static char longname[400];
        memset(longname, 'n', sizeof longname - 1);
        longname[sizeof longname - 1] = 0;
        dir_ents[0].name = longname; dir_ents[0].type = 8; dir_ents[0].ino = 1; dir_n = 1; dir_cursor = 0;
        max_per_call = 4096;
        d = opendir("/tmp/x");
        e = readdir(d);
        CHECK(e != NULL && strlen(e->d_name) == 255);
        closedir(d);
    }

    if (bad) { fprintf(stderr, "test_dirent_abi: %d failure(s)\n", bad); return 1; }
    printf("test_dirent_abi: ok\n");
    return 0;
}
