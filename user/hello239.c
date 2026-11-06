/* hello239: dup, dup3, fcntl, pread, pwrite, truncate, ftruncate, fsync, fdatasync, access, umask, pipe2 and fchdir of moqi_libc
 * on the real kernel. Expected values were measured against glibc on Linux: dup shares the file offset; dup3 with the same
 * descriptor or unknown flags is EINVAL and with O_CLOEXEC sets FD_CLOEXEC; fcntl F_GETFL/F_SETFL/F_DUPFD/F_DUPFD_CLOEXEC/F_GETFD/
 * F_SETFD; pread/pwrite leave the file offset alone and a negative offset is EINVAL; truncate/ftruncate cut and extend with zeros;
 * access is ENOENT for a missing file and EINVAL for a bad mode; umask returns the old mask; pipe2(O_NONBLOCK) makes an empty
 * read EAGAIN and unknown flags are EINVAL; fchdir of a file descriptor is ENOTDIR. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello239:   ok   " : "hello239:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello239: descriptor and file operations\n");
    char what[160];
    const char *path = "/tmp/hello239.dat";
    unlink(path);

    int fd = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    check(fd >= 0, "A: create the scratch file");
    check(write(fd, "0123456789", 10) == 10, "A: write 10 bytes");

    /* B: dup / dup3 */
    int d = dup(fd);
    check(d >= 0 && d != fd, "B: dup returns a new descriptor");
    lseek(fd, 3, SEEK_SET);
    check(lseek(d, 0, SEEK_CUR) == 3, "B: the duplicate shares the file offset");
    close(d);
    errno = 0;
    check(dup(999) == -1 && errno == EBADF, "B: dup of a closed descriptor is -1 / EBADF");
    errno = 0;
    check(dup3(fd, fd, 0) == -1 && errno == EINVAL, "B: dup3 with the same descriptor is -1 / EINVAL");
    errno = 0;
    check(dup3(fd, 51, 0x1234) == -1 && errno == EINVAL, "B: dup3 with unknown flags is -1 / EINVAL");
    int e = dup3(fd, 50, O_CLOEXEC);
    check(e == 50 && fcntl(50, F_GETFD) == FD_CLOEXEC, "B: dup3 with O_CLOEXEC sets FD_CLOEXEC");
    close(50);

    /* C: fcntl */
    int fl = fcntl(fd, F_GETFL);
    check(fl >= 0 && (fl & O_ACCMODE) == O_RDWR && !(fl & O_NONBLOCK), "C: F_GETFL reports read/write and blocking");
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    check((fcntl(fd, F_GETFL) & O_NONBLOCK) != 0, "C: F_SETFL O_NONBLOCK shows in F_GETFL");
    fcntl(fd, F_SETFL, fl);
    check(fcntl(fd, F_DUPFD, 40) == 40, "C: F_DUPFD returns the lowest free descriptor at or above 40");
    int dc = fcntl(fd, F_DUPFD_CLOEXEC, 45);
    check(dc == 45 && fcntl(dc, F_GETFD) == FD_CLOEXEC, "C: F_DUPFD_CLOEXEC sets FD_CLOEXEC");
    close(40);
    close(45);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    check(fcntl(fd, F_GETFD) == FD_CLOEXEC, "C: F_SETFD / F_GETFD round-trip");
    fcntl(fd, F_SETFD, 0);
    errno = 0;
    check(fcntl(999, F_GETFL) == -1 && errno == EBADF, "C: fcntl on a closed descriptor is -1 / EBADF");
    errno = 0;
    check(fcntl(fd, 9999) == -1 && errno == EINVAL, "C: an unknown command is -1 / EINVAL");

    /* D: pread / pwrite */
    char b[8];
    memset(b, 0, sizeof b);
    lseek(fd, 3, SEEK_SET);
    check(pread(fd, b, 4, 2) == 4 && memcmp(b, "2345", 4) == 0, "D: pread(fd, 4 bytes, offset 2) returns \"2345\"");
    check(lseek(fd, 0, SEEK_CUR) == 3, "D: pread leaves the file offset alone");
    check(pwrite(fd, "AB", 2, 8) == 2, "D: pwrite(\"AB\", offset 8)");
    check(lseek(fd, 0, SEEK_CUR) == 3, "D: pwrite leaves the file offset alone");
    char c[11];
    memset(c, 0, sizeof c);
    pread(fd, c, 10, 0);
    check(memcmp(c, "01234567AB", 10) == 0, "D: the file now reads 01234567AB");
    errno = 0;
    check(pread(fd, b, 4, -1) == -1 && errno == EINVAL, "D: pread with a negative offset is -1 / EINVAL");
    errno = 0;
    check(pread(999, b, 4, 0) == -1 && errno == EBADF, "D: pread on a closed descriptor is -1 / EBADF");

    /* E: truncate / ftruncate */
    check(ftruncate(fd, 4) == 0 && lseek(fd, 0, SEEK_END) == 4, "E: ftruncate(4) cuts the file to 4 bytes");
    check(ftruncate(fd, 12) == 0 && lseek(fd, 0, SEEK_END) == 12, "E: ftruncate(12) extends it to 12 bytes");
    memset(c, 'x', sizeof c);
    pread(fd, c, 11, 0);
    check(c[3] == '3' && c[4] == 0 && c[10] == 0, "E: the extension reads as zeros and the head is kept");
    errno = 0;
    check(ftruncate(fd, -1) == -1 && errno == EINVAL, "E: a negative length is -1 / EINVAL");
    errno = 0;
    check(ftruncate(999, 0) == -1 && errno == EBADF, "E: ftruncate on a closed descriptor is -1 / EBADF");
    long tr = truncate(path, 2);
    long tsz = lseek(fd, 0, SEEK_END);
    snprintf(what, sizeof what, "E: truncate(path, 2) cuts the file to 2 bytes (returned %ld, size %ld)", tr, tsz);
    check(tr == 0 && tsz == 2, what);
    errno = 0;
    check(truncate("/tmp/hello239.nope", 1) == -1 && errno == ENOENT, "E: truncate of a missing file is -1 / ENOENT");

    /* F: fsync / fdatasync / access */
    long fs1 = fsync(fd);
    int fe1 = errno;
    long fs2 = fdatasync(fd);
    snprintf(what, sizeof what, "F: fsync and fdatasync succeed on a file (fsync %ld errno %d, fdatasync %ld)", fs1, fs1 < 0 ? fe1 : 0, fs2);
    check(fs1 == 0 && fs2 == 0, what);
    errno = 0;
    check(fsync(999) == -1 && errno == EBADF, "F: fsync on a closed descriptor is -1 / EBADF");
    check(access(path, F_OK) == 0 && access(path, R_OK | W_OK) == 0, "F: access(F_OK) and access(R_OK|W_OK) succeed");
    errno = 0;
    check(access("/tmp/hello239.nope", F_OK) == -1 && errno == ENOENT, "F: access of a missing file is -1 / ENOENT");
    errno = 0;
    check(access(path, 8) == -1 && errno == EINVAL, "F: access with a bad mode is -1 / EINVAL");

    /* G: umask */
    unsigned int old = umask(077);
    unsigned int back = umask(old);
    snprintf(what, sizeof what, "G: umask returns the previous mask (set 077, then read back %o)", back);
    check(back == 077, what);

    /* H: pipe2 / fchdir */
    int p[2];
    errno = 0;
    check(pipe2(p, 0x1234) == -1 && errno == EINVAL, "H: pipe2 with unknown flags is -1 / EINVAL");
    check(pipe2(p, O_NONBLOCK) == 0, "H: pipe2(O_NONBLOCK)");
    errno = 0;
    check(read(p[0], b, 1) == -EAGAIN, "H: reading the empty non-blocking pipe is EAGAIN");
    close(p[0]);
    close(p[1]);
    check(pipe2(p, O_CLOEXEC) == 0 && fcntl(p[0], F_GETFD) == FD_CLOEXEC && fcntl(p[1], F_GETFD) == FD_CLOEXEC, "H: pipe2(O_CLOEXEC) sets FD_CLOEXEC on both ends");
    close(p[0]);
    close(p[1]);
    errno = 0;
    check(fchdir(fd) == -1 && errno == ENOTDIR, "H: fchdir of a regular file is -1 / ENOTDIR");
    errno = 0;
    check(fchdir(999) == -1 && errno == EBADF, "H: fchdir of a closed descriptor is -1 / EBADF");

    /* I: the size of a file is the file's, not a descriptor's. A second descriptor of the same file sees what truncate(path),
     * ftruncate on another descriptor, and appends through another descriptor did (measured on Linux: SEEK_END and read both follow). */
    {
        const char *p2 = "/tmp/hello239b.dat";
        unlink(p2);
        int a = (int)open(p2, O_RDWR | O_CREAT | O_TRUNC, 0644);
        write(a, "0123456789", 10);
        int bfd = (int)open(p2, O_RDWR, 0);
        check(lseek(bfd, 0, SEEK_END) == 10, "I: a second descriptor sees the 10 bytes written through the first");
        truncate(p2, 4);
        char rb0[16];
        memset(rb0, 0, sizeof rb0);
        lseek(bfd, 0, SEEK_SET);
        long rn0 = read(bfd, rb0, 16);
        snprintf(what, sizeof what, "I: read on a descriptor that has not asked for its size since the truncate gives 4 bytes (read %ld)", rn0);
        check(rn0 == 4 && memcmp(rb0, "0123", 4) == 0, what);
        long e1 = lseek(a, 0, SEEK_END);
        long e2 = lseek(bfd, 0, SEEK_END);
        snprintf(what, sizeof what, "I: truncate(path, 4) shows on both descriptors (SEEK_END %ld and %ld)", e1, e2);
        check(e1 == 4 && e2 == 4, what);
        char rb[16];
        memset(rb, 0, sizeof rb);
        lseek(a, 0, SEEK_SET);
        long rn = read(a, rb, 16);
        snprintf(what, sizeof what, "I: and read gives 4 bytes, not the 10 it used to have (read %ld)", rn);
        check(rn == 4 && memcmp(rb, "0123", 4) == 0, what);
        ftruncate(bfd, 8);
        long e3 = lseek(a, 0, SEEK_END);
        snprintf(what, sizeof what, "I: ftruncate(8) on the second descriptor shows on the first (SEEK_END %ld)", e3);
        check(e3 == 8, what);
        lseek(bfd, 0, SEEK_END);
        write(bfd, "ZZ", 2);
        long e4 = lseek(a, 0, SEEK_END);
        snprintf(what, sizeof what, "I: a write through the second descriptor extends the first's view (SEEK_END %ld)", e4);
        check(e4 == 10, what);
        /* A descriptor whose cached size is smaller than the file (another descriptor extended it) still reads the new bytes. */
        int cfd = (int)open(p2, O_RDONLY, 0);
        char r2[16];
        memset(r2, 0, sizeof r2);
        long r2a = read(cfd, r2, 16);
        write(bfd, "WXYZ", 4);
        long r2b = read(cfd, r2 + r2a, 16 - r2a);
        snprintf(what, sizeof what, "I: bytes appended through another descriptor are readable by a descriptor that had already read to the old end (%ld then %ld)", r2a, r2b);
        check(r2a == 10 && r2b == 4 && memcmp(r2 + 10, "WXYZ", 4) == 0, what);
        close(cfd);
        close(a);
        close(bfd);
        unlink(p2);
    }

    close(fd);
    unlink(path);
    print(failures == 0 ? "hello239: PASS\n" : "hello239: FAIL\n");
    return failures;
}
