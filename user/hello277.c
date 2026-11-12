/// hello277: open flags and object kinds through /proc/self/fd/N. Linux (measured on the host): the link is reopened with the flags
/// given now, not the ones the descriptor had. O_CREAT|O_EXCL is EEXIST, O_TRUNC truncates, O_DIRECTORY on a file is ENOTDIR, O_RDWR on a
/// directory is EISDIR, the access mode is the new one and is checked against the file's mode bits again (also after unlink); a pipe end
/// reopens as the end the access mode asks for; eventfd and epoll are EACCES, a socket ENXIO; stat through a pipe or socket link works.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/epoll.h"

#define SYS_SETUID    174
#define SYS_EVENTFD2  169

static int failures;
static char what[240];
static void check(int ok, const char *w) {
    print(ok ? "hello277:   ok   " : "hello277:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void linkOf(char *l, int fd) { snprintf(l, 64, "/proc/self/fd/%d", fd); }
/* open through the link of `fd`; returns the descriptor or -errno (moqi_libc's open returns the kernel value as is) */
static int via(int fd, int flags) {
    char l[64];
    linkOf(l, fd);
    return (int)open(l, flags, 0644);
}

static void flagsOn(const char *tag, int deleted) {
    char name[32];
    snprintf(name, sizeof name, "/tmp/h277%s", tag);
    unlink(name);
    int f = (int)open(name, O_RDWR | O_CREAT | O_TRUNC, 0644);
    write(f, "hello", 5);
    if (deleted) unlink(name);

    int r = via(f, O_RDWR | O_CREAT | O_EXCL);
    snprintf(what, sizeof what, "%s: O_CREAT|O_EXCL through the link is EEXIST (%d)", tag, r);
    check(r == -EEXIST, what);
    if (r >= 0) close(r);

    r = via(f, O_RDONLY | O_DIRECTORY);
    snprintf(what, sizeof what, "%s: O_DIRECTORY on a file through the link is ENOTDIR (%d)", tag, r);
    check(r == -ENOTDIR, what);
    if (r >= 0) close(r);

    int ro = via(f, O_RDONLY);
    long wr = ro >= 0 ? write(ro, "q", 1) : 0;
    long fl = ro >= 0 ? fcntl(ro, F_GETFL, 0) : -1;
    snprintf(what, sizeof what, "%s: an O_RDONLY reopen of an O_RDWR descriptor cannot write (fd %d write %ld F_GETFL %lx)", tag, ro, wr, fl);
    check(ro >= 0 && wr < 0 && (fl & O_ACCMODE) == O_RDONLY, what);
    if (ro >= 0) close(ro);

    int ap = via(f, O_WRONLY | O_APPEND);
    long afl = ap >= 0 ? fcntl(ap, F_GETFL, 0) : -1;
    long aw = ap >= 0 ? write(ap, "xy", 2) : -1;
    struct stat st;
    fstat(f, &st);
    snprintf(what, sizeof what, "%s: O_WRONLY|O_APPEND through the link is that mode and appends (F_GETFL %lx, write %ld, size %ld)", tag, afl, aw, (long)st.st_size);
    check(ap >= 0 && (afl & (O_ACCMODE | O_APPEND)) == (O_WRONLY | O_APPEND) && aw == 2 && st.st_size == 7, what);
    if (ap >= 0) close(ap);

    int tr = via(f, O_RDWR | O_TRUNC);
    fstat(f, &st);
    snprintf(what, sizeof what, "%s: O_TRUNC through the link truncates the file (fd %d, size %ld)", tag, tr, (long)st.st_size);
    check(tr >= 0 && st.st_size == 0, what);
    if (tr >= 0) close(tr);
    close(f);
    unlink(name);
}

static int st_mode_of(int fd) {
    char l[64];
    struct stat st;
    linkOf(l, fd);
    memset(&st, 0, sizeof st);
    return stat(l, &st) == 0 ? (int)st.st_mode : -1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello277: open flags and object kinds through /proc/self/fd/N\n");

    flagsOn("live", 0);
    flagsOn("gone", 1);

    /* directory: O_RDONLY reopens, O_RDWR is EISDIR, O_CREAT|O_EXCL is EEXIST */
    rmdir("/tmp/h277d");
    mkdir("/tmp/h277d", 0755);
    int d = (int)open("/tmp/h277d", O_RDONLY | O_DIRECTORY, 0);
    int r1 = via(d, O_RDONLY), r2 = via(d, O_RDWR), r3 = via(d, O_RDONLY | O_CREAT | O_EXCL);
    snprintf(what, sizeof what, "dir: O_RDONLY reopens (%d), O_RDWR is EISDIR (%d), O_CREAT|O_EXCL is EEXIST (%d)", r1, r2, r3);
    check(r1 >= 0 && r2 == -EISDIR && r3 == -EEXIST, what);
    if (r1 >= 0) close(r1);
    if (r2 >= 0) close(r2);
    if (r3 >= 0) close(r3);
    close(d);
    rmdir("/tmp/h277d");

    /* pipe: either end reopens as the end the access mode asks for */
    int p[2];
    pipe(p);
    int w = via(p[0], O_WRONLY | O_NONBLOCK);
    long wn = w >= 0 ? write(w, "ab", 2) : -1;
    char b[4] = {0};
    long rn = wn == 2 ? read(p[0], b, 2) : -1; /* an empty pipe with a writer would block */
    snprintf(what, sizeof what, "pipe: the read end reopened O_WRONLY writes into the same pipe (fd %d write %ld read %ld \"%s\")", w, wn, rn, b);
    check(w >= 0 && wn == 2 && rn == 2 && memcmp(b, "ab", 2) == 0, what);
    if (w >= 0) close(w);
    int pm = st_mode_of(p[0]);
    snprintf(what, sizeof what, "pipe: stat through the link is a FIFO (mode %o)", pm);
    check(pm >= 0 && S_ISFIFO(pm), what);
    close(p[0]);
    close(p[1]);

    /* objects with no name: eventfd and epoll are EACCES, a socket is ENXIO */
    int ev = (int)syscall2(SYS_EVENTFD2, 0, 0);
    int ep = epoll_create1(0);
    int so = (int)syscall3(SYS_socket, 1 /* AF_UNIX */, 1 /* SOCK_STREAM */, 0);
    int e1 = via(ev, O_RDWR), e2 = via(ep, O_RDWR), e3 = via(so, O_RDWR);
    snprintf(what, sizeof what, "eventfd (%d) and epoll (%d) are EACCES, a socket is ENXIO (%d)", e1, e2, e3);
    check(e1 == -EACCES && e2 == -EACCES && e3 == -ENXIO, what);
    int sm = st_mode_of(so);
    snprintf(what, sizeof what, "socket: stat through the link is a socket (mode %o)", sm);
    check(sm >= 0 && S_ISSOCK(sm), what);
    close(ev);
    close(ep);
    close(so);

    /* permissions are checked again for the new access mode, also after unlink */
    unlink("/tmp/h277p");
    int c = (int)open("/tmp/h277p", O_RDWR | O_CREAT | O_TRUNC, 0644);
    close(c);
    chmod("/tmp/h277p", 0444);
    long pid = fork();
    if (pid == 0) {
        int bits = 0;
        if (syscall1(SYS_SETUID, 1000) != 0) _exit(64);
        int ro = (int)open("/tmp/h277p", O_RDONLY, 0);
        if (ro < 0) _exit(65);
        if (via(ro, O_RDWR) != -EACCES) bits |= 1;
        int ok = via(ro, O_RDONLY);
        if (ok < 0) bits |= 2; else close(ok);
        unlink("/tmp/h277p");
        if (via(ro, O_RDWR) != -EACCES) bits |= 4;
        _exit(bits);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    int code = (status >> 8) & 0xff;
    snprintf(what, sizeof what, "a non-root reopen of a 0444 file for writing is EACCES, also after unlink; reading still works (child bits %d)", code);
    check(pid > 0 && code == 0, what);
    unlink("/tmp/h277p");

    print(failures == 0 ? "hello277: PASS\n" : "hello277: FAIL\n");
    return failures;
}
