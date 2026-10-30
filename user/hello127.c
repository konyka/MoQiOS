/// hello127: errno semantics of open/unlink/rmdir/mkdir on ext2 and tmpfs.
///
///   unlink of a directory EISDIR; rmdir of a file ENOTDIR; rmdir of a
///   non-empty directory ENOTEMPTY; rmdir of a missing name ENOENT; mkdir of
///   an existing name EEXIST; open(O_CREAT|O_EXCL) of an existing name
///   EEXIST; open(O_DIRECTORY) of a file ENOTDIR; open(O_NOFOLLOW) of a
///   symlink ELOOP; open of a directory for writing EISDIR; open of a
///   missing name ENOENT; a path component that is a file ENOTDIR.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_OPEN      9
#define SYS_CLOSE     11
#define SYS_MKDIR     83
#define SYS_RMDIR     84
#define SYS_UNLINK    87
#define SYS_SYMLINK   88
#define O_RDWR_CREAT  0x42
#define O_EXCL_CREAT  0xC2
#define O_WRONLY      0x1
#define O_RDWR        0x2
#define O_DIRECTORY   0x10000
#define O_NOFOLLOW    0x20000

#define ENOENT_    2
#define EEXIST_    17
#define ENOTDIR_   20
#define EISDIR_    21
#define ELOOP_     40
#define ENOTEMPTY_ 39

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello127:   ok   " : "hello127:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t mkfile(const char *path) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT, 0644);
    if (fd < 0) return fd;
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return 0;
}
static int64_t opn(const char *p, uint64_t flags) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)p, flags, 0644);
    if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
    return fd;
}

static char *path_join(char *out, const char *a, const char *b) {
    int i = 0;
    while (*a) out[i++] = *a++;
    while (*b) out[i++] = *b++;
    out[i] = 0;
    return out;
}

static void suite(const char *tag, const char *dir, int has_symlinks) {
    char p[96];
    print("hello127: -- "); print(tag); print("\n");
    syscall2(SYS_MKDIR, (uint64_t)path_join(p, dir, "/d"), 0755);
    mkfile(path_join(p, dir, "/f"));
    char f[96], d[96], l[96], m[96], nd[96];
    path_join(f, dir, "/f"); path_join(d, dir, "/d"); path_join(l, dir, "/l");
    path_join(m, dir, "/missing"); path_join(nd, dir, "/d/inner");
    syscall2(SYS_SYMLINK, (uint64_t)"f", (uint64_t)l);
    mkfile(nd);

    check(syscall1(SYS_UNLINK, (uint64_t)d) == -EISDIR_, "unlink of a directory is EISDIR");
    check(syscall1(SYS_RMDIR, (uint64_t)f) == -ENOTDIR_, "rmdir of a file is ENOTDIR");
    check(syscall1(SYS_RMDIR, (uint64_t)d) == -ENOTEMPTY_, "rmdir of a non-empty directory is ENOTEMPTY");
    check(syscall1(SYS_RMDIR, (uint64_t)m) == -ENOENT_, "rmdir of a missing name is ENOENT");
    check(syscall1(SYS_UNLINK, (uint64_t)m) == -ENOENT_, "unlink of a missing name is ENOENT");
    check(syscall2(SYS_MKDIR, (uint64_t)d, 0755) == -EEXIST_, "mkdir of an existing directory is EEXIST");
    check(syscall2(SYS_MKDIR, (uint64_t)f, 0755) == -EEXIST_, "mkdir over a file is EEXIST");
    check(opn(f, O_EXCL_CREAT) == -EEXIST_, "open(O_CREAT|O_EXCL) of an existing file is EEXIST");
    check(opn(f, O_DIRECTORY) == -ENOTDIR_, "open(O_DIRECTORY) of a file is ENOTDIR");
    check(opn(d, O_DIRECTORY) >= 0, "open(O_DIRECTORY) of a directory works");
    if (has_symlinks) check(opn(l, O_NOFOLLOW) == -ELOOP_, "open(O_NOFOLLOW) of a symlink is ELOOP");
    check(opn(d, O_WRONLY) == -EISDIR_, "open of a directory for writing is EISDIR");
    check(opn(d, O_RDWR) == -EISDIR_, "open of a directory read-write is EISDIR");
    check(opn(m, 0) == -ENOENT_, "open of a missing name is ENOENT");
    char under[96];
    path_join(under, f, "/x");
    check(opn(under, 0) == -ENOTDIR_, "a file used as a path component is ENOTDIR");

    syscall1(SYS_UNLINK, (uint64_t)nd);
    syscall1(SYS_RMDIR, (uint64_t)d);
    syscall1(SYS_UNLINK, (uint64_t)l);
    syscall1(SYS_UNLINK, (uint64_t)f);
}

void _start(void) {
    print("hello127: namespace errnos\n");
    suite("ext2", "/testdir", 1);
    suite("tmpfs", "/tmp", 0); /* tmpfs has no symlinks */
    print(failures == 0 ? "hello127: PASS\n" : "hello127: FAIL\n");
    print("hello127 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
