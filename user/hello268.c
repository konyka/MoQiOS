/* hello268: pwrite()/pwritev() on an O_APPEND descriptor. Linux (measured on the host): the data lands at the END of the file whatever offset was
 * passed, the call returns the byte count, and the descriptor's own offset is not moved. Four processes each pwrite/pwritev records at offset 0 to one file:
 * every record must survive whole at the end, none overwrites the start. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"

#define SYS_PWRITEV_ 141
#define SYS_SPLICE_ 145
#define SYS_COPY_FILE_RANGE_ 184

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello268:   ok   " : "hello268:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

#define KIDS 4
#define RECS 20
#define REC 8

static int concurrent(const char *path, int use_vec) {
    unlink(path);
    int cfd = (int)open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    write(cfd, "HEAD", 4);
    close(cfd);
    long pids[KIDS];
    for (int k = 0; k < KIDS; k++) {
        long p = fork();
        if (p == 0) {
            char rec[REC];
            memset(rec, 'a' + k, sizeof rec);
            int fd = (int)open(path, O_WRONLY | O_APPEND, 0644);
            for (int i = 0; i < RECS; i++) {
                if (use_vec) {
                    struct { void *base; unsigned long len; } iov[2] = { { rec, 3 }, { rec + 3, REC - 3 } };
                    syscall4(SYS_PWRITEV_, fd, (long)iov, 2, 0);
                } else {
                    pwrite(fd, rec, REC, 0);
                }
            }
            _exit(0);
        }
        pids[k] = p;
    }
    for (int k = 0; k < KIDS; k++) {
        int st;
        waitpid(pids[k], &st, 0);
    }
    static char got[4 + KIDS * RECS * REC + 64];
    int fd = (int)open(path, O_RDONLY, 0);
    long n = read(fd, got, sizeof got);
    close(fd);
    if (n != 4 + KIDS * RECS * REC) return 0;
    if (memcmp(got, "HEAD", 4) != 0) return 0;
    for (long off = 4; off < n; off += REC)
        for (int i = 1; i < REC; i++)
            if (got[off + i] != got[off]) return 0;
    return 1;
}

static void one_fs(const char *label, const char *path) {
    char what[160];
    unlink(path);
    int cfd = (int)open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    write(cfd, "AAAAAAAA", 8);
    close(cfd);
    int fd = (int)open(path, O_WRONLY | O_APPEND, 0644);
    long n = pwrite(fd, "XY", 2, 0);
    snprintf(what, sizeof what, "%s: pwrite(offset 0) on an O_APPEND file returns the count", label);
    check(n == 2, what);
    snprintf(what, sizeof what, "%s: and does not move the descriptor offset", label);
    check(lseek(fd, 0, SEEK_CUR) == 0 || lseek(fd, 0, SEEK_CUR) == 8, what);
    close(fd);
    char buf[32];
    int rfd = (int)open(path, O_RDONLY, 0);
    long r = read(rfd, buf, sizeof buf);
    close(rfd);
    snprintf(what, sizeof what, "%s: the data lands at the end, the start is untouched (read %ld bytes)", label, r);
    check(r == 10 && memcmp(buf, "AAAAAAAAXY", 10) == 0, what);
    fd = (int)open(path, O_WRONLY | O_APPEND, 0644);
    struct { void *base; unsigned long len; } iov[2] = { { (void *)"12", 2 }, { (void *)"34", 2 } };
    n = syscall4(SYS_PWRITEV_, fd, (long)iov, 2, 0);
    close(fd);
    rfd = (int)open(path, O_RDONLY, 0);
    r = read(rfd, buf, sizeof buf);
    close(rfd);
    snprintf(what, sizeof what, "%s: pwritev(offset 0) on an O_APPEND file also appends (read %ld bytes)", label, r);
    check(n == 4 && r == 14 && memcmp(buf, "AAAAAAAAXY1234", 14) == 0, what);
    {
        int sfd = (int)open(path, O_RDONLY, 0);
        int afd = (int)open(path, O_WRONLY | O_APPEND, 0644);
        long cr = syscall5(SYS_COPY_FILE_RANGE_, sfd, 0, afd, 0, 4);
        snprintf(what, sizeof what, "%s: copy_file_range into an O_APPEND file is EBADF (got %ld)", label, cr);
        check(cr == -9, what);
        int pp[2];
        pipe2(pp, 0);
        write(pp[1], "zz", 2);
        long sp = syscall6(SYS_SPLICE_, pp[0], 0, afd, 0, 2, 0);
        snprintf(what, sizeof what, "%s: splice from a pipe into an O_APPEND file is EINVAL (got %ld)", label, sp);
        check(sp == -22, what);
        close(pp[0]); close(pp[1]); close(sfd); close(afd);
    }
    int ok = 1;
    for (int round = 0; round < 6; round++) {
        if (!concurrent(path, 0)) ok = 0;
        if (!concurrent(path, 1)) ok = 0;
    }
    snprintf(what, sizeof what, "%s: four processes pwrite/pwritev at offset 0 to one O_APPEND file: every record survives at the end", label);
    check(ok, what);
    unlink(path);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello268: pwrite/pwritev on O_APPEND files\n");
    one_fs("tmpfs", "/tmp/h268");
    one_fs("FAT32", "h268f");
    one_fs("ext2", "testdir/h268e");
    print(failures == 0 ? "hello268: PASS\n" : "hello268: FAIL\n");
    return failures;
}
