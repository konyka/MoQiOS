/// hello282: process_vm_readv/writev across processes. Linux (measured on the host): a parent may read and write a child's memory; a write into a
/// copy-on-write page changes only the child's copy; a missing pid and a zombie are ESRCH; a non-zero flags word is EINVAL; a read-only
/// destination is EFAULT; a length-0 iovec against a missing pid still returns 0. Another user's process is EPERM (Linux's ptrace check).
/// File pages the child never touched (/tmp/pvf.c on the host): readv faults them in for the child and returns the file's bytes; writev
/// into a MAP_PRIVATE page gives the child a private copy (the file and the parent's untouched private page, which keeps following the
/// file, never see it); writev into a MAP_SHARED page
/// reaches the file; a page wholly past the end of the file is EFAULT.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/mman.h"
#include "../lib/moqi_libc/include/fcntl.h"

#define SYS_PROCESS_VM_READV 283
#define SYS_PROCESS_VM_WRITEV 284
#define SYS_SETUID_ 174

static int failures;
static char msg[160];
static void check(int ok, const char *w) {
    print(ok ? "hello282:   ok   " : "hello282:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

struct iov { long base; long len; };
char g_data[16] = "original";

/* A 4 KiB file of 'f' starting with "file-bytes", mapped twice (8 KiB MAP_PRIVATE, 4 KiB MAP_SHARED) before a fork. Neither the parent
 * nor the child touches the mappings before the parent's process_vm calls, so the child's pages are not present yet. */
static void file_case(const char *label, const char *path) {
    int fd = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        snprintf(msg, sizeof msg, "%s: open failed (%d)", label, fd);
        check(0, msg);
        return;
    }
    char page[4096];
    memset(page, 'f', sizeof page);
    memcpy(page, "file-bytes", 10);
    write(fd, page, sizeof page);
    char *pm = (char *)mmap(0, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    char *sm = (char *)mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int p[2];
    pipe(p);
    long c = fork();
    if (c == 0) {
        char x;
        read(p[0], &x, 1);
        volatile char *vp = pm, *vs = sm;
        _exit((vp[0] == 'P' ? 0 : 1) | (vs[0] == 'S' ? 0 : 2));
    }
    char got[16] = { 0 };
    struct iov l = { (long)got, 10 }, r = { (long)pm, 10 };
    long n = syscall6(SYS_PROCESS_VM_READV, c, (long)&l, 1, (long)&r, 1, 0);
    snprintf(msg, sizeof msg, "%s: readv of a file page the child never touched returns the file's bytes (%ld, %.10s)", label, n, got);
    check(n == 10 && memcmp(got, "file-bytes", 10) == 0, msg);
    struct iov lw = { (long)"PRIV", 4 }, rw = { (long)pm, 4 };
    n = syscall6(SYS_PROCESS_VM_WRITEV, c, (long)&lw, 1, (long)&rw, 1, 0);
    snprintf(msg, sizeof msg, "%s: writev into an untouched MAP_PRIVATE file page succeeds (%ld)", label, n);
    check(n == 4, msg);
    struct iov ls = { (long)"SHRD", 4 }, rs = { (long)sm, 4 };
    n = syscall6(SYS_PROCESS_VM_WRITEV, c, (long)&ls, 1, (long)&rs, 1, 0);
    snprintf(msg, sizeof msg, "%s: writev into an untouched MAP_SHARED file page succeeds (%ld)", label, n);
    check(n == 4, msg);
    struct iov le = { (long)got, 4 }, re = { (long)(pm + 4096), 4 };
    n = syscall6(SYS_PROCESS_VM_READV, c, (long)&le, 1, (long)&re, 1, 0);
    snprintf(msg, sizeof msg, "%s: readv of a page wholly past the end of the file is EFAULT (%ld)", label, n);
    check(n == -14, msg);
    write(p[1], "g", 1);
    int st = 0;
    waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "%s: the child sees both writes (missing: %d)", label, (st >> 8) & 0xff);
    check(c > 0 && (st & 0x7f) == 0 && (st >> 8) == 0, msg);
    snprintf(msg, sizeof msg, "%s: the parent's untouched private page follows the file, not the child's private write (%.4s, %.4s)", label, pm, sm);
    check(memcmp(pm, "SHRD", 4) == 0 && memcmp(sm, "SHRD", 4) == 0, msg);
    munmap(pm, 8192);
    munmap(sm, 4096);
    char fb[8] = { 0 };
    pread(fd, fb, 4, 0);
    snprintf(msg, sizeof msg, "%s: the file holds the shared write, not the private one (%.4s)", label, fb);
    check(memcmp(fb, "SHRD", 4) == 0, msg);
    close(fd);
    unlink(path);
}

int main(void) {
    int p1[2], p2[2];
    if (pipe(p1) != 0 || pipe(p2) != 0) { print("hello282: FAIL pipe\n"); return 1; }
    char shared[16] = "original";
    char *cow = (char *)mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if ((long)cow < 0) { print("hello282: FAIL mmap\n"); return 1; }
    memcpy(cow, "cow-original", 13);
    long child = fork();
    if (child == 0) {
        char x = 'r';
        write(p1[1], &x, 1);
        read(p2[0], &x, 1);
        volatile char *vs = shared, *vc = cow, *vg = g_data;
        _exit((vs[0] == 'P' ? 0 : 1) | (vc[0] == 'P' ? 0 : 2) | (vg[0] == 'P' ? 0 : 4));
    }
    char x;
    read(p1[0], &x, 1);

    char got[16] = { 0 };
    struct iov local = { (long)got, 8 };
    struct iov remote = { (long)shared, 8 };
    check(syscall6(SYS_PROCESS_VM_READV, child, (long)&local, 1, (long)&remote, 1, 0) == 8 && memcmp(got, "original", 8) == 0,
          "readv of the child's memory returns its bytes");

    char w[] = "PARENT!!";
    struct iov lw = { (long)w, 8 };
    check(syscall6(SYS_PROCESS_VM_WRITEV, child, (long)&lw, 1, (long)&remote, 1, 0) == 8 && shared[0] == 'o',
          "writev into the child's copy-on-write page leaves the parent's copy untouched");
    struct iov rc = { (long)cow, 8 };
    check(syscall6(SYS_PROCESS_VM_WRITEV, child, (long)&lw, 1, (long)&rc, 1, 0) == 8 && cow[0] == 'c',
          "writev into a forked anonymous page leaves the parent's page untouched");
    struct iov rg = { (long)g_data, 8 };
    check(syscall6(SYS_PROCESS_VM_WRITEV, child, (long)&lw, 1, (long)&rg, 1, 0) == 8 && g_data[0] == 'o',
          "writev into a copy-on-write data page leaves the parent's copy untouched");

    struct iov zero = { (long)got, 0 };
    check(syscall6(SYS_PROCESS_VM_READV, 999999, (long)&zero, 1, (long)&remote, 1, 0) == 0, "a zero-length read of a missing pid is 0");
    check(syscall6(SYS_PROCESS_VM_READV, 999999, (long)&local, 1, (long)&remote, 1, 0) == -ESRCH, "a missing pid is ESRCH");
    check(syscall6(SYS_PROCESS_VM_READV, child, (long)&local, 1, (long)&remote, 1, 1) == -EINVAL, "a non-zero flags word is EINVAL");

    /* Another user's process: a child that drops to uid 1000 may not read this root-owned process (Linux: EPERM, ptrace check). */
    long me = getpid();
    long dropper = fork();
    if (dropper == 0) {
        if (syscall1(SYS_SETUID_, 1000) != 0) _exit(100);
        char b[8];
        struct iov l2 = { (long)b, 8 };
        struct iov r2 = { (long)shared, 8 };
        long rr = syscall6(SYS_PROCESS_VM_READV, me, (long)&l2, 1, (long)&r2, 1, 0);
        _exit(rr == -EPERM ? 0 : 1);
    }
    int ds = 0;
    waitpid(dropper, &ds, 0);
    snprintf(msg, sizeof msg, "uid 1000 reading a root process is EPERM (child status %d)", (ds >> 8) & 0xff);
    check(dropper > 0 && (ds >> 8) == 0, msg);

    write(p2[1], &x, 1);
    int st = 0;
    waitpid(child, &st, 0);
    snprintf(msg, sizeof msg, "the child observed both writes (missing: %d)", (st >> 8) & 0xff);
    check((st >> 8) == 0, msg);
    check(syscall6(SYS_PROCESS_VM_READV, child, (long)&local, 1, (long)&remote, 1, 0) == -ESRCH, "a reaped child is ESRCH");
    munmap(cow, 4096);

    file_case("tmpfs", "/tmp/h282f");
    file_case("ext2", "testdir/h282e");

    print(failures == 0 ? "hello282: PASS\n" : "hello282: FAIL\n");
    return failures;
}
