/* servers/syslogd/main.c — MoQiOS system log daemon (first userspace system
 * service), built against moqi_libc like servers/init/main.c.
 *
 * Design (kmsg consumer pattern):
 *  - Opens /dev/kmsg read-only. The kernel gives each fd an independent
 *    cursor into the kernel log ring; offset 0 means the oldest available
 *    byte. Since J3 the read() blocks at the newest byte until a log line
 *    is appended (or a signal interrupts it), so the daemon is fully
 *    event-driven — no poll loop, no nanosleep.
 *  - Main loop: blocking-read whatever is available and append it to the
 *    log file. read() returning 0 means a non-blocking/edge case (nothing
 *    to do); a negative return other than -EINTR is unexpected but must
 *    never wedge the daemon, so it just retries.
 *  - Rotation: the log file is opened O_WRONLY|O_CREAT|O_APPEND (= 0x441 in
 *    this kernel's flag encoding, see lib/moqi_libc/include/unistd.h).
 *    tmpfs (kernel/fs/tmpfs.zig) imposes a hard per-file cap of exactly
 *    256 KiB (PAGES_PER_FILE * PAGE_SIZE) and refuses/short-writes at the
 *    cap, so we rotate *before* a write would push the file past 256 KiB:
 *    close and re-open with O_TRUNC (combined with O_APPEND so append
 *    semantics are preserved for subsequent writes). Single-generation
 *    rotation: old content is discarded, no .1/.2 backup files.
 *
 * Log path: /tmp/kern.log. There is no global filesystem root in the vfs
 * open path — only "/tmp"-prefixed paths are routed to tmpfs with O_CREAT
 * support (kernel/fs/vfs.zig FdTable.open); any other absolute path such
 * as /var/log/kern.log falls through to the read-only ramdisk lookup and
 * cannot be created. Hence tmpfs is the only writable location today.
 */

#include <stdio.h>
#include <unistd.h>

#define KMSG_PATH "/dev/kmsg"
#define LOG_PATH  "/tmp/kern.log"

/* Rotation threshold. Equals the tmpfs per-file hard cap (256 KiB); the
 * rotate-before-write check below guarantees the cap is never hit
 * mid-write (drain chunks are DRAIN_BUF_SIZE bytes at most). */
#define LOG_MAX_BYTES (256L * 1024L)

#define DRAIN_BUF_SIZE 4096

/* open() flag values from lib/moqi_libc/include/unistd.h:
 * O_WRONLY=0x001, O_CREAT=0x040, O_TRUNC=0x200, O_APPEND=0x400. */
#define LOG_OPEN_FLAGS (O_WRONLY | O_CREAT | O_APPEND)             /* 0x441 */
#define LOG_OPEN_FLAGS_TRUNC (O_WRONLY | O_CREAT | O_TRUNC | O_APPEND) /* 0x641 */

static char drain_buf[DRAIN_BUF_SIZE];

static int log_fd = -1;
static long log_size = 0;

/* (Re)open the log file in append mode and adopt its current size.
 * Returns 0 on success, -1 on failure (log_fd left closed). */
static int log_open_append(void) {
    log_fd = open(LOG_PATH, LOG_OPEN_FLAGS, 0);
    if (log_fd < 0) return -1;
    /* lseek SEEK_END reports the size cached by the vfs at open(); with
     * O_APPEND the kernel resets the offset to end-of-file before every
     * write anyway, so this only seeds our local size counter. */
    log_size = lseek(log_fd, 0, SEEK_END);
    if (log_size < 0) log_size = 0;
    return 0;
}

/* Simple rotation: discard the current log and start over empty. */
static int log_rotate(void) {
    close(log_fd);
    log_fd = open(LOG_PATH, LOG_OPEN_FLAGS_TRUNC, 0);
    if (log_fd < 0) return -1;
    log_size = 0;
    return 0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;

    const long kmsg = open(KMSG_PATH, O_RDONLY, 0);
    if (kmsg < 0) {
        printf("[syslogd] FATAL: open %s failed (%ld)\n", KMSG_PATH, kmsg);
        return 1;
    }
    if (log_open_append() < 0) {
        printf("[syslogd] FATAL: open %s failed (%ld)\n", LOG_PATH, (long)log_fd);
        return 1;
    }

    printf("[syslogd] started\n");

    for (;;) {
        /* Blocking read (J3): sleeps in the kernel at the newest byte
         * until a log line is appended; no poll loop needed. */
        const long n = read(kmsg, drain_buf, sizeof(drain_buf));
        if (n > 0) {
            /* Rotate before a write that would cross the 256 KiB tmpfs
             * per-file cap, so writes never fail at the ceiling. */
            if (log_size + n > LOG_MAX_BYTES) {
                if (log_rotate() < 0) {
                    printf("[syslogd] FATAL: rotation reopen failed (%ld)\n",
                           (long)log_fd);
                    return 1;
                }
            }
            const long w = write(log_fd, drain_buf, (unsigned long)n);
            if (w > 0) log_size += w;
            /* A short/failed write just drops the tail of this chunk;
             * logging is best-effort and must never wedge the daemon. */
            continue; /* keep draining while data is available */
        }
        /* n == 0: nothing readable (edge case). n < 0: -EINTR (-4, a
         * signal interrupted the blocking read) or an unexpected error.
         * All are handled the same way: loop back into the blocking
         * read. */
    }
}
