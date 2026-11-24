/* hello537: /etc/nsswitch.conf lines have no length limit (glibc 2.44 reads them with getline, measured). A: a hosts line with
 * 2000 blanks before "files" is the last hosts line, so /etc/hosts answers; B: a passwd line with 5000 blanks before a bad
 * action voids the file, so the lookup fails with NETDB_INTERNAL and errno EINVAL; C: a long valid "files [NOTFOUND=return] dns"
 * line answers from /etc/hosts; D: cleanup. Measured with -DHOST through glibc in `unshare -r -m -n` with a tmpfs on /etc, so
 * both builds create and remove the same files. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
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
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/netdb.h"
#endif
static int failures;
static char msg[300];
static char conf[6000];
static void check(int ok, const char *w) {
    print(ok ? "hello537:   ok   " : "hello537:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int write_file(const char *path, const char *text) {
    int fd = (int)open(path, 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
/* conf = head, `blanks` spaces, tail. */
static void build(const char *head, int blanks, const char *tail) {
    size_t n = strlen(head);
    memcpy(conf, head, n);
    for (int i = 0; i < blanks; i++) conf[n++] = ' ';
    memcpy(conf + n, tail, strlen(tail) + 1);
}
/* "hit" when /etc/hosts answered, else "NULL". The nameserver does not answer, so DNS cannot supply this name. */
static const char *lookup(int *wrote, int *herr, int *err) {
    *wrote = write_file("/etc/nsswitch.conf", conf);
    h_errno = 0;
    errno = 0;
    struct hostent *h = gethostbyname("late537.test");
    *herr = h_errno;
    *err = errno;
    return h && (unsigned char)h->h_addr_list[0][3] == 1 ? "hit" : "NULL";
}
int main(void) {
    print("hello537: nsswitch.conf lines have no length limit\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int wh = write_file("/etc/hosts", "10.5.37.1 late537.test\n");
    int wr = write_file("/etc/resolv.conf", "nameserver 127.0.0.1\noptions timeout:1 attempts:1\n");
    int w, he, e;

    build("hosts: dns\nhosts:", 2000, "files\n");
    const char *a = lookup(&w, &he, &e);
    snprintf(msg, sizeof msg, "A: 2000 blanks before 'files' (%d %d %d): %s (hit)", wh, wr, w, a);
    check(wh == 0 && wr == 0 && w == 0 && strcmp(a, "hit") == 0, msg);

    build("hosts: files\npasswd: files", 5000, "[NOTFOUND=foo]\n");
    const char *b = lookup(&w, &he, &e);
    snprintf(msg, sizeof msg, "B: 5000-byte bad passwd line (%d): %s h_errno %d errno %d (NULL -1 22)", w, b, he, e);
    check(w == 0 && strcmp(b, "NULL") == 0 && he == NETDB_INTERNAL && e == EINVAL, msg);

    build("hosts: dns\nhosts:", 2000, "files [NOTFOUND=return] dns\n");
    const char *c = lookup(&w, &he, &e);
    snprintf(msg, sizeof msg, "C: long 'files [NOTFOUND=return] dns' (%d): %s (hit)", w, c);
    check(w == 0 && strcmp(c, "hit") == 0, msg);

    long u1 = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf"), u3 = unlink("/etc/resolv.conf");
    snprintf(msg, sizeof msg, "D: unlink %ld %ld %ld (0 0 0)", u1, u2, u3);
    check(u1 == 0 && u2 == 0 && u3 == 0, msg);
    print(failures ? "hello537: FAIL\n" : "hello537: PASS\n");
    return failures ? 1 : 0;
}
