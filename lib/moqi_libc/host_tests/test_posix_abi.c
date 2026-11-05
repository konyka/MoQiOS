/* test_posix_abi.c — getuid/alarm/pause/isatty/remove/rename/perror (src/posix.c) against a recording system-call stub.
 * The expectations are what glibc does for the same calls (measured on glibc 2.43): remove removes a file with unlink and an
 * empty directory with rmdir, perror writes "prog: message\n" in one write and leaves errno alone, isatty is 0 with ENOTTY
 * for anything that is not a terminal.
 */
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"

/* The host's declarations of these names are not wanted: the library's are compiled under other names. */
unsigned int moqi_getuid(void);
unsigned int moqi_geteuid(void);
unsigned int moqi_getgid(void);
unsigned int moqi_getegid(void);
int moqi_getppid(void);
unsigned int moqi_alarm(unsigned int);
int moqi_pause(void);
int moqi_isatty(int);
long moqi_rmdir(const char *);
int moqi_rename(const char *, const char *);
int moqi_remove(const char *);
void moqi_perror(const char *);

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

#define MAXCALLS 8
static int ncalls;
static long c_nr[MAXCALLS], c_a1[MAXCALLS], c_a2[MAXCALLS], c_a3[MAXCALLS];
static char c_text[MAXCALLS][600];     /* for write: what was written */
static long reply[MAXCALLS];           /* scripted reply for the Nth call (default 0) */

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a4; (void)a5; (void)a6;
    int i = ncalls < MAXCALLS ? ncalls : MAXCALLS - 1;
    c_nr[i] = nr; c_a1[i] = a1; c_a2[i] = a2; c_a3[i] = a3;
    if (nr == SYS_write) {
        size_t n = (size_t)a3 < sizeof c_text[i] - 1 ? (size_t)a3 : sizeof c_text[i] - 1;
        memcpy(c_text[i], (const void *)a2, n);
        c_text[i][n] = 0;
        if (reply[ncalls] == 0) { ncalls++; return a3; }
    }
    return reply[ncalls++];
}

static void reset(void) {
    ncalls = 0;
    memset(reply, 0, sizeof reply);
    errno_slot = 0;
}

int main(void) {
    CHECK(SYS_getuid == 201 && SYS_getgid == 202 && SYS_geteuid == 203 && SYS_getegid == 204 && SYS_getppid == 205);
    CHECK(SYS_alarm == 37 && SYS_pause == 34 && SYS_ioctl == 165 && SYS_rename == 212 && SYS_rmdir == 84 && SYS_unlink == 111);

    /* identity: whatever the kernel says, as an unsigned id */
    reset(); reply[0] = 1000;
    CHECK(moqi_getuid() == 1000 && c_nr[0] == SYS_getuid);
    reset(); reply[0] = 0; CHECK(moqi_geteuid() == 0 && c_nr[0] == SYS_geteuid);
    reset(); reply[0] = 7; CHECK(moqi_getgid() == 7 && c_nr[0] == SYS_getgid);
    reset(); reply[0] = 8; CHECK(moqi_getegid() == 8 && c_nr[0] == SYS_getegid);
    reset(); reply[0] = 1; CHECK(moqi_getppid() == 1 && c_nr[0] == SYS_getppid);

    /* alarm: seconds in, previous remaining out */
    reset(); reply[0] = 5;
    CHECK(moqi_alarm(10) == 5 && c_nr[0] == SYS_alarm && c_a1[0] == 10);
    reset(); CHECK(moqi_alarm(0) == 0 && c_a1[0] == 0);
    reset(); reply[0] = 3; CHECK(moqi_alarm(4294967295u) == 3 && c_a1[0] == 4294967295L);

    /* pause: always -1 with the kernel's error */
    reset(); reply[0] = -4;
    CHECK(moqi_pause() == -1 && errno_slot == EINTR && c_nr[0] == SYS_pause);

    /* isatty: TCGETS answers 0 on a terminal, ENOTTY or EBADF otherwise */
    reset(); reply[0] = 0;
    CHECK(moqi_isatty(1) == 1 && c_nr[0] == SYS_ioctl && c_a1[0] == 1 && c_a2[0] == 0x5401 && c_a3[0] != 0);
    reset(); reply[0] = -25; errno_slot = 0;
    CHECK(moqi_isatty(0) == 0 && errno_slot == ENOTTY);
    reset(); reply[0] = -9; errno_slot = 0;
    CHECK(moqi_isatty(999) == 0 && errno_slot == EBADF);

    /* rmdir: the raw kernel value */
    reset(); reply[0] = -39;
    CHECK(moqi_rmdir("/tmp/d") == -39 && c_nr[0] == SYS_rmdir && strcmp((const char *)c_a1[0], "/tmp/d") == 0);

    /* rename */
    reset(); reply[0] = 0;
    CHECK(moqi_rename("a", "b") == 0 && c_nr[0] == SYS_rename && strcmp((const char *)c_a1[0], "a") == 0 && strcmp((const char *)c_a2[0], "b") == 0);
    reset(); reply[0] = -2; errno_slot = 0;
    CHECK(moqi_rename("a", "b") == -1 && errno_slot == ENOENT);

    /* remove: a file by unlink; a directory (unlink says EISDIR) by rmdir; errors are the kernel's */
    reset(); reply[0] = 0; errno_slot = 99;
    CHECK(moqi_remove("f") == 0 && ncalls == 1 && c_nr[0] == SYS_unlink && errno_slot == 99);
    reset(); reply[0] = -21; reply[1] = 0;
    CHECK(moqi_remove("d") == 0 && ncalls == 2 && c_nr[0] == SYS_unlink && c_nr[1] == SYS_rmdir && strcmp((const char *)c_a1[1], "d") == 0);
    reset(); reply[0] = -21; reply[1] = -39; errno_slot = 0;
    CHECK(moqi_remove("d") == -1 && errno_slot == ENOTEMPTY && ncalls == 2);
    reset(); reply[0] = -2; errno_slot = 0;
    CHECK(moqi_remove("m") == -1 && errno_slot == ENOENT && ncalls == 1);
    reset(); reply[0] = -13; errno_slot = 0;
    CHECK(moqi_remove("p") == -1 && errno_slot == EACCES && ncalls == 1);

    /* perror: one write to fd 2, errno untouched */
    reset(); errno_slot = ENOENT;
    moqi_perror("prog");
    CHECK(ncalls == 1 && c_nr[0] == SYS_write && c_a1[0] == 2);
    CHECK(strcmp(c_text[0], "prog: No such file or directory\n") == 0);
    CHECK(errno_slot == ENOENT);
    reset(); errno_slot = EINVAL; moqi_perror((const char *)0);
    CHECK(strcmp(c_text[0], "Invalid argument\n") == 0 && ncalls == 1);
    reset(); errno_slot = EINVAL; moqi_perror("");
    CHECK(strcmp(c_text[0], "Invalid argument\n") == 0);
    reset(); errno_slot = 0; moqi_perror("zero");
    CHECK(strcmp(c_text[0], "zero: Success\n") == 0);
    reset(); errno_slot = 9999; moqi_perror("big");
    CHECK(strcmp(c_text[0], "big: Unknown error 9999\n") == 0);
    reset(); errno_slot = ERANGE; moqi_perror("x");
    CHECK(strcmp(c_text[0], "x: Numerical result out of range\n") == 0);
    {
        char longp[800];
        memset(longp, 'p', sizeof longp - 1); longp[sizeof longp - 1] = 0;
        reset(); errno_slot = ENOENT; moqi_perror(longp);
        CHECK(ncalls == 1 && strlen(c_text[0]) <= 512 && c_text[0][strlen(c_text[0]) - 1] == '\n');
    }
    /* a failing write sets errno to its error */
    reset(); reply[0] = -9; errno_slot = ENOENT; moqi_perror("w");
    CHECK(errno_slot == EBADF);

    if (bad) { fprintf(stderr, "test_posix_abi: %d failure(s)\n", bad); return 1; }
    printf("test_posix_abi: ok\n");
    return 0;
}
