/* dirent.h — directory streams: opendir, readdir, rewinddir, seekdir, telldir, closedir, dirfd.
 *
 * Layout and behavior follow glibc on x86-64 (measured; host_tests/test_dirent_abi.c): struct dirent is 280 bytes with d_ino at
 * 0, d_off at 8, d_reclen at 16, d_type at 18 and the NUL-terminated name at 19. A stream reads the kernel's getdents64 records
 * through a 4096-byte buffer, hands out one record at a time, and returns the same storage for each result (a result is valid
 * only until the next readdir on that stream). The directory is opened close-on-exec. Order is whatever the file system gives.
 *
 * opendir returns NULL with errno ENOENT (missing, or an empty path), ENOTDIR (not a directory), EACCES and the like from open.
 * readdir returns NULL at the end with errno untouched, and NULL with errno set on an error. closedir closes the descriptor
 * (0, or -1 with errno) and frees the stream. rewinddir restarts the listing. telldir/seekdir save and restore a position; a
 * position is valid only for the stream it came from and only while the directory has not changed.
 */
#ifndef MOQI_DIRENT_H
#define MOQI_DIRENT_H

#include <stddef.h>

#define DT_UNKNOWN 0
#define DT_FIFO    1
#define DT_CHR     2
#define DT_DIR     4
#define DT_BLK     6
#define DT_REG     8
#define DT_LNK     10
#define DT_SOCK    12

struct dirent {
    unsigned long d_ino;
    long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};

typedef struct __moqi_dir DIR;

DIR *opendir(const char *path);
struct dirent *readdir(DIR *dir);
int closedir(DIR *dir);
void rewinddir(DIR *dir);
long telldir(DIR *dir);
void seekdir(DIR *dir, long pos);
int dirfd(DIR *dir);

#endif /* MOQI_DIRENT_H */
