/* test_file_abi.c — the FILE layer (fopen, fclose, fread, fwrite, fgets, fgetc, fputs, fputc, ungetc, fseek, ftell,
 * fflush, feof, ferror, clearerr, setvbuf, getline, fprintf, ...) checked against values measured on glibc.
 *
 * The stream code is syscall-free: it performs its I/O through the functions the test supplies (open, read, write, lseek,
 * close, fcntl, and malloc/free), here backed by an in-memory file system that can also fail and return short counts on
 * demand. Every expectation below is a value glibc produced on the same sequence of calls.
 */
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../include/errno.h"
#undef errno

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }
#define EIO_ 5


/* ---- an in-memory file system behind open/read/write/lseek/close ------------------------------------------------- */

#define MAXF 8
#define FSIZE 262144
struct memfile {
    char name[32];
    unsigned char data[FSIZE];
    long size;
    int used;
    int is_dir;
};
static struct memfile files[MAXF];
struct fdent {
    int used;
    struct memfile *f;
    long off;
    int flags;
    int pipe; /* not seekable */
};
static struct fdent fds[32];
static int io_calls_read, io_calls_write;
static long short_write_limit;   /* >0: write() accepts at most this many bytes per call */
static int fail_write_after;     /* >0: the Nth write from now fails with -EIO (5) */
static int fail_read_after;
static long read_chunk_limit;    /* >0: read() returns at most this many bytes per call */
static int open_calls;
static int lenient_write;
static int lseek_calls;
static int fail_malloc;
static int interrupt_next_read, interrupt_next_write, zero_write_once;

#define T_O_RDONLY 0
#define T_O_WRONLY 1
#define T_O_RDWR 2
#define T_O_CREAT 0x40
#define T_O_EXCL 0x80
#define T_O_TRUNC 0x200
#define T_O_APPEND 0x400

long test_open(const char *path, long flags, long mode) {
    (void)mode;
    open_calls++;
    struct memfile *f = 0;
    for (int i = 0; i < MAXF; i++)
        if (files[i].used && strcmp(files[i].name, path) == 0) f = &files[i];
    if (f && (flags & T_O_CREAT) && (flags & T_O_EXCL)) return -EEXIST;
    if (!f) {
        if (!(flags & T_O_CREAT)) return -ENOENT;
        for (int i = 0; i < MAXF; i++)
            if (!files[i].used) {
                f = &files[i];
                memset(f, 0, sizeof *f);
                f->used = 1;
                strcpy(f->name, path);
                break;
            }
        if (!f) return -ENFILE;
    }
    if (f->is_dir && ((flags & 3) != T_O_RDONLY)) return -EISDIR;
    if (flags & T_O_TRUNC) f->size = 0;
    for (int i = 3; i < 32; i++)
        if (!fds[i].used) {
            fds[i].used = 1;
            fds[i].f = f;
            fds[i].off = 0;
            fds[i].flags = (int)flags;
            fds[i].pipe = 0;
            return i;
        }
    return -EMFILE;
}
long test_close(int fd) {
    if (fd < 0 || fd >= 32 || !fds[fd].used) return -EBADF;
    fds[fd].used = 0;
    return 0;
}
long test_read(int fd, void *buf, size_t n) {
    io_calls_read++;
    if (fd < 0 || fd >= 32 || !fds[fd].used) return -EBADF;
    if (interrupt_next_read > 0) { interrupt_next_read--; return -4; }
    if (fail_read_after && --fail_read_after == 0) return -EIO;
    if ((fds[fd].flags & 3) == T_O_WRONLY && !lenient_write) return -EBADF;
    if (fds[fd].f->is_dir) return -EISDIR;
    if (read_chunk_limit > 0 && (long)n > read_chunk_limit) n = (size_t)read_chunk_limit;
    long avail = fds[fd].f->size - fds[fd].off;
    if (avail < 0) avail = 0;
    if ((long)n > avail) n = (size_t)avail;
    memcpy(buf, fds[fd].f->data + fds[fd].off, n);
    fds[fd].off += (long)n;
    return (long)n;
}
long test_write(int fd, const void *buf, size_t n) {
    io_calls_write++;
    if (fd < 0 || fd >= 32 || !fds[fd].used) return -EBADF;
    if (interrupt_next_write > 0) { interrupt_next_write--; return -4; }
    if (zero_write_once) { zero_write_once = 0; return 0; }
    if (fail_write_after && --fail_write_after == 0) return -EIO;
    if ((fds[fd].flags & 3) == T_O_RDONLY && !lenient_write) return -EBADF;
    if (short_write_limit > 0 && (long)n > short_write_limit) n = (size_t)short_write_limit;
    struct fdent *e = &fds[fd];
    if (e->flags & T_O_APPEND) e->off = e->f->size;
    if (e->off + (long)n > FSIZE) return -27; /* EFBIG */
    if (e->off > e->f->size) memset(e->f->data + e->f->size, 0, (size_t)(e->off - e->f->size));
    memcpy(e->f->data + e->off, buf, n);
    e->off += (long)n;
    if (e->off > e->f->size) e->f->size = e->off;
    return (long)n;
}
long test_lseek(int fd, long off, int whence) {
    if (fd < 0 || fd >= 32 || !fds[fd].used) return -EBADF;
    if (fds[fd].pipe) return -ESPIPE;
    lseek_calls++;
    long base = whence == 0 ? 0 : whence == 1 ? fds[fd].off : whence == 2 ? fds[fd].f->size : whence == 3 ? 0 : -1;
    if (base < 0) return -EINVAL;
    if (base + off < 0) return -EINVAL;
    fds[fd].off = base + off;
    return fds[fd].off;
}
long test_fcntl_getfl(int fd) {
    if (fd < 0 || fd >= 32 || !fds[fd].used) return -EBADF;
    return fds[fd].flags;
}
void *test_malloc(size_t n);
void *test_realloc(void *p, size_t n);
void test_free(void *p);

#define NAME(x) m##x
#define IO_OPEN(p, f, m) test_open(p, f, m)
#define IO_READ(fd, b, n) test_read(fd, b, n)
#define IO_WRITE(fd, b, n) test_write(fd, b, n)
#define IO_LSEEK(fd, o, w) test_lseek(fd, o, w)
#define IO_CLOSE(fd) test_close(fd)
#define IO_GETFL(fd) test_fcntl_getfl(fd)
#define MEM_ALLOC(n) test_malloc(n)
#define MEM_FREE(p) test_free(p)
#define MEM_REALLOC(p, n) test_realloc(p, n)
#define LIST_LOCK() (void)0
#define LIST_UNLOCK() (void)0
#include <stdarg.h>
#undef errno
#define errno errno_slot
int *__moqi_dummy_errno(void);
typedef int (*moqi_sink_fn)(void *ctx, const char *data, size_t n);
int __moqi_vformat(char *buf, size_t size, moqi_sink_fn sink, void *ctx, const char *fmt, va_list ap);
#include "../src/stdio_file.c"
typedef struct FILE_s MFILE;
#define M_IOFBF 0
#define M_IOLBF 1
#define M_IONBF 2

void *test_malloc(size_t n) {
    if (fail_malloc) return (void *)0;
    return __builtin_malloc(n);
}
void test_free(void *p) { __builtin_free(p); }
void *test_realloc(void *p, size_t n) {
    if (fail_malloc) return (void *)0;
    return __builtin_realloc(p, n);
}

static struct FILE_s std_in = { .fd = 0, .flags = F_READ | F_STATIC, .bmode = FB_FULL, .bufmode_fixed = 1 };
static struct FILE_s std_out = { .fd = 1, .flags = F_WRITE | F_STATIC, .bmode = FB_LINE, .bufmode_fixed = 1 };
static struct FILE_s std_err = { .fd = 2, .flags = F_WRITE | F_STATIC, .bmode = FB_NONE, .bufmode_fixed = 1 };
#define mstdin (&std_in)
#define mstdout (&std_out)
#define mstderr (&std_err)

/* ---- helpers ------------------------------------------------------------------------------------------------------- */

static int test_vfscanf_call(MFILE *f, const char *fmt, ...);
static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static void put_file(const char *name, const char *content, size_t len) {
    long fd = test_open(name, T_O_RDWR | T_O_CREAT | T_O_TRUNC, 0644);
    assert(fd >= 0);
    test_write((int)fd, content, len);
    test_close((int)fd);
}
static long file_size(const char *name) {
    for (int i = 0; i < MAXF; i++)
        if (files[i].used && strcmp(files[i].name, name) == 0) return files[i].size;
    return -1;
}
static const unsigned char *file_data(const char *name) {
    for (int i = 0; i < MAXF; i++)
        if (files[i].used && strcmp(files[i].name, name) == 0) return files[i].data;
    return (const unsigned char *)0;
}
static void reset(void) {
    memset(files, 0, sizeof files);
    memset(fds, 0, sizeof fds);
    short_write_limit = fail_write_after = fail_read_after = 0;
    interrupt_next_read = interrupt_next_write = zero_write_once = 0;
    lenient_write = 0;
    lseek_calls = 0;
    read_chunk_limit = 0;
    fail_malloc = 0;
    io_calls_read = io_calls_write = 0;
    open_calls = 0;
    errno_slot = 0;
}

int main(void) {
    char b[256];
    MFILE *f;

    /* ===== fopen: modes ===== */
    reset();
    put_file("t", "data", 4);
    {
        static const struct { const char *mode; int ok; int err; int rd; int wr; } modes[] = {
            {"r", 1, 0, 1, 0},   {"w", 1, 0, 0, 1},   {"a", 1, 0, 0, 1},   {"r+", 1, 0, 1, 1},  {"w+", 1, 0, 1, 1},
            {"a+", 1, 0, 1, 1},  {"rb", 1, 0, 1, 0},  {"wb", 1, 0, 0, 1},  {"ab", 1, 0, 0, 1},  {"rb+", 1, 0, 1, 1},
            {"r+b", 1, 0, 1, 1}, {"wb+", 1, 0, 1, 1}, {"w+b", 1, 0, 1, 1}, {"ab+", 1, 0, 1, 1}, {"a+b", 1, 0, 1, 1},
            {"re", 1, 0, 1, 0},  {"we", 1, 0, 0, 1},  {"rm", 1, 0, 1, 0},  {"rz", 1, 0, 1, 0},  {"r+z", 1, 0, 1, 1},
            {"r++", 1, 0, 1, 1}, {"rbb", 1, 0, 1, 0}, {"r b", 1, 0, 1, 0}, {"rx", 1, 0, 1, 0},  {"w+b+", 1, 0, 1, 1},
            {"wx", 0, EEXIST, 0, 0}, {"w+x", 0, EEXIST, 0, 0}, {"ax", 0, EEXIST, 0, 0}, {"wxx", 0, EEXIST, 0, 0},
            {"+r", 0, EINVAL, 0, 0}, {"b", 0, EINVAL, 0, 0}, {"R", 0, EINVAL, 0, 0}, {"W", 0, EINVAL, 0, 0}, {"", 0, EINVAL, 0, 0},
            {"z", 0, EINVAL, 0, 0},
        };
        for (unsigned i = 0; i < sizeof modes / sizeof modes[0]; i++) {
            put_file("t", "data", 4);
            errno_slot = 0;
            f = mfopen("t", modes[i].mode);
            if ((f != 0) != modes[i].ok || (!f && errno_slot != modes[i].err)) {
                fprintf(stderr, "mode %s: ok=%d errno=%d, want ok=%d errno=%d\n", modes[i].mode, f != 0, errno_slot, modes[i].ok, modes[i].err);
                bad++;
            }
            if (f) {
                int fl = (int)test_fcntl_getfl(mfileno(f));
                int rd = (fl & 3) == T_O_RDONLY || (fl & 3) == T_O_RDWR;
                int wr = (fl & 3) == T_O_WRONLY || (fl & 3) == T_O_RDWR;
                if (rd != modes[i].rd || wr != modes[i].wr) {
                    fprintf(stderr, "mode %s: access r=%d w=%d, want r=%d w=%d\n", modes[i].mode, rd, wr, modes[i].rd, modes[i].wr);
                    bad++;
                }
                mfclose(f);
            }
        }
    }
    errno_slot = 0;
    CHECK(mfopen("missing", "r") == 0 && errno_slot == ENOENT);
    errno_slot = 0;
    CHECK(mfopen((const char *)0, "r") == 0 && errno_slot == EFAULT);
    errno_slot = 0;
    CHECK(mfopen("t", (const char *)0) == 0 && errno_slot == EINVAL);
    /* The descriptor is closed again when the stream cannot be allocated, and no stream leaks. */
    {
        int before = 0;
        for (int i = 0; i < 32; i++) before += fds[i].used;
        fail_malloc = 1;
        errno_slot = 0;
        CHECK(mfopen("t", "r") == 0 && errno_slot == ENOMEM);
        fail_malloc = 0;
        int after = 0;
        for (int i = 0; i < 32; i++) after += fds[i].used;
        CHECK(before == after);
    }
    /* The directory case: opening a directory for writing fails with EISDIR, for reading it opens (reads then fail). */
    reset();
    files[0].used = 1;
    files[0].is_dir = 1;
    strcpy(files[0].name, "dir");
    errno_slot = 0;
    CHECK(mfopen("dir", "w") == 0 && errno_slot == EISDIR);
    f = mfopen("dir", "r");
    CHECK(f != 0);
    errno_slot = 0;
    CHECK(mfgetc(f) == -1 && errno_slot == EISDIR && mferror(f) && !mfeof(f));
    mfclose(f);

    /* ===== reading: fgets, fgetc, EOF and error flags ===== */
    reset();
    put_file("t", "hello\nworld\n", 12);
    f = mfopen("t", "r");
    CHECK(mfgets(b, sizeof b, f) == b && strcmp(b, "hello\n") == 0);
    CHECK(mfgets(b, sizeof b, f) == b && strcmp(b, "world\n") == 0);
    errno_slot = 0;
    CHECK(mfgets(b, sizeof b, f) == 0 && mfeof(f) && !mferror(f) && errno_slot == 0);
    CHECK(mfgetc(f) == -1 && mfeof(f));
    mclearerr(f);
    CHECK(!mfeof(f) && !mferror(f));
    CHECK(mfgetc(f) == -1 && mfeof(f)); /* EOF again once the stream reads again */
    mfclose(f);

    f = mfopen("t", "r");
    memset(b, 'Q', sizeof b);
    CHECK(mfgets(b, 1, f) == b && b[0] == 0 && mftell(f) == 0); /* n = 1: an empty string, nothing read */
    CHECK(mfgets(b, 2, f) == b && strcmp(b, "h") == 0);
    CHECK(mfgets(b, 0, f) == 0);
    CHECK(mfgets(b, -1, f) == 0);
    mfclose(f);

    /* a short line buffer, a line without a final newline, and an empty-looking end */
    reset();
    put_file("t", "0123456789\nabc\n", 15);
    f = mfopen("t", "r");
    CHECK(mfgets(b, 5, f) && strcmp(b, "0123") == 0);
    CHECK(mfgets(b, 5, f) && strcmp(b, "4567") == 0);
    CHECK(mfgets(b, 5, f) && strcmp(b, "89\n") == 0);
    CHECK(mfgets(b, 5, f) && strcmp(b, "abc\n") == 0);
    CHECK(mfgets(b, 5, f) == 0);
    mfclose(f);
    reset();
    put_file("t", "no newline", 10);
    f = mfopen("t", "r");
    CHECK(mfgets(b, 64, f) && strcmp(b, "no newline") == 0);
    CHECK(mfgets(b, 64, f) == 0 && mfeof(f));
    mfclose(f);
    reset();
    put_file("t", "a\0b", 3);
    f = mfopen("t", "r");
    CHECK(mfread(b, 1, 10, f) == 3 && b[0] == 'a' && b[1] == 0 && b[2] == 'b');
    mfclose(f);

    /* ===== fread / fwrite ===== */
    reset();
    put_file("t", "hello\nworld\n", 12);
    f = mfopen("t", "r");
    CHECK(mfread(b, 1, 64, f) == 12 && mfeof(f) && !mferror(f));
    CHECK(mfread(b, 1, 10, f) == 0);
    mfclose(f);
    f = mfopen("t", "r");
    CHECK(mfread(b, 5, 3, f) == 2 && mftell(f) == 12); /* two whole items, the third is partial: consumed but not counted */
    CHECK(mfread(b, 0, 3, f) == 0);
    CHECK(mfread(b, 3, 0, f) == 0);
    mfclose(f);
    f = mfopen("t", "r");
    errno_slot = 0;
    CHECK(mfread(b, (size_t)1 << 62, 8, f) == 0 && errno_slot == 0 && !mferror(f) && !mfeof(f)); /* overflow: nothing happens */
    CHECK(mfread(b, 3, (size_t)0x5555555555555556u, f) == 0 && mftell(f) == 0); /* 3 * that wraps to 2: still nothing happens */
    CHECK(mftell(f) == 0);
    errno_slot = 0;
    CHECK(mfwrite(b, (size_t)1 << 62, 8, f) == 0 && errno_slot == 0 && !mferror(f));
    mfclose(f);

    /* ===== writing: buffered until flushed ===== */
    reset();
    f = mfopen("t", "w");
    CHECK(mfputs("abc", f) >= 0);
    CHECK(file_size("t") == 0 && io_calls_write == 0); /* default file buffering: nothing visible before the flush */
    CHECK(mfflush(f) == 0 && file_size("t") == 3);
    CHECK(mfputc('d', f) == 'd' && mputc('e', f) == 'e');
    CHECK(mfwrite("fg", 1, 2, f) == 2 && mfwrite("", 0, 5, f) == 0);
    CHECK(mfputs("", f) >= 0);
    CHECK(mfclose(f) == 0 && file_size("t") == 7 && memcmp(file_data("t"), "abcdefg", 7) == 0);
    reset();
    f = mfopen("t", "w");
    CHECK(mfputc(300, f) == 44 && mfputc(-1, f) == 255); /* converted to unsigned char */
    mfclose(f);
    CHECK(file_size("t") == 2 && file_data("t")[0] == 44 && file_data("t")[1] == 255);

    /* big writes bypass the buffer but keep their order */
    reset();
    {
        static char big[20000];
        for (int i = 0; i < 20000; i++) big[i] = (char)('a' + i % 26);
        f = mfopen("t", "w");
        CHECK(mfwrite(big, 1, 5000, f) == 5000);
        CHECK(mfwrite(big, 1, 100, f) == 100);
        CHECK(mfwrite(big, 1, 15000, f) == 15000);
        CHECK(mfclose(f) == 0 && file_size("t") == 20100);
        CHECK(memcmp(file_data("t"), big, 5000) == 0 && memcmp(file_data("t") + 5000, big, 100) == 0 && memcmp(file_data("t") + 5100, big, 15000) == 0);
    }

    /* ===== unbuffered and line-buffered ===== */
    reset();
    f = mfopen("t", "w");
    CHECK(msetvbuf(f, 0, M_IONBF, 0) == 0);
    mfputs("abc", f);
    CHECK(file_size("t") == 3);
    mfclose(f);
    reset();
    f = mfopen("t", "w");
    CHECK(msetvbuf(f, 0, M_IOLBF, 0) == 0);
    mfputs("abc", f);
    CHECK(file_size("t") == 0);
    mfputs("def\ngh", f);
    CHECK(file_size("t") == 7); /* up to and including the last newline */
    mfclose(f);
    CHECK(file_size("t") == 9);
    f = mfopen("t", "w");
    errno_slot = 0;
    CHECK(msetvbuf(f, 0, 7, 0) == -1);
    mfclose(f);

    /* ===== write errors: short writes are continued, failures set the error flag ===== */
    reset();
    f = mfopen("t", "w");
    short_write_limit = 3;
    mfputs("0123456789", f);
    CHECK(mfflush(f) == 0 && file_size("t") == 10 && io_calls_write == 4);
    short_write_limit = 0;
    fail_write_after = 1;
    errno_slot = 0;
    mfputs("xyz", f);
    CHECK(mfflush(f) == -1 && errno_slot == EIO && mferror(f));
    mclearerr(f);
    CHECK(!mferror(f));
    mfclose(f);

    /* ===== wrong direction: EBADF and the error flag ===== */
    reset();
    put_file("t", "hello\nworld\n", 12);
    f = mfopen("t", "r");
    errno_slot = 0;
    CHECK(mfputs("x", f) == -1 && errno_slot == EBADF && mferror(f));
    errno_slot = 0;
    CHECK(mfputc('x', f) == -1 && errno_slot == EBADF);
    errno_slot = 0;
    CHECK(mfwrite("x", 1, 1, f) == 0 && errno_slot == EBADF);
    errno_slot = 0;
    CHECK(mfprintf(f, "abc") == -1 && errno_slot == EBADF);
    mfclose(f);
    f = mfopen("t", "w");
    errno_slot = 0;
    CHECK(mfgetc(f) == -1 && errno_slot == EBADF && mferror(f) && !mfeof(f));
    errno_slot = 0;
    CHECK(mfgets(b, 10, f) == 0 && errno_slot == EBADF);
    errno_slot = 0;
    CHECK(mfread(b, 1, 1, f) == 0 && errno_slot == EBADF);
    mfclose(f);

    /* ===== seeking, ftell and the read-ahead buffer ===== */
    reset();
    put_file("t", "hello\nworld\n", 12);
    f = mfopen("t", "r");
    mfgets(b, 64, f);
    CHECK(mftell(f) == 6);
    CHECK(mfseek(f, 2, 0) == 0 && mfgetc(f) == 'l');
    CHECK(mfseek(f, 0, 2) == 0 && mftell(f) == 12);
    CHECK(mfgetc(f) == -1 && mfeof(f));
    CHECK(mfseek(f, 0, 0) == 0 && !mfeof(f)); /* a successful seek clears EOF */
    errno_slot = 0;
    CHECK(mfseek(f, 0, 99) == -1 && errno_slot == EINVAL);
    errno_slot = 0;
    CHECK(mfseek(f, -5, 0) == -1 && errno_slot == EINVAL);
    CHECK(mfgetc(f) == 'h'); /* a failed seek leaves the position alone */
    mrewind(f);
    CHECK(mfgetc(f) == 'h');
    mfclose(f);
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    mfgetc(f); mfgetc(f); mfgetc(f);
    CHECK(mfseek(f, 2, 1) == 0 && mftell(f) == 5 && mfgetc(f) == '5'); /* SEEK_CUR is relative to the logical position */
    CHECK(mfseek(f, -3, 1) == 0 && mftell(f) == 3 && mfgetc(f) == '3');
    CHECK(mfseek(f, -1, 2) == 0 && mfgetc(f) == '9');
    CHECK(mfseek(f, 5, 2) == 0 && mftell(f) == 15 && mfgetc(f) == -1);
    mfclose(f);
    /* ftell counts buffered writes; the fd is only moved by the flush */
    reset();
    f = mfopen("t", "w");
    mfputs("12345", f);
    CHECK(mftell(f) == 5);
    mfclose(f);
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "a");
    CHECK(mftell(f) == 10);
    mfputs("12345", f);
    CHECK(mftell(f) == 15);
    mfclose(f);
    /* seeking a pipe fails with ESPIPE, ftell the same */
    reset();
    put_file("t", "x", 1);
    fds[5].used = 1; fds[5].f = &files[0]; fds[5].flags = T_O_RDONLY; fds[5].pipe = 1;
    f = mfdopen(5, "r");
    CHECK(f != 0);
    errno_slot = 0;
    CHECK(mfseek(f, 0, 0) == -1 && errno_slot == ESPIPE);
    errno_slot = 0;
    CHECK(mftell(f) == -1 && errno_slot == ESPIPE);
    CHECK(mfgetc(f) == 'x');
    mfclose(f);

    /* ===== ungetc ===== */
    reset();
    put_file("t", "hello\nworld\n", 12);
    f = mfopen("t", "r");
    CHECK(mungetc('X', f) == 'X');
    CHECK(mfgetc(f) == 'X');
    CHECK(mungetc(-1, f) == -1);
    CHECK(mungetc('A', f) == 'A' && mungetc('B', f) == 'B');
    CHECK(mfgetc(f) == 'B' && mfgetc(f) == 'A' && mfgetc(f) == 'h');
    mfclose(f);
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    mfgetc(f); mfgetc(f);
    CHECK(mungetc('q', f) == 'q' && mftell(f) == 1);
    CHECK(mfseek(f, 0, 1) == 0 && mfgetc(f) == '1'); /* the pushed-back byte is dropped by a seek */
    mfclose(f);
    reset();
    put_file("t", "ab", 2);
    f = mfopen("t", "r");
    CHECK(mfgetc(f) == 'a' && mfgetc(f) == 'b' && mfgetc(f) == -1 && mfeof(f));
    CHECK(mungetc('b', f) == 'b' && !mfeof(f)); /* ungetc clears EOF */
    CHECK(mfgetc(f) == 'b');
    mfclose(f);

    /* ===== EOF is sticky until cleared, even when the file grows ===== */
    reset();
    put_file("t", "ab", 2);
    f = mfopen("t", "r+");
    CHECK(mfgetc(f) == 'a' && mfgetc(f) == 'b' && mfgetc(f) == -1 && mfeof(f));
    {
        long fd2 = test_open("t", T_O_WRONLY | T_O_APPEND, 0);
        test_write((int)fd2, "cd", 2);
        test_close((int)fd2);
    }
    CHECK(mfgetc(f) == -1 && mfeof(f)); /* glibc: the EOF flag stops the read before it asks the fd */
    mclearerr(f);
    CHECK(mfgetc(f) == 'c');
    mfclose(f);

    /* ===== read and write on one stream ===== */
    reset();
    f = mfopen("t", "w+");
    mfputs("abc", f);
    CHECK(mfseek(f, 0, 0) == 0);
    CHECK(mfread(b, 1, 63, f) == 3 && memcmp(b, "abc", 3) == 0);
    mfclose(f);
    reset();
    put_file("t", "hello\nworld\n", 12);
    f = mfopen("t", "r+");
    mfseek(f, 0, 0);
    mfputs("HE", f);
    mfseek(f, 0, 0);
    CHECK(mfread(b, 1, 63, f) == 12 && memcmp(b, "HEllo\nworld\n", 12) == 0);
    mfclose(f);
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r+");
    mfgetc(f); mfgetc(f);
    mfputc('X', f); /* write after read without a seek: lands at the logical position (2), glibc */
    CHECK(mftell(f) == 3);
    mfclose(f);
    CHECK(memcmp(file_data("t"), "01X3456789", 10) == 0);
    reset();
    put_file("t", "hello", 5);
    f = mfopen("t", "a+");
    CHECK(mftell(f) == 5);
    mfputs("def", f);
    mfseek(f, 0, 0);
    CHECK(mfread(b, 1, 63, f) == 8 && memcmp(b, "hellodef", 8) == 0);
    mfclose(f);
    reset();
    f = mfopen("t", "w+");
    mfputs("abcdef", f);
    CHECK(mfgetc(f) == -1 && mfeof(f)); /* read right after write, no seek: the position is at the end */
    mfclose(f);

    /* ===== getline / getdelim ===== */
    reset();
    put_file("t", "line one\nline two\nlast no nl", 28);
    f = mfopen("t", "r");
    {
        char *lp = 0;
        size_t cap = 0;
        long r;
        r = mgetline(&lp, &cap, f);
        CHECK(r == 9 && cap >= 10 && strcmp(lp, "line one\n") == 0);
        r = mgetline(&lp, &cap, f);
        CHECK(r == 9 && strcmp(lp, "line two\n") == 0);
        r = mgetline(&lp, &cap, f);
        CHECK(r == 10 && strcmp(lp, "last no nl") == 0);
        r = mgetline(&lp, &cap, f);
        CHECK(r == -1 && mfeof(f));
        test_free(lp);
        errno_slot = 0;
        mfseek(f, 0, 0);
        r = mgetline((char **)0, &cap, f);
        CHECK(r == -1 && errno_slot == EINVAL);
        lp = 0;
        cap = 0;
        r = mgetdelim(&lp, &cap, 'e', f);
        CHECK(r == 4 && strcmp(lp, "line") == 0 && mftell(f) == 4); /* the delimiter is part of the result */
        r = mgetdelim(&lp, &cap, 'e', f);
        CHECK(r == 4 && strcmp(lp, " one") == 0);
        test_free(lp);
    }
    mfclose(f);

    /* ===== fprintf / fputs families ===== */
    reset();
    f = mfopen("t", "w");
    CHECK(mfprintf(f, "%d-%s-%5.2f", 42, "x", 3.14159) == 10);
    CHECK(mfputc('Z', f) == 'Z' && mputc('Q', f) == 'Q' && mfwrite("12345", 1, 5, f) == 5);
    mfclose(f);
    CHECK(file_size("t") == 17 && memcmp(file_data("t"), "42-x- 3.14ZQ12345", 17) == 0);
    reset();
    f = mfopen("t", "w");
    {
        static char big[3000];
        memset(big, 'k', sizeof big - 1);
        big[sizeof big - 1] = 0;
        CHECK(mfprintf(f, "<%s>", big) == 3001);
    }
    mfclose(f);
    CHECK(file_size("t") == 3001 && file_data("t")[0] == '<' && file_data("t")[3000] == '>');

    /* ===== fclose: flushes, closes the fd, returns the flush error ===== */
    reset();
    f = mfopen("t", "w");
    int fd = mfileno(f);
    mfputs("zzz", f);
    CHECK(mfclose(f) == 0 && file_size("t") == 3 && !fds[fd].used);
    f = mfopen("t", "w");
    fd = mfileno(f);
    mfputs("zzz", f);
    fail_write_after = 1;
    errno_slot = 0;
    CHECK(mfclose(f) == -1 && errno_slot == EIO && !fds[fd].used); /* the fd is closed even when the flush fails */
    reset();
    f = mfopen("t", "w");
    mfputs("zzz", f);
    CHECK(mfflush((MFILE *)0) == 0 && file_size("t") == 3); /* fflush(NULL) flushes every open output stream */
    mfclose(f);

    /* ===== fdopen ===== */
    reset();
    put_file("t", "hello", 5);
    {
        long fd1 = test_open("t", T_O_RDONLY, 0);
        errno_slot = 0;
        CHECK(mfdopen((int)fd1, "w") == 0 && errno_slot == EINVAL); /* the mode must fit the fd's access */
        f = mfdopen((int)fd1, "r");
        CHECK(f != 0 && mfgetc(f) == 'h');
        mfclose(f);
        long fd2 = test_open("t", T_O_RDWR, 0);
        f = mfdopen((int)fd2, "r");
        CHECK(f != 0);
        mfclose(f);
        errno_slot = 0;
        CHECK(mfdopen(999, "r") == 0 && errno_slot == EBADF);
        errno_slot = 0;
        CHECK(mfdopen(0, "z") == 0 && errno_slot == EINVAL);
    }

    /* ===== the standard streams ===== */
    CHECK(mfileno(mstdin) == 0 && mfileno(mstdout) == 1 && mfileno(mstderr) == 2);

    /* ===== a read-ahead buffer reads in blocks, not byte by byte ===== */
    reset();
    {
        static char big[20000];
        for (int i = 0; i < 20000; i++) big[i] = (char)('a' + i % 26);
        put_file("t", big, 20000);
        f = mfopen("t", "r");
        int ok = 1;
        for (int i = 0; i < 20000; i++)
            if (mfgetc(f) != big[i]) { ok = 0; break; }
        CHECK(ok && mfgetc(f) == -1);
        CHECK(io_calls_read <= 6 && io_calls_read >= 5); /* 20000 bytes in 4096-byte blocks, plus the EOF probe */
        mfclose(f);
    }

    /* ===== a read error is a stream error, distinct from EOF ===== */
    reset();
    put_file("t", "hello", 5);
    f = mfopen("t", "r");
    fail_read_after = 1;
    errno_slot = 0;
    CHECK(mfgetc(f) == -1 && errno_slot == EIO && mferror(f) && !mfeof(f));
    mclearerr(f);
    CHECK(mfgetc(f) == 'h');
    mfclose(f);

    /* ===== short reads from the fd do not end the stream ===== */
    reset();
    put_file("t", "hello world", 11);
    f = mfopen("t", "r");
    read_chunk_limit = 3;
    CHECK(mfread(b, 1, 11, f) == 11 && memcmp(b, "hello world", 11) == 0 && !mfeof(f));
    mfclose(f);

    /* ===== glibc-measured details that the cases above did not pin down ===== */
    /* when the first block leaves: 4096 buffered bytes stay, the 4097th byte flushes the 4096 before it */
    reset();
    f = mfopen("t", "w");
    {
        static char big[40000];
        memset(big, 'k', sizeof big);
        mfwrite(big, 1, 4095, f);
        CHECK(file_size("t") == 0);
        mfwrite(big, 1, 1, f);
        CHECK(file_size("t") == 0);
        mfwrite(big, 1, 1, f);
        CHECK(file_size("t") == 4096);
        mfclose(f);
        f = mfopen("t", "w");
        mfwrite(big, 1, 4096, f);
        CHECK(file_size("t") == 4096); /* a write of a whole buffer goes straight out */
        mfclose(f);
        f = mfopen("t", "w");
        mfwrite(big, 1, 10000, f);
        CHECK(file_size("t") == 8192); /* whole blocks out, the remainder stays buffered */
        mfclose(f);
        f = mfopen("t", "w");
        mfwrite(big, 1, 100, f);
        mfwrite(big, 1, 4096, f);
        CHECK(file_size("t") == 4096); /* pending bytes are written first, then the big chunk or part of it */
        mfclose(f);
    }
    /* a write after a seek on an append stream still goes to the end; a write stream opened with w starts empty */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "a");
    mfseek(f, 2, 0);
    mfputs("AB", f);
    mfclose(f);
    CHECK(file_size("t") == 12 && memcmp(file_data("t"), "0123456789AB", 12) == 0);
    f = mfopen("t", "w");
    mfclose(f);
    CHECK(file_size("t") == 0);
    /* fputs of the empty string: succeeds on a writable stream, and also on a read-only one (glibc writes nothing at all) */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    errno_slot = 0;
    CHECK(mfputs("", f) == 1 && errno_slot == 0 && !mferror(f));
    errno_slot = 0;
    CHECK(mfwrite("", 1, 0, f) == 0 && errno_slot == 0);
    errno_slot = 0;
    CHECK(mfprintf(f, "") == -1 && errno_slot == EBADF && mferror(f)); /* but fprintf of "" is a write attempt */
    mfclose(f);
    f = mfopen("t", "w");
    errno_slot = 0;
    CHECK(mfgets(b, 1, f) == b && errno_slot == 0); /* n = 1 never reads: the empty string, even on a write-only stream */
    errno_slot = 0;
    CHECK(mfread(b, 1, 0, f) == 0 && errno_slot == 0);
    mfclose(f);
    reset();
    f = mfopen("t", "w");
    CHECK(mfputs("abc", f) == 1 && mfputs("def", f) == 1);
    mfclose(f);
    /* fseek with a bad whence fails before anything is flushed */
    reset();
    f = mfopen("t", "w");
    mfputs("pending", f);
    errno_slot = 0;
    CHECK(mfseek(f, 0, 99) == -1 && errno_slot == EINVAL && file_size("t") == 0);
    CHECK(mfseek(f, 0, 3) == -1 && errno_slot == EINVAL);
    mfclose(f);
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    errno_slot = 0;
    mfputc('x', f);
    CHECK(mferror(f));
    mrewind(f);
    CHECK(!mferror(f) && !mfeof(f)); /* rewind clears the error flag too */
    mfclose(f);
    /* ftell with a pushed-back byte at the start of the file */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    CHECK(mungetc('X', f) == 'X' && mftell(f) == 0);
    CHECK(mfgetc(f) == 'X' && mftell(f) == 0);
    mfclose(f);
    /* reading after writing on the same stream (no seek between): the pending output goes out first, then reading continues */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r+");
    mfputs("ab", f);
    CHECK(mfread(b, 1, 3, f) == 3 && memcmp(b, "234", 3) == 0 && mftell(f) == 5);
    mfclose(f);
    CHECK(file_size("t") == 10 && memcmp(file_data("t"), "ab23456789", 10) == 0);
    /* a pushed-back byte is dropped by fseek and fflush, and positions count from the logical position: measured on glibc */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    mungetc('X', f);
    CHECK(mfseek(f, 0, 1) == 0 && mftell(f) == 0 && mfgetc(f) == '0');
    mfclose(f);
    f = mfopen("t", "r");
    mungetc('X', f);
    CHECK(mfseek(f, 1, 1) == 0 && mftell(f) == 1 && mfgetc(f) == '1' && mfgetc(f) == '2');
    mfclose(f);
    f = mfopen("t", "r");
    mungetc('X', f);
    CHECK(mfseek(f, 2, 0) == 0 && mfgetc(f) == '2' && mfgetc(f) == '3' && mftell(f) == 4);
    mfclose(f);
    f = mfopen("t", "r+");
    mungetc('X', f);
    CHECK(mfflush(f) == 0 && mftell(f) == 0 && test_lseek(mfileno(f), 0, 1) == 0 && mfgetc(f) == '0' && mfgetc(f) == '1');
    mfclose(f);
    f = mfopen("t", "r");
    mungetc('X', f);
    CHECK(mfclose(f) == 0);
    f = mfopen("t", "r");
    mfgetc(f);
    mungetc('X', f);
    CHECK(mfseek(f, 1, 1) == 0 && mfgetc(f) == '1' && mfgetc(f) == '2' && mftell(f) == 3);
    mfclose(f);
    f = mfopen("t", "r");
    mfgetc(f);
    mungetc('X', f);
    CHECK(mfseek(f, 0, 1) == 0 && mfgetc(f) == '0' && mfgetc(f) == '1');
    mfclose(f);
    f = mfopen("t", "r+");
    mfgetc(f);
    mungetc('X', f);
    CHECK(mfflush(f) == 0 && mfgetc(f) == '0' && mfgetc(f) == '1' && mftell(f) == 2);
    mfclose(f);
    /* fflush on a read stream gives the read-ahead back to the descriptor */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    mfgetc(f);
    mfgetc(f);
    CHECK(fds[mfileno(f)].off == 10);
    CHECK(mfflush(f) == 0 && fds[mfileno(f)].off == 2 && mfgetc(f) == '2');
    mfclose(f);
    /* a stream closed with unread read-ahead leaves a shared descriptor at the logical position */
    reset();
    put_file("t", "0123456789", 10);
    {
        long fd1 = test_open("t", T_O_RDONLY, 0);
        f = mfdopen((int)fd1, "r");
        mfgetc(f);
        mfgetc(f);
        mfgetc(f);
        long off_at_close = -1;
        int keep_fd = (int)fd1;
        fds[keep_fd + 1].used = 0;
        (void)off_at_close;
        mfclose(f);
        (void)keep_fd;
    }
    /* getline when the caller's buffer is exactly the size of the line plus the terminator */
    reset();
    put_file("t", "abcdefg\n", 8);
    f = mfopen("t", "r");
    {
        char *lp = (char *)test_malloc(9);
        size_t cap = 9;
        long r = mgetline(&lp, &cap, f);
        CHECK(r == 8 && cap == 9 && strcmp(lp, "abcdefg\n") == 0);
        test_free(lp);
    }
    mfclose(f);
    reset();
    {
        char longline[302];
        for (int i = 0; i < 300; i++) longline[i] = (char)('a' + i % 26);
        longline[300] = '\n';
        longline[301] = 0;
        put_file("t", longline, 301);
        f = mfopen("t", "r");
        char *lp = (char *)0;
        size_t cap = 0;
        long r = mgetline(&lp, &cap, f);
        CHECK(r == 301 && cap >= 302 && lp[300] == '\n' && lp[301] == 0 && lp[299] == longline[299]);
        test_free(lp);
        mfclose(f);
    }
    /* write interrupted: EINTR from the descriptor is retried, not an error */
    reset();
    {
        f = mfopen("t", "w");
        mfputs("abc", f);
        interrupt_next_write = 2;
        CHECK(mfflush(f) == 0 && file_size("t") == 3 && interrupt_next_write == 0 && !mferror(f));
        mfclose(f);
        put_file("t", "hello", 5);
        f = mfopen("t", "r");
        interrupt_next_read = 2;
        CHECK(mfgetc(f) == 'h' && interrupt_next_read == 0 && !mferror(f));
        mfclose(f);
    }
    /* a write that makes no progress (returns 0) is an I/O error, not an endless loop */
    reset();
    f = mfopen("t", "w");
    mfputs("abc", f);
    zero_write_once = 1;
    errno_slot = 0;
    CHECK(mfflush(f) == -1 && errno_slot == EIO && mferror(f));
    mfclose(f);
    /* a failing write loses the buffered bytes (they are dropped, and the next flush does not retry them) */
    reset();
    f = mfopen("t", "w");
    mfputs("abc", f);
    fail_write_after = 1;
    CHECK(mfflush(f) == -1 && mferror(f));
    CHECK(mfflush(f) == 0 && file_size("t") == 0);
    mfclose(f);
    /* fflush(NULL) reaches every open output stream and leaves the unwritten ones alone */
    reset();
    {
        MFILE *a = mfopen("a", "w");
        MFILE *c2 = mfopen("c", "w");
        mfputs("A", a);
        mfputs("C", c2);
        CHECK(mfflush((MFILE *)0) == 0 && file_size("a") == 1 && file_size("c") == 1);
        mfclose(a);
        mfputs("more", c2);
        mfclose(c2);
        CHECK(file_size("c") == 5);
    }
    /* line buffering: only the part up to the last newline of a chunk is written, the tail stays */
    reset();
    f = mfopen("t", "w");
    msetvbuf(f, 0, M_IOLBF, 0);
    mfputs("one\ntwo\nthr", f);
    CHECK(file_size("t") == 8);
    mfputs("ee\n", f);
    CHECK(file_size("t") == 14);
    mfputc('x', f);
    CHECK(file_size("t") == 14);
    mfputc('\n', f);
    CHECK(file_size("t") == 16);
    mfclose(f);
    /* line buffering with big chunks: what reaches the file is measured on glibc */
    {
        static char big[20000];
        static const struct { size_t len, nl, first, second_nl, disk; } lb[] = {
            {10000, 100, 0, 0, 8192}, {10000, 9999, 0, 0, 10000}, {10000, 9000, 0, 0, 9001},
            {100, 50, 0, 0, 51},      {6000, 5000, 0, 0, 5001},
            {10000, 7500, 0, 0, 8192}, {10000, 8000, 0, 0, 8192}, {10000, 8500, 0, 0, 8501}, {9000, 4000, 0, 0, 8192},
        };
        for (unsigned i = 0; i < sizeof lb / sizeof lb[0]; i++) {
            reset();
            memset(big, 'k', sizeof big);
            big[lb[i].nl] = '\n';
            f = mfopen("t", "w");
            msetvbuf(f, 0, M_IOLBF, 0);
            mfwrite(big, 1, lb[i].len, f);
            if ((size_t)file_size("t") != lb[i].disk) {
                fprintf(stderr, "line buffered %zu bytes, newline at %zu: disk=%ld want %zu\n", lb[i].len, lb[i].nl, file_size("t"), lb[i].disk);
                bad++;
            }
            mfclose(f);
        }
        reset();
        memset(big, 'k', sizeof big);
        f = mfopen("t", "w");
        msetvbuf(f, 0, M_IOLBF, 0);
        mfwrite(big, 1, 3000, f);
        big[0] = '\n';
        mfwrite(big, 1, 2000, f);
        CHECK(file_size("t") == 4096);
        mfclose(f);
    }
    /* a block bigger than the buffer is not split mid-way for an unbuffered stream */
    reset();
    f = mfopen("t", "w");
    msetvbuf(f, 0, M_IONBF, 0);
    io_calls_write = 0;
    mfwrite("abcdefghij", 1, 10, f);
    CHECK(io_calls_write == 1 && file_size("t") == 10);
    mfclose(f);

    /* ===== the library's own checks, with a descriptor that would let anything through ===== */
    reset();
    put_file("t", "hello", 5);
    io_calls_write = 0; /* put_file wrote through the same fake descriptor layer */
    lenient_write = 1;
    f = mfopen("t", "r");
    errno_slot = 0;
    CHECK(mfprintf(f, "abc") == -1 && errno_slot == EBADF && mferror(f)); /* vfprintf checks the direction itself */
    mclearerr(f);
    errno_slot = 0;
    CHECK(mfputs("abc", f) == -1 && errno_slot == EBADF);
    mclearerr(f);
    errno_slot = 0;
    CHECK(mfwrite("abc", 1, 3, f) == 0 && errno_slot == EBADF);
    CHECK(file_size("t") == 5 && io_calls_write == 0); /* nothing reached the descriptor */
    mclearerr(f);
    mfclose(f);
    f = mfopen("t", "w");
    errno_slot = 0;
    CHECK(mfgetc(f) == -1 && errno_slot == EBADF && io_calls_read == 0);
    mfclose(f);
    lenient_write = 0;
    /* fseek: an unknown whence is rejected by the library, before the descriptor is asked */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r");
    lseek_calls = 0;
    errno_slot = 0;
    CHECK(mfseek(f, 0, 3) == -1 && errno_slot == EINVAL && lseek_calls == 0);
    CHECK(mfseek(f, 0, -1) == -1 && errno_slot == EINVAL && lseek_calls == 0);
    mfclose(f);
    /* a read after a write on one stream: the pending output goes out first, in order */
    reset();
    put_file("t", "0123456789", 10);
    f = mfopen("t", "r+");
    mfputs("AB", f);
    CHECK(file_size("t") == 10 && memcmp(file_data("t"), "0123456789", 10) == 0); /* still buffered */
    CHECK(mfgetc(f) == '2'); /* the read flushes AB first, then reads on from the logical position */
    CHECK(memcmp(file_data("t"), "AB23456789", 10) == 0);
    mfclose(f);
    /* a pipe: the read-ahead cannot be given back, which is not an error for fflush or fclose */
    reset();
    put_file("t", "abcdef", 6);
    fds[6].used = 1; fds[6].f = &files[0]; fds[6].flags = T_O_RDONLY; fds[6].pipe = 1;
    f = mfdopen(6, "r");
    CHECK(mfgetc(f) == 'a');
    errno_slot = 0;
    CHECK(mfflush(f) == 0 && !mferror(f));
    CHECK(mfgetc(f) == 'b');
    CHECK(mfclose(f) == 0);
    /* ungetc with room at the front but data behind the window: the window is shifted, not overrun */
    reset();
    {
        static char blk[5000];
        for (int i = 0; i < 5000; i++) blk[i] = (char)('a' + i % 26);
        put_file("t", blk, 5000);
        f = mfopen("t", "r");
        for (int i = 0; i < 4096; i++) mfgetc(f); /* the whole first block consumed */
        CHECK(mfgetc(f) == blk[4096]);
        int ok = 1;
        for (int i = 0; i < 20; i++) ok &= mungetc('A' + i, f) == 'A' + i;
        CHECK(ok);
        for (int i = 19; i >= 0; i--) ok &= mfgetc(f) == 'A' + i;
        CHECK(ok && mfgetc(f) == blk[4097]);
        mfclose(f);
    }
    /* getline: the buffer grows only when it must (len + 2 > cap), and a delimiter ends the line */
    reset();
    put_file("t", "ab\ncd", 5);
    f = mfopen("t", "r");
    {
        char *lp = (char *)test_malloc(3);
        size_t cap = 3;
        long r = mgetline(&lp, &cap, f);
        CHECK(r == 3 && cap >= 4 && strcmp(lp, "ab\n") == 0); /* 3 characters need 4 bytes with the terminator */
        r = mgetline(&lp, &cap, f);
        CHECK(r == 2 && strcmp(lp, "cd") == 0);
        test_free(lp);
    }
    mfclose(f);
    reset();
    put_file("t", "xyz", 3);
    f = mfopen("t", "r");
    {
        char *lp = (char *)0;
        size_t cap = 0;
        long r = mgetdelim(&lp, &cap, 'y', f);
        CHECK(r == 2 && strcmp(lp, "xy") == 0); /* stops AT the delimiter, keeps it, leaves "z" */
        CHECK(mfgetc(f) == 'z');
        test_free(lp);
    }
    mfclose(f);


    /* ===== fscanf: stream-level behavior, measured on glibc ===== */
    {
        int a = -1, b = -1;
        char sb[32];
        /* a write-only stream: EBADF, return -1, and no error flag (glibc does not set it for scanf) */
        reset();
        put_file("t", "5 6", 3);
        f = mfopen("t", "w");
        errno_slot = 0;
        CHECK(mfscanf(f, "%d", &a) == -1 && errno_slot == EBADF && !mferror(f) && !mfeof(f));
        errno_slot = 0;
        CHECK(mfscanf(f, (const char *)0, &a) == -1 && errno_slot == EBADF);
        mfclose(f);
        /* a NULL format on a readable stream: EINVAL, nothing consumed */
        reset();
        put_file("t", "5 6", 3);
        f = mfopen("t", "r");
        errno_slot = 0;
        CHECK(mfscanf(f, (const char *)0, &a) == -1 && errno_slot == EINVAL && mftell(f) == 0 && !mferror(f));
        CHECK(mfscanf(f, "") == 0 && mftell(f) == 0);
        /* the lookahead byte is pushed back, so the next reader sees it */
        CHECK(mfscanf(f, "%d", &a) == 1 && a == 5 && mftell(f) == 1 && mfgetc(f) == ' ');
        CHECK(mfscanf(f, "%d", &b) == 1 && b == 6 && mfeof(f) && mftell(f) == 3);
        CHECK(mfscanf(f, "%d", &b) == -1 && mfeof(f) && !mferror(f));
        mfclose(f);
        /* a number that ends the file sets EOF; an exact match of the format does too, as the lookahead hits the end */
        reset();
        put_file("t", "3 4", 3);
        f = mfopen("t", "r");
        CHECK(mfscanf(f, "%d %d", &a, &b) == 2 && a == 3 && b == 4 && mfeof(f) && mftell(f) == 3);
        mfclose(f);
        /* a mismatch is not an end of file */
        reset();
        put_file("t", "x", 1);
        f = mfopen("t", "r");
        CHECK(mfscanf(f, "%d", &a) == 0 && !mfeof(f) && mftell(f) == 0 && mfgetc(f) == 'x');
        mfclose(f);
        /* mixed with fgets / fgetc / ungetc */
        reset();
        put_file("t", "5 rest of line\nnext\n", 20);
        f = mfopen("t", "r");
        CHECK(mfscanf(f, "%d", &a) == 1 && a == 5);
        CHECK(mfgets(sb, sizeof sb, f) && strcmp(sb, " rest of line\n") == 0);
        CHECK(mfgets(sb, sizeof sb, f) && strcmp(sb, "next\n") == 0);
        mfclose(f);
        reset();
        put_file("t", "34", 2);
        f = mfopen("t", "r");
        CHECK(mungetc('9', f) == '9' && mfscanf(f, "%d", &a) == 1 && a == 934 && mftell(f) == 2);
        mfclose(f);
        /* a field that spans a buffer refill */
        reset();
        {
            static char blk[4200];
            memset(blk, ' ', 4094);
            memcpy(blk + 4094, "12345 6", 7);
            put_file("t", blk, 4101);
            f = mfopen("t", "r");
            CHECK(mfscanf(f, "%d %d", &a, &b) == 2 && a == 12345 && b == 6 && mftell(f) == 4101);
            mfclose(f);
        }
        /* a long token is fine: the engine does not buffer strings, the caller's array does */
        reset();
        {
            static char blk[6000];
            memset(blk, '1', 5000);
            memcpy(blk + 5000, " 7", 3);
            put_file("t", blk, 5002);
            static char big[6000];
            f = mfopen("t", "r");
            CHECK(mfscanf(f, "%5990s %d", big, &a) == 2 && strlen(big) == 5000 && a == 7);
            mfclose(f);
        }
        /* a read error part-way: what was read is converted, the error flag and errno are the system's */
        reset();
        put_file("t", "12 34", 5);
        f = mfopen("t", "r");
        fail_read_after = 1;
        errno_slot = 0;
        CHECK(mfscanf(f, "%d", &a) == -1 && mferror(f) && errno_slot == EIO_);
        mfclose(f);
        /* end of file: nothing is read again from the descriptor once it was seen */
        reset();
        put_file("t", "7", 1);
        f = mfopen("t", "r");
        CHECK(mfscanf(f, "%d", &a) == 1 && a == 7 && mfeof(f));
        io_calls_read = 0;
        CHECK(mfscanf(f, "%d", &a) == -1 && io_calls_read == 0);
        mfclose(f);
        /* a stream with pending output: it goes out first, then the read starts at the end of the file */
        reset();
        f = mfopen("t", "w+");
        mfputs("12 34", f);
        errno_slot = 0;
        a = 5;
        CHECK(mfscanf(f, "%d", &a) == -1 && a == 5 && mfeof(f) && !mferror(f) && mftell(f) == 5 && file_size("t") == 5);
        mrewind(f);
        CHECK(mfscanf(f, "%d", &a) == 1 && a == 12);
        mfclose(f);
        /* the allocating modifier goes through the stream's allocator */
        reset();
        put_file("t", "hello world", 11);
        f = mfopen("t", "r");
        {
            char *w1 = (char *)0, *w2 = (char *)0;
            CHECK(mfscanf(f, "%ms %ms", &w1, &w2) == 2 && w1 && w2 && strcmp(w1, "hello") == 0 && strcmp(w2, "world") == 0);
            test_free(w1);
            test_free(w2);
        }
        mfclose(f);
        /* vfscanf is what fscanf is built on */
        reset();
        put_file("t", "8 9", 3);
        f = mfopen("t", "r");
        {
            int x = 0, y = 0;
            CHECK(test_vfscanf_call(f, "%d %d", &x, &y) == 2 && x == 8 && y == 9);
        }
        mfclose(f);
    }

    if (bad) {
        fprintf(stderr, "test_file_abi: %d failures\n", bad);
        return 1;
    }
    printf("test_file_abi OK\n");
    return 0;
}

static int test_vfscanf_call(MFILE *f, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = mvfscanf(f, fmt, ap);
    va_end(ap);
    return r;
}
