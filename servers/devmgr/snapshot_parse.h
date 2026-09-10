#ifndef MOQIOS_DEVMGR_SNAPSHOT_PARSE_H
#define MOQIOS_DEVMGR_SNAPSHOT_PARSE_H

#include <stddef.h>
#include <string.h>

/* linux_dirent64, matching kernel/fs/getdents.zig. */
typedef struct {
    unsigned long long ino;
    long long          off;
    unsigned short     reclen;
    unsigned char      type;
    char               name[];
} dirent64_t;

/* Parse one getdents64 buffer, appending node names space-separated to
 * `out` (`n` bytes already used, capacity `cap`); returns the new `n`.
 *
 * reclen comes from a kernel-filled buffer but is not trusted blindly: a
 * record shorter than the header (0 included — that would loop the daemon
 * in place) or one running past the end of the buffer ends the batch, and
 * the name scan is bounded by reclen instead of an unbounded strlen. */
static int devmgr_snapshot_parse(const char *buf, int r, char *out, int n, int cap) {
    const int hdr = (int)offsetof(dirent64_t, name);
    int pos = 0;
    while (pos < r) {
        if (r - pos < hdr) break; /* truncated header at the tail */
        dirent64_t *d = (dirent64_t *)(const void *)(buf + pos);
        if ((int)d->reclen < hdr + 1 || pos + (int)d->reclen > r) break;
        int max = (int)d->reclen - hdr;
        int len = 0;
        while (len < max && d->name[len] != '\0') len++;
        if (n + len + 2 < cap) {
            if (n) out[n++] = ' ';
            memcpy(out + n, d->name, (size_t)len);
            n += len;
            out[n] = '\0';
        }
        pos += (int)d->reclen;
    }
    return n;
}

#endif
