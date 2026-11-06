/* test_stat_abi.c -- stat, lstat and fstat, plus chmod, fchmod, readlink, symlink and link (src/stat.c), against a
 * recording system-call stub. struct stat is glibc's x86-64 layout (measured: 144 bytes; st_dev 0, st_ino 8, st_nlink 16, st_mode 24,
 * st_uid 28, st_gid 32, st_rdev 40, st_size 48, st_blksize 56, st_blocks 64, st_atim 72, st_mtim 88, st_ctim 104). stat and lstat ask
 * the kernel with statx; the library converts the 144-byte statx (mask 0, blksize 4, nlink 16, uid 20, gid 24, mode 28, ino 32,
 * size 40, blocks 48, atime 64, ctime 96, mtime 112) into struct stat, and a field the statx mask does not cover is 0. fstat uses the
 * kernel's own fstat, which already writes struct stat.
 */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"

/* The host's names are not wanted: the library's are compiled under moqi_ names. */
#define stat moqi_stat_struct
#define timespec moqi_timespec
#include "../include/stat.h"
#undef stat
#undef timespec

int moqi_stat(const char *, struct moqi_stat_struct *);
int moqi_lstat(const char *, struct moqi_stat_struct *);
int moqi_fstat(int, struct moqi_stat_struct *);
int moqi_chmod(const char *, unsigned int);
int moqi_fchmod(int, unsigned int);
long moqi_readlink(const char *, char *, size_t);
int moqi_symlink(const char *, const char *);
int moqi_link(const char *, const char *);

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static int ncalls;
static long c_nr, c_a1, c_a2, c_a3, c_a4, c_a5;
static long reply;
static uint8_t statx_reply[144];
static uint8_t fstat_reply[144];

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a6;
    ncalls++;
    c_nr = nr; c_a1 = a1; c_a2 = a2; c_a3 = a3; c_a4 = a4; c_a5 = a5;
    if (nr == SYS_statx && reply == 0) memcpy((void *)a5, statx_reply, 144);
    if (nr == SYS_fstat && reply == 0) memcpy((void *)a2, fstat_reply, 144);
    return reply;
}

static void arm(long r) { ncalls = 0; reply = r; errno_slot = 0; c_nr = c_a1 = c_a2 = c_a3 = c_a4 = c_a5 = -777; }
static void put32(int o, uint32_t v) { memcpy(statx_reply + o, &v, 4); }
static void put64(int o, uint64_t v) { memcpy(statx_reply + o, &v, 8); }

int main(void) {
    CHECK(sizeof(struct moqi_stat_struct) == 144);
    CHECK(offsetof(struct moqi_stat_struct, st_dev) == 0 && offsetof(struct moqi_stat_struct, st_ino) == 8 && offsetof(struct moqi_stat_struct, st_nlink) == 16);
    CHECK(offsetof(struct moqi_stat_struct, st_mode) == 24 && offsetof(struct moqi_stat_struct, st_uid) == 28 && offsetof(struct moqi_stat_struct, st_gid) == 32);
    CHECK(offsetof(struct moqi_stat_struct, st_rdev) == 40 && offsetof(struct moqi_stat_struct, st_size) == 48 && offsetof(struct moqi_stat_struct, st_blksize) == 56);
    CHECK(offsetof(struct moqi_stat_struct, st_blocks) == 64 && offsetof(struct moqi_stat_struct, st_atim) == 72 && offsetof(struct moqi_stat_struct, st_mtim) == 88 && offsetof(struct moqi_stat_struct, st_ctim) == 104);
    CHECK(S_ISREG(0100644) && !S_ISDIR(0100644) && S_ISDIR(040755) && S_ISLNK(0120777) && S_ISCHR(020666) && S_ISBLK(060660) && S_ISFIFO(010644) && S_ISSOCK(0140755));
    CHECK(!S_ISREG(040755) && !S_ISLNK(0100644));
    CHECK(SYS_statx == 183 && SYS_fstat == 110 && SYS_chmod == 90 && SYS_fchmod == 91 && SYS_readlink == 89 && SYS_symlink == 88 && SYS_link == 86);

    struct moqi_stat_struct st;

    /* stat: statx with AT_FDCWD, the path, no flags and the basic mask; every field converted */
    memset(statx_reply, 0, sizeof statx_reply);
    put32(0, 0x7ff);                /* mask: everything */
    put32(4, 4096);                 /* blksize */
    put32(16, 3);                   /* nlink */
    put32(20, 1000);                /* uid */
    put32(24, 100);                 /* gid */
    put32(28, 0100640);             /* mode */
    put64(32, 777);                 /* ino */
    put64(40, 11);                  /* size */
    put64(48, 8);                   /* blocks */
    put64(64, 1111); put64(72, 11); /* atime sec, nsec */
    put64(96, 3333); put64(104, 33);/* ctime */
    put64(112, 2222); put64(120, 22);/* mtime */
    arm(0);
    memset(&st, 0xAA, sizeof st);
    const char *statpath = "/tmp/f";
    CHECK(moqi_stat(statpath, &st) == 0);
    CHECK(ncalls == 1 && c_nr == SYS_statx && c_a1 == -100 && c_a2 == (long)statpath && c_a3 == 0);
    CHECK(st.st_ino == 777 && st.st_nlink == 3 && st.st_mode == 0100640 && st.st_uid == 1000 && st.st_gid == 100);
    CHECK(st.st_size == 11 && st.st_blksize == 4096 && st.st_blocks == 8 && st.st_dev == 0 && st.st_rdev == 0);
    CHECK(st.st_atim.tv_sec == 1111 && st.st_atim.tv_nsec == 11 && st.st_mtim.tv_sec == 2222 && st.st_mtim.tv_nsec == 22 && st.st_ctim.tv_sec == 3333 && st.st_ctim.tv_nsec == 33);

    /* lstat adds AT_SYMLINK_NOFOLLOW (0x100) */
    arm(0);
    CHECK(moqi_lstat("/tmp/ln", &st) == 0 && c_a1 == -100 && c_a3 == 0x100);

    /* fstat: the kernel's fstat writes struct stat directly into the caller's buffer */
    memset(fstat_reply, 0, sizeof fstat_reply);
    { uint64_t ino = 55, nlink = 2, size = 99; uint32_t mode = 0100600, uid = 7; memcpy(fstat_reply + 8, &ino, 8); memcpy(fstat_reply + 16, &nlink, 8); memcpy(fstat_reply + 24, &mode, 4); memcpy(fstat_reply + 28, &uid, 4); memcpy(fstat_reply + 48, &size, 8); }
    arm(0);
    memset(&st, 0xAA, sizeof st);
    CHECK(moqi_fstat(5, &st) == 0 && c_nr == SYS_fstat && c_a1 == 5 && c_a2 == (long)&st);
    CHECK(st.st_ino == 55 && st.st_nlink == 2 && st.st_mode == 0100600 && st.st_uid == 7 && st.st_size == 99);

    /* a field the kernel did not cover (mask lacks it) reads as 0, never as stale stack bytes */
    memset(statx_reply, 0, sizeof statx_reply);
    put32(0, 0x1 | 0x2 | 0x200);    /* type, mode, size only */
    put32(28, 0040755);
    put64(40, 4096);
    put64(64, 9999);                /* time bytes present but the mask does not claim them */
    arm(0);
    memset(&st, 0xAA, sizeof st);
    CHECK(moqi_stat("/tmp/d", &st) == 0 && st.st_mode == 0040755 && st.st_size == 4096);
    CHECK(st.st_nlink == 0 && st.st_uid == 0 && st.st_atim.tv_sec == 0 && st.st_blocks == 0 && st.st_ino == 0);

    /* each field is guarded by its own mask bit: with only the mode claimed, everything else is 0 even though the bytes are set */
    memset(statx_reply, 0, sizeof statx_reply);
    put32(0, 0x2);
    put32(16, 9); put32(20, 9); put32(24, 9); put32(28, 0100644); put64(32, 9); put64(40, 9); put64(48, 9);
    put64(64, 9); put64(96, 9); put64(112, 9);
    arm(0);
    memset(&st, 0xAA, sizeof st);
    CHECK(moqi_stat("/tmp/f", &st) == 0 && st.st_mode == 0100644);
    CHECK(st.st_nlink == 0 && st.st_uid == 0 && st.st_gid == 0 && st.st_ino == 0 && st.st_size == 0 && st.st_blocks == 0);
    CHECK(st.st_atim.tv_sec == 0 && st.st_mtim.tv_sec == 0 && st.st_ctim.tv_sec == 0);

    /* errors */
    arm(-2);
    CHECK(moqi_stat("/tmp/nope", &st) == -1 && errno_slot == ENOENT);
    arm(-20);
    CHECK(moqi_stat("/tmp/f/x", &st) == -1 && errno_slot == ENOTDIR);
    arm(-9);
    CHECK(moqi_fstat(999, &st) == -1 && errno_slot == EBADF);
    arm(-14);
    CHECK(moqi_lstat("/tmp/f", &st) == -1 && errno_slot == EFAULT);

    /* chmod / fchmod / readlink / symlink / link */
    arm(0);
    const char *cp = "/tmp/f";
    CHECK(moqi_chmod(cp, 0600) == 0 && c_nr == SYS_chmod && c_a1 == (long)cp && c_a2 == 0600);
    arm(-2);
    CHECK(moqi_chmod("/tmp/nope", 0600) == -1 && errno_slot == ENOENT);
    arm(0);
    CHECK(moqi_fchmod(4, 0644) == 0 && c_nr == SYS_fchmod && c_a1 == 4 && c_a2 == 0644);
    arm(-9);
    CHECK(moqi_fchmod(999, 0644) == -1 && errno_slot == EBADF);
    char buf[8];
    arm(1);
    CHECK(moqi_readlink("/tmp/ln", buf, sizeof buf) == 1 && c_nr == SYS_readlink && c_a2 == (long)buf && c_a3 == 8);
    arm(-22);
    CHECK(moqi_readlink("/tmp/f", buf, sizeof buf) == -1 && errno_slot == EINVAL);
    arm(0);
    CHECK(moqi_symlink("f", "/tmp/ln") == 0 && c_nr == SYS_symlink);
    arm(-17);
    CHECK(moqi_symlink("f", "/tmp/ln") == -1 && errno_slot == EEXIST);
    arm(0);
    CHECK(moqi_link("/tmp/f", "/tmp/hl") == 0 && c_nr == SYS_link);
    arm(-2);
    CHECK(moqi_link("/tmp/nope", "/tmp/hl") == -1 && errno_slot == ENOENT);

    if (bad) { fprintf(stderr, "%d check(s) failed\n", bad); return 1; }
    printf("test_stat_abi: ok\n");
    return 0;
}
