/* stat.h -- file status and permissions for moqi_libc.
 *
 * struct stat is glibc's x86-64 layout (measured on glibc 2.43): 144 bytes, st_dev 0, st_ino 8, st_nlink 16, st_mode 24, st_uid 28,
 * st_gid 32, st_rdev 40, st_size 48, st_blksize 56, st_blocks 64, st_atim 72, st_mtim 88, st_ctim 104. The mode macros S_ISREG,
 * S_ISDIR, ... and the permission bits are the usual octal values.
 *
 * stat and lstat ask the kernel with statx; fields the filesystem does not keep are 0 (st_dev and st_rdev always, the times and
 * st_blocks on tmpfs). lstat does not follow a final symbolic link. fstat is the kernel's own fstat. All of them return 0, or -1 with
 * errno (ENOENT, ENOTDIR, EBADF, EFAULT, EACCES, ...). chmod and fchmod set the permission bits (07777), readlink fills the buffer
 * without a terminating NUL and returns the length (EINVAL when the file is not a link), symlink and link create a symbolic and a
 * hard link (EEXIST when the name exists). unistd.h declares nothing of these.
 *
 * statfs and fstatfs fill struct statfs, glibc's x86-64 layout (120 bytes, measured): f_type 0, f_bsize 8, f_blocks 16, f_bfree 24,
 * f_bavail 32, f_files 40, f_ffree 48, f_fsid 56, f_namelen 64, f_frsize 72, f_flags 80, then four spare words. They return 0, or -1 with
 * errno (ENOENT, ENOTDIR, EACCES, EBADF, EFAULT, EIO). The kernel reports each filesystem's own type, sizes and inode counts: f_type is
 * TMPFS_MAGIC, MSDOS_SUPER_MAGIC or EXT2_SUPER_MAGIC below, and FAT has no inode table (f_files and f_ffree are 0).
 */
#ifndef MOQI_STAT_H
#define MOQI_STAT_H

#include <stddef.h>

#include "time.h"

struct stat {
    unsigned long  st_dev;
    unsigned long  st_ino;
    unsigned long  st_nlink;
    unsigned int   st_mode;
    unsigned int   st_uid;
    unsigned int   st_gid;
    int            __pad0;
    unsigned long  st_rdev;
    long           st_size;
    long           st_blksize;
    long           st_blocks;
    struct timespec st_atim;
    struct timespec st_mtim;
    struct timespec st_ctim;
    long           __unused[3];
};

#define S_IFMT   0170000
#define S_IFSOCK 0140000
#define S_IFLNK  0120000
#define S_IFREG  0100000
#define S_IFBLK  0060000
#define S_IFDIR  0040000
#define S_IFCHR  0020000
#define S_IFIFO  0010000

#define S_ISUID 04000
#define S_ISGID 02000
#define S_ISVTX 01000
#define S_IRWXU 00700
#define S_IRUSR 00400
#define S_IWUSR 00200
#define S_IXUSR 00100
#define S_IRWXG 00070
#define S_IRGRP 00040
#define S_IWGRP 00020
#define S_IXGRP 00010
#define S_IRWXO 00007
#define S_IROTH 00004
#define S_IWOTH 00002
#define S_IXOTH 00001

#define S_ISREG(m)  (((m) & S_IFMT) == S_IFREG)
#define S_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m)  (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m)  (((m) & S_IFMT) == S_IFBLK)
#define S_ISFIFO(m) (((m) & S_IFMT) == S_IFIFO)
#define S_ISLNK(m)  (((m) & S_IFMT) == S_IFLNK)
#define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK)

int stat(const char *path, struct stat *buf);
int lstat(const char *path, struct stat *buf);
int fstat(int fd, struct stat *buf);
int chmod(const char *path, unsigned int mode);
int fchmod(int fd, unsigned int mode);
long readlink(const char *path, char *buf, size_t size);
int symlink(const char *target, const char *linkpath);
int link(const char *oldpath, const char *newpath);

struct statfs {
    long f_type;
    long f_bsize;
    unsigned long f_blocks;
    unsigned long f_bfree;
    unsigned long f_bavail;
    unsigned long f_files;
    unsigned long f_ffree;
    int f_fsid[2];
    long f_namelen;
    long f_frsize;
    long f_flags;
    long f_spare[4];
};

#define TMPFS_MAGIC        0x01021994
#define MSDOS_SUPER_MAGIC  0x4d44
#define EXT2_SUPER_MAGIC   0xEF53
#define ST_RDONLY          1

int statfs(const char *path, struct statfs *buf);
int fstatfs(int fd, struct statfs *buf);

#endif
