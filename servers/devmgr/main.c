/* servers/devmgr/main.c — MoQiOS device manager, built against moqi_libc
 * like servers/syslogd/main.c.
 *
 * Event-driven: blocks on /dev/devfs-watch, whose read returns the devfs
 * change counter (u64 LE) once it moves past the fd's last-read cursor —
 * i.e. after any device-node register/unregister (userspace-owned nodes
 * from devfs_register, syscall 484, included). On each change devmgr
 * re-snapshots getdents("/dev") and logs the node set. If the watch node
 * is unavailable it falls back to the original 1s poll loop.
 *
 * Markers: "[devmgr] started" at boot (smoke gate), "[devmgr] devices: ..."
 * on change.
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <moqi_syscalls.h>

#define DEV_PATH       "/dev"
#define WATCH_PATH     "/dev/devfs-watch"
#define SYS_getdents64 78
#define POLL_NS    (1000L * 1000L * 1000L) /* 1s */

/* linux_dirent64, matching kernel/fs/getdents.zig. */
typedef struct {
    unsigned long long ino;
    long long          off;
    unsigned short     reclen;
    unsigned char      type;
    char               name[];
} dirent64_t;

/* Snapshot the node names into one space-separated line. */
static int snapshot(char *out, int cap) {
    static char buf[2048];
    int fd = open(DEV_PATH, 0, 0);
    if (fd < 0) return -1;
    int n = 0;
    out[0] = '\0';
    for (;;) {
        int r = (int)syscall3(SYS_getdents64, (long)fd, (long)buf, (long)sizeof(buf));
        if (r < 0) { close(fd); return -1; }
        if (r == 0) break;
        int pos = 0;
        while (pos < r) {
            dirent64_t *d = (dirent64_t *)(buf + pos);
            int len = (int)strlen(d->name);
            if (n + len + 2 < cap) {
                if (n) out[n++] = ' ';
                memcpy(out + n, d->name, len);
                n += len;
                out[n] = '\0';
            }
            pos += d->reclen;
        }
    }
    close(fd);
    return n;
}

static void report_change(char *cur, char *prev, int cap) {
    if (snapshot(cur, cap) >= 0 && strcmp(cur, prev) != 0) {
        printf("[devmgr] devices: %s\n", cur);
        memcpy(prev, cur, (size_t)cap);
    }
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    static char cur[1024], prev[1024];

    printf("[devmgr] started\n");
    prev[0] = '\0';

    int wfd = open(WATCH_PATH, 0, 0);
    if (wfd >= 0) {
        /* Event-driven: the first read returns the current counter
         * immediately (fresh cursor), later reads block until the next
         * register/unregister. */
        for (;;) {
            unsigned long long counter = 0;
            long n = read(wfd, &counter, sizeof(counter));
            if (n < 0) {
                /* Node gone or interrupted — re-report, then keep going. */
                report_change(cur, prev, (int)sizeof(cur));
                continue;
            }
            report_change(cur, prev, (int)sizeof(cur));
        }
    }

    /* Fallback: no /dev/devfs-watch on this kernel — poll once a second. */
    for (;;) {
        report_change(cur, prev, (int)sizeof(cur));
        struct timespec ts = { .tv_sec = 0, .tv_nsec = POLL_NS };
        nanosleep(&ts, (void *)0);
    }
    return 0;
}
