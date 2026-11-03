/* stdio_file.h — the FILE layer: fopen, fclose, fread, fwrite, fgets, fgetc, fputs, fputc, ungetc, fseek, ftell, fflush,
 * feof, ferror, clearerr, setvbuf, getline, fprintf, ... (see include/stdio.h).
 *
 * It is one header-only implementation so that the same code runs on the host against an in-memory file system: all I/O
 * goes through the IO_* macros, which the freestanding build maps to the system calls (stdio.c) and the test maps to its
 * own functions, and every exported name goes through NAME() (the test prefixes them so they cannot collide with the
 * host's libc).
 *
 * Behavior follows glibc as measured (host_tests/test_file_abi.c):
 *   - buffering: a file stream is fully buffered (4096 bytes, glibc's choice on a filesystem whose st_blksize is 4096), stderr is unbuffered, stdout is line buffered; output
 *     appears when the buffer fills, after a newline for a line-buffered stream, on fflush, fclose or exit;
 *   - EOF and error are separate sticky flags, cleared by clearerr or a successful fseek (and EOF by ungetc); once EOF is
 *     set a read returns EOF without asking the descriptor, until the flag is cleared;
 *   - a read-ahead window is given back (the descriptor is moved to the logical position) before the stream writes or
 *     seeks, a write buffer is flushed before the stream reads or seeks, ftell reports the logical position, ungetc pushes
 *     back at least one byte (more while there is room in front of the read position);
 *   - an operation in the wrong direction (reading a write-only stream, writing a read-only one) is EBADF and sets the
 *     error flag; the kernel's own error code is passed on for everything else.
 * Not provided: file locking, wide-character streams, tmpfile, popen, freopen, fgetpos/fsetpos, setbuf.
 */
#ifndef MOQI_STDIO_FILE_H
#define MOQI_STDIO_FILE_H

#define F_READ      0x01
#define F_WRITE     0x02
#define F_APPEND    0x04
#define F_EOF       0x08
#define F_ERR       0x10
#define F_USERBUF   0x20
#define F_STATIC    0x40
#define F_FRESH     0x80   /* the read window holds only pushed-back bytes that never came from the descriptor */

#define FB_FULL 0
#define FB_LINE 1
#define FB_NONE 2

#define FILE_BUFSIZE 4096

struct FILE_s {
    int fd;
    int flags;
    unsigned char *buf;  /* FILE_BUFSIZE bytes (or the caller's), allocated on first use */
    size_t bufsize;
    size_t rpos, rend;   /* read-ahead window buf[rpos..rend) */
    size_t wpos;         /* pending output buf[0..wpos) */
    int bmode;           /* FB_* */
    int bufmode_fixed;   /* the mode was chosen (setvbuf or a standard stream) */
    int fresh_buf;       /* the buffer was allocated by the current write: glibc treats it as having no room yet */
    struct FILE_s *next; /* every open stream, for fflush(NULL) */
};

#endif
