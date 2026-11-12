/// hello281: the sticky bit on directories. Linux (measured on the host, /tmp is 1777): another user's file or directory in a sticky
/// directory cannot be unlinked, rmdir'ed, renamed away or replaced by rename; every one of these is EPERM (may_delete_dentry). The entry's
/// owner can still remove it, and in a 0777 directory without the bit anyone with write permission can.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stat.h"

#define SYS_SETUID 174

static int failures;
static char what[240];
static void check(int ok, const char *w) {
    print(ok ? "hello281:   ok   " : "hello281:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void touch(const char *p) {
    int f = (int)open(p, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (f >= 0) close(f);
}

/* In a child that drops to uid 1000: bit i of the exit code is set when step i gave the wrong answer. */
static int asUser(const char *dir, int sticky) {
    char f[96], d[96], mine[96], dst[96], t[96];
    snprintf(f, sizeof f, "%s/rootf", dir);
    snprintf(d, sizeof d, "%s/rootd", dir);
    snprintf(mine, sizeof mine, "%s/mine", dir);
    snprintf(dst, sizeof dst, "%s/moved", dir);
    snprintf(t, sizeof t, "%s/roott", dir);
    long pid = fork();
    if (pid == 0) {
        int bits = 0;
        if (syscall1(SYS_SETUID, 1000) != 0) _exit(127);
        long want = sticky ? -EPERM : 0;
        if (rename(f, dst) != want) bits |= 1;
        if (sticky && unlink(f) != -EPERM) bits |= 2;
        if (!sticky && unlink(dst) != 0) bits |= 2;
        if (rmdir(d) != want) bits |= 4;
        touch(mine);
        if (rename(mine, t) != want) bits |= 8;
        if (sticky) {
            if (unlink(mine) != 0) bits |= 16;
        } else if (unlink(t) != 0) bits |= 16;
        _exit(bits);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return pid > 0 ? (status >> 8) & 0xff : 255;
}

static void setup(const char *dir, int mode) {
    char p[96];
    mkdir(dir, 0755);
    chmod(dir, mode);
    snprintf(p, sizeof p, "%s/rootf", dir);
    touch(p);
    snprintf(p, sizeof p, "%s/roott", dir);
    touch(p);
    snprintf(p, sizeof p, "%s/rootd", dir);
    mkdir(p, 0755);
}
static void cleanup(const char *dir) {
    const char *names[] = { "rootf", "roott", "moved", "mine" };
    char p[96];
    for (int i = 0; i < 4; i++) {
        snprintf(p, sizeof p, "%s/%s", dir, names[i]);
        unlink(p);
    }
    snprintf(p, sizeof p, "%s/rootd", dir);
    rmdir(p);
    rmdir(dir);
}

static void run(const char *label, const char *dir, int mode, int sticky) {
    cleanup(dir);
    setup(dir, mode);
    struct stat st;
    memset(&st, 0, sizeof st);
    stat(dir, &st);
    int bits = asUser(dir, sticky);
    snprintf(what, sizeof what, "%s: mode %o; another user's rename away, unlink, rmdir and rename-over are %s; the owner removes its own entry (child bits %d)",
             label, st.st_mode & 07777, sticky ? "EPERM" : "allowed", bits);
    check((st.st_mode & 07777) == (unsigned)mode && bits == 0, what);
    char p[96];
    snprintf(p, sizeof p, "%s/rootf", dir);
    int f = (int)open(p, O_RDONLY, 0);
    if (sticky) {
        snprintf(what, sizeof what, "%s: root's file is still there (%d)", label, f);
        check(f >= 0, what);
    }
    if (f >= 0) close(f);
    cleanup(dir);
}

int main(void) {
    run("ext2 sticky", "testdir/h281s", 01777, 1);
    run("ext2 plain 0777", "testdir/h281p", 0777, 0);
    run("tmpfs sticky", "/tmp/h281s", 01777, 1);
    print(failures == 0 ? "hello281: PASS\n" : "hello281: FAIL\n");
    return failures;
}
