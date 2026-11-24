/* hello534: the whole /etc/nsswitch.conf is read (glibc 2.44, measured with 100000 bytes). A: an empty hosts line first, then
 * 6000 bytes of comments, then "hosts: files": /etc/hosts answers; B: a comment line of 9000 bytes before "hosts: files" does
 * not hide it; C: "hosts:" (refused) as the last line without a newline is ignored (glibc's getline loop stops at end of
 * file), so the "hosts: files" before it answers; D: cleanup.
 * Measured with -DHOST through glibc in `unshare -r -m -n` with a tmpfs on /etc, so both builds create and remove the same
 * files. */
#ifdef HOST
#define _GNU_SOURCE
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello534:   ok   " : "hello534:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int put(int fd, const char *text, size_t n) { return (long)write(fd, text, n) == (long)n ? 0 : -1; }
/* /etc/nsswitch.conf from `head`, `pad` bytes of filler ('#' lines of 40 bytes, or one '#' line), then `tail`. */
static int write_conf(const char *head, int pad, int one_line, const char *tail) {
    int fd = (int)open("/etc/nsswitch.conf", 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    int rc = put(fd, head, strlen(head));
    static char filler[10000];
    if (one_line) {
        filler[0] = '#';
        memset(filler + 1, 'x', (size_t)pad - 2);
        filler[pad - 1] = '\n';
        rc |= put(fd, filler, (size_t)pad);
    } else {
        for (int i = 0; i < pad / 40; i++) rc |= put(fd, "# padding padding padding padding paddi\n", 40);
    }
    rc |= put(fd, tail, strlen(tail));
    close(fd);
    return rc;
}
static void lookup(char *out, size_t cap) {
    h_errno = 0;
    struct hostent *h = gethostbyname("late534.test");
    if (h) snprintf(out, cap, "%s %d.%d.%d.%d", h->h_name, (unsigned char)h->h_addr_list[0][0], (unsigned char)h->h_addr_list[0][1],
                    (unsigned char)h->h_addr_list[0][2], (unsigned char)h->h_addr_list[0][3]);
    else snprintf(out, cap, "NULL/%d", h_errno);
}
int main(void) {
    print("hello534: the whole nsswitch.conf is read\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int hf = (int)open("/etc/hosts", 0x041 | 0x200, 0644);
    int wh = hf >= 0 ? put(hf, "10.5.34.1 late534.test\n", 23) : -1;
    if (hf >= 0) close(hf);
    char got[120];

    int w = write_conf("hosts:\n", 6000, 0, "hosts: files\n");
    lookup(got, sizeof got);
    snprintf(msg, sizeof msg, "A: hosts line after 6000 bytes (%d %d): '%s' ('late534.test 10.5.34.1')", wh, w, got);
    check(wh == 0 && w == 0 && strcmp(got, "late534.test 10.5.34.1") == 0, msg);

    w = write_conf("hosts:\n", 9000, 1, "hosts: files\n");
    lookup(got, sizeof got);
    snprintf(msg, sizeof msg, "B: after a 9000-byte line (%d): '%s' ('late534.test 10.5.34.1')", w, got);
    check(w == 0 && strcmp(got, "late534.test 10.5.34.1") == 0, msg);

    w = write_conf("hosts: files\n", 3000, 0, "hosts:");
    lookup(got, sizeof got);
    snprintf(msg, sizeof msg, "C: a refused last line without newline (%d): '%s' ('late534.test 10.5.34.1')", w, got);
    check(w == 0 && strcmp(got, "late534.test 10.5.34.1") == 0, msg);

    long u1 = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf");
    snprintf(msg, sizeof msg, "D: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello534: FAIL\n" : "hello534: PASS\n");
    return failures ? 1 : 0;
}
