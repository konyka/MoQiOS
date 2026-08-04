/* servers/devmgr/main.c — MoQiOS device manager (minimal first step),
 * built against moqi_libc like servers/syslogd/main.c.
 *
 * Current scope: poll getdents("/dev") every second and log the registered
 * device-node set whenever it changes. The devfs registration table is
 * kernel-init-time only today, so the set is static — but this daemon is
 * the hook point for future hotplug: once devfs grows an event/notify
 * mechanism, devmgr switches from polling to event-driven without changing
 * its external role (documented in docs/kernel-subsystems.md §3.8).
 *
 * Markers: "[devmgr] started" at boot (smoke gate), "[devmgr] devices: ..."
 * on change.
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <moqi_syscalls.h>

#define DEV_PATH   "/dev"
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

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    static char cur[1024], prev[1024];

    printf("[devmgr] started\n");
    prev[0] = '\0';

    for (;;) {
        if (snapshot(cur, (int)sizeof(cur)) >= 0 && strcmp(cur, prev) != 0) {
            printf("[devmgr] devices: %s\n", cur);
            memcpy(prev, cur, sizeof(prev));
        }
        struct timespec ts = { .tv_sec = 0, .tv_nsec = POLL_NS };
        nanosleep(&ts, (void *)0);
    }
    return 0;
}
