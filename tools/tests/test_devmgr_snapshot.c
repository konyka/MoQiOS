/* test_devmgr_snapshot.c — host test for the getdents64 parse loop
 * extracted to servers/devmgr/snapshot_parse.h.
 *
 * Drives the parser with malformed dirent64 records: reclen == 0 (used to
 * infinite-loop the daemon), reclen smaller than the header, reclen
 * running past the end of the buffer, and an unterminated name (used to
 * strlen past the record). The parser must stay in bounds and drop the
 * bad record instead of trusting reclen.
 */
#include <stdio.h>
#include <string.h>

#include "../../servers/devmgr/snapshot_parse.h"

static int failures;
static int checks;

#define CHECK(cond) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    } \
} while (0)

/* Append a kernel-style record (header 19 bytes + name + NUL, reclen
 * padded to 8) at buf+pos; returns the position past it. */
static int emit_rec(char *buf, int pos, const char *name) {
    int nlen = (int)strlen(name);
    unsigned short reclen = (unsigned short)(((19 + nlen + 1) + 7) & ~7);
    memset(buf + pos, 0, reclen);
    buf[pos + 16] = (char)(reclen & 0xff);
    buf[pos + 17] = (char)(reclen >> 8);
    buf[pos + 18] = 4; /* DT_DIR-ish, value irrelevant */
    memcpy(buf + pos + 19, name, (size_t)nlen + 1);
    return pos + reclen;
}

/* Overwrite the reclen field of the record at buf+pos. */
static void patch_reclen(char *buf, int pos, unsigned short reclen) {
    buf[pos + 16] = (char)(reclen & 0xff);
    buf[pos + 17] = (char)(reclen >> 8);
}

static int parse(char *buf, int r, char *out) {
    out[0] = '\0';
    return devmgr_snapshot_parse(buf, r, out, 0, 1024);
}

int main(void) {
    static char buf[512];
    static char out[1025];

    /* Well-formed batch: both names are collected. */
    {
        int r = emit_rec(buf, 0, "null");
        r = emit_rec(buf, r, "tty");
        int n = parse(buf, r, out);
        CHECK(strcmp(out, "null tty") == 0);
        CHECK(n == 8);
    }

    /* reclen == 0: must terminate instead of looping in place. */
    {
        int r = emit_rec(buf, 0, "null");
        patch_reclen(buf, 0, 0);
        int n = parse(buf, r, out);
        CHECK(n == 0);
        CHECK(strcmp(out, "") == 0);
    }

    /* reclen smaller than the header: dropped, no out-of-record reads. */
    {
        int r = emit_rec(buf, 0, "null");
        patch_reclen(buf, 0, 10);
        int n = parse(buf, r, out);
        CHECK(n == 0);
    }

    /* reclen running past the end of the buffer: dropped. */
    {
        int r = emit_rec(buf, 0, "tty");
        patch_reclen(buf, 0, 400);
        int n = parse(buf, r, out);
        CHECK(n == 0);
    }

    /* Unterminated name: scan is bounded by reclen, not strlen. */
    {
        int r = emit_rec(buf, 0, "console");
        /* Clobber the NUL and the padding so no NUL remains in the record. */
        memset(buf + 19 + 7, 'X', 32 - 19 - 7);
        memset(out, 0xA5, sizeof(out));
        int n = parse(buf, r, out);
        CHECK(n == 32 - 19); /* whole padded name field, no overrun */
        CHECK(memcmp(out, "consoleXXXXXX", 13) == 0);
        CHECK(out[n] == '\0');
        CHECK((unsigned char)out[1024] == 0xA5);
    }

    /* Good record followed by a corrupt one: the good one is kept, the
     * bad one stops the batch. */
    {
        int r = emit_rec(buf, 0, "null");
        int bad = r;
        r = emit_rec(buf, r, "tty");
        patch_reclen(buf, bad, 1);
        int n = parse(buf, r, out);
        CHECK(strcmp(out, "null") == 0);
        CHECK(n == 4);
    }

    /* Trailing partial header (fewer bytes left than a header): ignored. */
    {
        int r = emit_rec(buf, 0, "null");
        int n = parse(buf, r + 5, out);
        CHECK(strcmp(out, "null") == 0);
        CHECK(n == 4);
    }

    printf("test_devmgr_snapshot: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
