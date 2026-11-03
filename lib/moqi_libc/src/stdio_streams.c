/* stdio_streams.c — the FILE streams in the freestanding build: stdio_file.c bound to the system calls, plus the three
 * standard streams. (The same implementation is compiled against an in-memory file system by host_tests/test_file_abi.c.)
 */
#include "../include/errno.h"
#include "../include/stdio.h"
#include "../include/stdlib.h"
#include "../include/string.h"
#include "../include/unistd.h"
#include "../include/moqi_syscalls.h"

extern int __moqi_vformat(char *buf, size_t size, moqi_sink_fn sink, void *ctx, const char *fmt, va_list ap);
#define SYS_FCNTL 142
#define NAME(x) x
#define IO_OPEN(p, f, m) open(p, f, m)
#define IO_READ(fd, b, n) read(fd, b, n)
#define IO_WRITE(fd, b, n) write(fd, b, n)
#define IO_LSEEK(fd, o, w) lseek(fd, o, w)
#define IO_CLOSE(fd) close(fd)
#define IO_GETFL(fd) syscall3(SYS_FCNTL, fd, 3, 0)
#define MEM_ALLOC(n) malloc(n)
#define MEM_FREE(p) free(p)

/* The list of open streams is shared by every thread; the critical sections are a few pointer moves (and, for
 * fflush(NULL), the writes of the buffered bytes). The lock word is a plain spin lock that yields when contended. */
static volatile int list_lk;
static void list_lock(void) {
    unsigned int spins = 0;
    while (__atomic_exchange_n(&list_lk, 1, __ATOMIC_ACQUIRE)) {
        if ((++spins & 63U) == 0) yield();
    }
}
static void list_unlock(void) { __atomic_store_n(&list_lk, 0, __ATOMIC_RELEASE); }
#define LIST_LOCK() list_lock()
#define LIST_UNLOCK() list_unlock()
#include "stdio_file.c"

static struct FILE_s std_in = { .fd = 0, .flags = F_READ | F_STATIC, .bmode = FB_FULL, .bufmode_fixed = 1 };
static struct FILE_s std_out = { .fd = 1, .flags = F_WRITE | F_STATIC, .bmode = FB_LINE, .bufmode_fixed = 1 };
static struct FILE_s std_err = { .fd = 2, .flags = F_WRITE | F_STATIC, .bmode = FB_NONE, .bufmode_fixed = 1 };
FILE *stdin = &std_in;
FILE *stdout = &std_out;
FILE *stderr = &std_err;

int fflush_all(void) { return fflush((FILE *)0); }
