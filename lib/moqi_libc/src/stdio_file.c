/* stdio_file.c — the FILE layer (see stdio_file.h for the design and the glibc behavior it follows).
 *
 * The code is written against the hooks below, so the host test can build it with an in-memory file system:
 *   NAME(x)        the exported name (the test renames them);
 *   IO_OPEN/READ/WRITE/LSEEK/CLOSE/GETFL   system calls returning -errno;
 *   MEM_ALLOC/MEM_FREE;
 *   LIST_LOCK/LIST_UNLOCK   guard the list of open streams (threads may fopen/fclose/fflush(NULL) at the same time).
 */
/* The including file defines the hooks before including this one (stdio_streams.c for the system, test_file_abi.c for the
 * host test). */
#ifndef NAME
#error "define NAME, IO_*, MEM_* before including stdio_file.c"
#endif
#if !defined(LIST_LOCK) || !defined(LIST_UNLOCK)
#error "define LIST_LOCK and LIST_UNLOCK before including stdio_file.c"
#endif

#include "stdio_file.h"

#define O_EXCL_ 0x80

/* ---- plumbing -------------------------------------------------------------------------------------------------- */

static struct FILE_s *open_streams;

static void list_add(struct FILE_s *f) {
    LIST_LOCK();
    f->next = open_streams;
    open_streams = f;
    LIST_UNLOCK();
}

static void list_remove(struct FILE_s *f) {
    LIST_LOCK();
    for (struct FILE_s **p = &open_streams; *p; p = &(*p)->next)
        if (*p == f) {
            *p = f->next;
            break;
        }
    LIST_UNLOCK();
}

static int set_err(struct FILE_s *f, long neg_errno) {
    f->flags |= F_ERR;
    errno = (int)-neg_errno;
    return -1;
}

static int ensure_buf(struct FILE_s *f) {
    if (f->buf) return 0;
    f->buf = (unsigned char *)MEM_ALLOC(FILE_BUFSIZE);
    if (!f->buf) {
        errno = ENOMEM;
        f->flags |= F_ERR;
        return -1;
    }
    f->bufsize = FILE_BUFSIZE;
    f->fresh_buf = 1;
    return 0;
}

/* Write out the pending output. Short writes are continued; on failure what was not written is dropped and the error flag
 * is set (glibc keeps the data buffered, but then every later call fails the same way). */
static int flush_out(struct FILE_s *f) {
    size_t done = 0;
    while (done < f->wpos) {
        long r = IO_WRITE(f->fd, f->buf + done, f->wpos - done);
        if (r == -EINTR) continue;
        if (r < 0) {
            f->wpos = 0;
            return set_err(f, r);
        }
        if (r == 0) {
            f->wpos = 0;
            return set_err(f, -EIO);
        }
        done += (size_t)r;
    }
    f->wpos = 0;
    return 0;
}

/* Give back the read-ahead window: the descriptor goes back to the logical position. */
static int drop_readahead(struct FILE_s *f) {
    if (f->flags & F_FRESH) {
        f->flags &= ~F_FRESH;
        f->rpos = f->rend = 0;
        return 0;
    }
    if (f->rend > f->rpos) {
        long back = (long)(f->rend - f->rpos);
        long r = IO_LSEEK(f->fd, -back, 1);
        if (r == -ESPIPE) return 0; /* a pipe cannot give bytes back: keep the window, they are still readable (glibc) */
        if (r < 0) {
            f->rpos = f->rend = 0;
            return set_err(f, r);
        }
    }
    f->rpos = f->rend = 0;
    return 0;
}

/* Get ready to read: pending output goes out first. */
static int begin_read(struct FILE_s *f) {
    if (!(f->flags & F_READ)) {
        errno = EBADF;
        f->flags |= F_ERR;
        return -1;
    }
    if (f->wpos) {
        if (flush_out(f) != 0) return -1;
    }
    return 0;
}

/* Get ready to write: a read-ahead window is given back first. */
static int begin_write(struct FILE_s *f) {
    if (!(f->flags & F_WRITE)) {
        errno = EBADF;
        f->flags |= F_ERR;
        return -1;
    }
    if (f->rend > f->rpos || f->rend) {
        if (drop_readahead(f) != 0) return -1;
    }
    return ensure_buf(f);
}

/* Fill the read-ahead window; returns the number of bytes now available, 0 at end of file, -1 on error. */
static long fill(struct FILE_s *f) {
    if (ensure_buf(f) != 0) return -1;
    if (f->flags & F_EOF) return 0;
    f->flags &= ~F_FRESH;
    long r;
    do {
        r = IO_READ(f->fd, f->buf, f->bufsize);
    } while (r == -EINTR);
    if (r < 0) {
        set_err(f, r);
        return -1;
    }
    if (r == 0) {
        f->flags |= F_EOF;
        f->rpos = f->rend = 0;
        return 0;
    }
    f->rpos = 0;
    f->rend = (size_t)r;
    return r;
}

/* ---- opening and closing --------------------------------------------------------------------------------------- */

/* Parse a mode string: r w a, then any of b + x e m (and others glibc ignores). Returns -1 for a bad first letter. */
static int parse_mode(const char *mode, long *oflags, int *fflags, int *excl) {
    if (!mode) return -1;
    int plus = 0;
    *excl = 0;
    long base;
    int ff;
    switch (mode[0]) {
    case 'r': base = 0; ff = F_READ; break;
    case 'w': base = 0x40 | 0x200; ff = F_WRITE; break;
    case 'a': base = 0x40 | 0x400; ff = F_WRITE | F_APPEND; break;
    default: return -1;
    }
    for (const char *p = mode + 1; *p && *p != ','; p++) {
        if (*p == '+') plus = 1;
        else if (*p == 'x') *excl = 1;
    }
    if (plus) {
        ff |= F_READ | F_WRITE;
        *oflags = base | 2;
    } else if (ff & F_WRITE) {
        *oflags = base | 1;
    } else {
        *oflags = base;
    }
    if (*excl && (mode[0] == 'w' || mode[0] == 'a')) *oflags |= O_EXCL_;
    *fflags = ff;
    return 0;
}

static struct FILE_s *new_stream(int fd, int fflags) {
    struct FILE_s *f = (struct FILE_s *)MEM_ALLOC(sizeof *f);
    if (!f) return (struct FILE_s *)0;
    memset(f, 0, sizeof *f);
    f->fd = fd;
    f->flags = fflags;
    f->bmode = FB_FULL;
    list_add(f);
    return f;
}

struct FILE_s *NAME(fopen)(const char *path, const char *mode) {
    long oflags;
    int fflags, excl;
    if (!path) {
        errno = EFAULT;
        return (struct FILE_s *)0;
    }
    if (parse_mode(mode, &oflags, &fflags, &excl) != 0) {
        errno = EINVAL;
        return (struct FILE_s *)0;
    }
    long fd = IO_OPEN(path, oflags, 0666);
    if (fd < 0) {
        errno = (int)-fd;
        return (struct FILE_s *)0;
    }
    struct FILE_s *f = new_stream((int)fd, fflags);
    if (!f) {
        IO_CLOSE((int)fd);
        errno = ENOMEM;
        return (struct FILE_s *)0;
    }
    /* glibc: a stream opened for appending starts at the end of the file, so ftell reports the length right away. */
    if (fflags & F_APPEND) IO_LSEEK((int)fd, 0, 2);
    return f;
}

struct FILE_s *NAME(fdopen)(int fd, const char *mode) {
    long oflags;
    int fflags, excl;
    if (parse_mode(mode, &oflags, &fflags, &excl) != 0) {
        errno = EINVAL;
        return (struct FILE_s *)0;
    }
    long cur = IO_GETFL(fd);
    if (cur < 0) {
        errno = (int)-cur;
        return (struct FILE_s *)0;
    }
    int acc = (int)(cur & 3);
    if (((fflags & F_READ) && acc == 1) || ((fflags & F_WRITE) && acc == 0)) {
        errno = EINVAL;
        return (struct FILE_s *)0;
    }
    struct FILE_s *f = new_stream(fd, fflags);
    if (!f) {
        errno = ENOMEM;
        return (struct FILE_s *)0;
    }
    return f;
}

int NAME(fileno)(struct FILE_s *f) { return f->fd; }

int NAME(fflush)(struct FILE_s *f) {
    if (!f) {
        int rc = 0;
        LIST_LOCK();
        for (struct FILE_s *p = open_streams; p; p = p->next)
            if ((p->flags & F_WRITE) && p->wpos && flush_out(p) != 0) rc = -1;
        LIST_UNLOCK();
        return rc;
    }
    int rc = 0;
    if (f->wpos && flush_out(f) != 0) rc = -1;
    if (f->rend > f->rpos && (f->flags & F_READ)) {
        /* glibc: flushing an input stream moves the descriptor to the logical position and drops the window. */
        if (drop_readahead(f) != 0) rc = -1;
    }
    return rc;
}

int NAME(fclose)(struct FILE_s *f) {
    int rc = 0;
    if (f->wpos && flush_out(f) != 0) rc = -1;
    int saved = errno;
    if (f->rend > f->rpos) drop_readahead(f);
    long r = IO_CLOSE(f->fd);
    if (r < 0 && rc == 0) {
        errno = (int)-r;
        rc = -1;
    } else if (rc != 0) {
        errno = saved;
    }
    list_remove(f);
    if (f->buf && !(f->flags & F_USERBUF)) MEM_FREE(f->buf);
    if (!(f->flags & F_STATIC)) MEM_FREE(f);
    return rc;
}

/* ---- flags ----------------------------------------------------------------------------------------------------- */

int NAME(feof)(struct FILE_s *f) { return (f->flags & F_EOF) != 0; }
int NAME(ferror)(struct FILE_s *f) { return (f->flags & F_ERR) != 0; }
void NAME(clearerr)(struct FILE_s *f) { f->flags &= ~(F_EOF | F_ERR); }

int NAME(setvbuf)(struct FILE_s *f, char *buf, int mode, size_t size) {
    if (mode != 0 && mode != 1 && mode != 2) return -1;
    if (f->wpos && flush_out(f) != 0) return -1;
    f->bmode = mode == 2 ? FB_NONE : mode == 1 ? FB_LINE : FB_FULL;
    f->bufmode_fixed = 1;
    if (buf && size >= 2 && !f->buf) {
        f->buf = (unsigned char *)buf;
        f->bufsize = size;
        f->flags |= F_USERBUF;
    }
    return 0;
}

/* ---- reading --------------------------------------------------------------------------------------------------- */

int NAME(fgetc)(struct FILE_s *f) {
    if (begin_read(f) != 0) return -1;
    if (f->rpos >= f->rend) {
        long n = fill(f);
        if (n <= 0) return -1;
    }
    return f->buf[f->rpos++];
}

int NAME(getc)(struct FILE_s *f) { return NAME(fgetc)(f); }

size_t NAME(fread)(void *ptr, size_t size, size_t nmemb, struct FILE_s *f) {
    if (size == 0 || nmemb == 0) return 0;
    if (nmemb > (size_t)-1 / size) return 0; /* the product does not fit: nothing happens (glibc) */
    if (begin_read(f) != 0) return 0;
    size_t want = size * nmemb, got = 0;
    unsigned char *out = (unsigned char *)ptr;
    while (got < want) {
        if (f->rpos >= f->rend) {
            long n = fill(f);
            if (n <= 0) break;
        }
        size_t take = f->rend - f->rpos;
        if (take > want - got) take = want - got;
        memcpy(out + got, f->buf + f->rpos, take);
        f->rpos += take;
        got += take;
    }
    return got / size;
}

char *NAME(fgets)(char *s, int n, struct FILE_s *f) {
    if (n <= 0) return (char *)0;
    if (n == 1) { /* never reads, so not even the direction matters (glibc) */
        s[0] = 0;
        return s;
    }
    if (begin_read(f) != 0) return (char *)0;
    int i = 0;
    while (i < n - 1) {
        if (f->rpos >= f->rend) {
            long r = fill(f);
            if (r <= 0) break;
        }
        unsigned char c = f->buf[f->rpos++];
        s[i++] = (char)c;
        if (c == '\n') break;
    }
    if (i == 0) return (char *)0;
    s[i] = 0;
    return s;
}

int NAME(ungetc)(int c, struct FILE_s *f) {
    if (c == -1) return -1;
    if (!(f->flags & F_READ)) {
        errno = EBADF;
        return -1;
    }
    if (f->wpos && flush_out(f) != 0) return -1;
    if (ensure_buf(f) != 0) return -1;
    if (f->rend == 0 && f->rpos == 0) {
        /* nothing read yet: make room by starting the window in the middle of the buffer. The pushed bytes are not part
         * of the descriptor's data, so ftell ignores them (glibc reports the start of the file). */
        f->rpos = f->rend = f->bufsize > 16 ? 16 : 0;
        f->flags |= F_FRESH;
    }
    if (f->rpos == 0) {
        /* no room in front: shift the window up when there is slack behind it */
        if (f->rend >= f->bufsize) return -1;
        size_t shift = 16 < f->bufsize - f->rend ? 16 : f->bufsize - f->rend;
        memmove(f->buf + shift, f->buf, f->rend);
        f->rpos += shift;
        f->rend += shift;
    }
    f->buf[--f->rpos] = (unsigned char)c;
    f->flags &= ~F_EOF;
    return (unsigned char)c;
}

long NAME(getdelim)(char **lineptr, size_t *n, int delim, struct FILE_s *f) {
    if (!lineptr || !n) {
        errno = EINVAL;
        return -1;
    }
    if (begin_read(f) != 0) return -1;
    size_t len = 0;
    for (;;) {
        if (f->rpos >= f->rend) {
            long r = fill(f);
            if (r < 0) return -1;
            if (r == 0) {
                if (len == 0) return -1;
                break;
            }
        }
        if (len + 2 > *n) {
            size_t nc = *n ? *n * 2 : 120;
            while (nc < len + 2) nc *= 2;
            char *np = (char *)MEM_ALLOC(nc);
            if (!np) {
                errno = ENOMEM;
                return -1;
            }
            if (*lineptr) {
                memcpy(np, *lineptr, len);
                MEM_FREE(*lineptr);
            }
            *lineptr = np;
            *n = nc;
        }
        unsigned char c = f->buf[f->rpos++];
        (*lineptr)[len++] = (char)c;
        if (c == (unsigned char)delim) break;
    }
    (*lineptr)[len] = 0;
    return (long)len;
}

long NAME(getline)(char **lineptr, size_t *n, struct FILE_s *f) { return NAME(getdelim)(lineptr, n, '\n', f); }

/* ---- writing --------------------------------------------------------------------------------------------------- */

/* Write all of p[0..n) straight to the descriptor. */
static int write_direct(struct FILE_s *f, const unsigned char *p, size_t n) {
    size_t done = 0;
    while (done < n) {
        long r = IO_WRITE(f->fd, p + done, n - done);
        if (r == -EINTR) continue;
        if (r < 0) return set_err(f, r);
        if (r == 0) return set_err(f, -EIO);
        done += (size_t)r;
    }
    return 0;
}

/* Output follows glibc's xsputn, measured: copy what fits into the buffer; if bytes remain, flush the buffer, write whole
 * blocks of the rest directly and buffer the tail. A stream that has no buffer yet counts as having no room, so a write of
 * a whole block on a fresh stream goes out at once; a buffer that is exactly full is flushed by the NEXT write, not this
 * one. A line-buffered stream writes up to and including the last newline of each call. */
static int put_bytes(struct FILE_s *f, const unsigned char *p, size_t n) {
    if (begin_write(f) != 0) return -1;
    if (f->bmode == FB_NONE) {
        if (f->wpos && flush_out(f) != 0) return -1;
        return write_direct(f, p, n);
    }
    size_t room = f->wpos < f->bufsize ? f->bufsize - f->wpos : 0;
    if (f->fresh_buf) room = 0;
    size_t copy = n < room ? n : room;
    if (copy) memcpy(f->buf + f->wpos, p, copy);
    f->wpos += copy;
    f->fresh_buf = 0;
    size_t rest = n - copy;
    if (rest) {
        if (f->wpos && flush_out(f) != 0) return -1;
        size_t direct = rest - rest % f->bufsize;
        if (direct && write_direct(f, p + copy, direct) != 0) return -1;
        size_t tail = rest - direct;
        if (tail) memcpy(f->buf, p + copy + direct, tail);
        f->wpos = tail;
    }
    if (f->bmode == FB_LINE) {
        /* flush up to and including the last newline written by this call */
        size_t last = n;
        while (last > 0 && p[last - 1] != '\n') last--;
        if (last > 0) {
            size_t keep = n - last; /* bytes after the last newline stay buffered */
            if (keep <= f->wpos) {
                size_t total = f->wpos;
                f->wpos = total - keep;
                if (flush_out(f) != 0) return -1;
                if (keep) memmove(f->buf, p + last, keep);
                f->wpos = keep;
            }
        }
    }
    return 0;
}

int NAME(fputc)(int c, struct FILE_s *f) {
    unsigned char ch = (unsigned char)c;
    if (put_bytes(f, &ch, 1) != 0) return -1;
    return ch;
}

int NAME(putc)(int c, struct FILE_s *f) { return NAME(fputc)(c, f); }

int NAME(fputs)(const char *s, struct FILE_s *f) {
    size_t n = strlen(s);
    if (n == 0) return 1; /* writes nothing, so it cannot fail, even on a read-only stream (glibc) */
    if (put_bytes(f, (const unsigned char *)s, n) != 0) return -1;
    return 1;
}

size_t NAME(fwrite)(const void *ptr, size_t size, size_t nmemb, struct FILE_s *f) {
    if (size == 0 || nmemb == 0) return 0;
    if (nmemb > (size_t)-1 / size) return 0;
    if (put_bytes(f, (const unsigned char *)ptr, size * nmemb) != 0) return 0;
    return nmemb;
}

/* ---- positioning ----------------------------------------------------------------------------------------------- */

long NAME(ftell)(struct FILE_s *f) {
    long base = IO_LSEEK(f->fd, 0, 1);
    if (base < 0) {
        errno = (int)-base;
        return -1;
    }
    if (f->flags & F_FRESH) return base + (long)f->wpos;
    return base - (long)(f->rend - f->rpos) + (long)f->wpos;
}

int NAME(fseek)(struct FILE_s *f, long off, int whence) {
    if (whence < 0 || whence > 2) {
        errno = EINVAL;
        return -1;
    }
    if (f->wpos && flush_out(f) != 0) return -1;
    long adj = off;
    if (whence == 1 && !(f->flags & F_FRESH)) adj -= (long)(f->rend - f->rpos); /* the descriptor is ahead of the logical position */
    f->rpos = f->rend = 0;
    f->flags &= ~F_FRESH;
    long r = IO_LSEEK(f->fd, adj, whence);
    if (r < 0) {
        errno = (int)-r;
        return -1;
    }
    f->flags &= ~F_EOF;
    return 0;
}

void NAME(rewind)(struct FILE_s *f) {
    NAME(fseek)(f, 0, 0);
    f->flags &= ~F_ERR;
}

/* ---- formatted output ------------------------------------------------------------------------------------------ */

static int stream_sink(void *ctx, const char *data, size_t n) {
    struct FILE_s *f = (struct FILE_s *)ctx;
    if (put_bytes(f, (const unsigned char *)data, n) != 0) return errno ? errno : EIO;
    return 0;
}

int NAME(vfprintf)(struct FILE_s *f, const char *fmt, va_list ap) {
    if (!(f->flags & F_WRITE)) {
        errno = EBADF;
        f->flags |= F_ERR;
        return -1;
    }
    char chunk[512];
    return __moqi_vformat(chunk, sizeof chunk, stream_sink, f, fmt, ap);
}

int NAME(fprintf)(struct FILE_s *f, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = NAME(vfprintf)(f, fmt, ap);
    va_end(ap);
    return n;
}
