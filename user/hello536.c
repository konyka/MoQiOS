/* hello536: the database name of an /etc/nsswitch.conf line ends at a blank or a colon (glibc 2.44 process_line, measured).
 * A: "hosts files" after "hosts: dns" is the last hosts line, so /etc/hosts answers; B: "hosts::files" and "hosts : : files"
 * the same; C: a bare "hosts" after "hosts: files" is an empty list, so the lookup fails (not the "files dns" default);
 * D: ":files" and "hostsfiles" are not hosts lines, so "hosts: dns" stays the last one and /etc/hosts is not asked; E: cleanup.
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
    print(ok ? "hello536:   ok   " : "hello536:   FAIL ");
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
/* "hit" when /etc/hosts answered, else "NULL". No nameserver is configured, so DNS cannot answer this name. */
static const char *lookup(const char *conf, int *wrote) {
    *wrote = write_file("/etc/nsswitch.conf", conf);
    struct hostent *h = gethostbyname("late536.test");
    return h && (unsigned char)h->h_addr_list[0][3] == 1 ? "hit" : "NULL";
}
int main(void) {
    print("hello536: the database name ends at a blank or a colon\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int wh = write_file("/etc/hosts", "10.5.36.1 late536.test\n");
    int wr = write_file("/etc/resolv.conf", "nameserver 127.0.0.1\noptions timeout:1 attempts:1\n");
    int w1, w2, w3;

    const char *a = lookup("hosts: dns\nhosts files\n", &w1);
    snprintf(msg, sizeof msg, "A: 'hosts files' last (%d %d %d): %s (hit)", wh, wr, w1, a);
    check(wh == 0 && wr == 0 && w1 == 0 && strcmp(a, "hit") == 0, msg);

    const char *b1 = lookup("hosts: dns\nhosts::files\n", &w1);
    const char *b2 = lookup("hosts: dns\nhosts : : files\n", &w2);
    snprintf(msg, sizeof msg, "B: 'hosts::files' %s, 'hosts : : files' %s (%d %d) (hit hit)", b1, b2, w1, w2);
    check(w1 == 0 && w2 == 0 && strcmp(b1, "hit") == 0 && strcmp(b2, "hit") == 0, msg);

    const char *c = lookup("hosts: files\nhosts\n", &w1);
    snprintf(msg, sizeof msg, "C: a bare 'hosts' last (%d): %s (NULL)", w1, c);
    check(w1 == 0 && strcmp(c, "NULL") == 0, msg);

    const char *d1 = lookup("hosts: dns\n:files\n", &w1);
    const char *d2 = lookup("hosts: dns\nhostsfiles\n", &w2);
    const char *d3 = lookup("hosts: dns\n", &w3);
    snprintf(msg, sizeof msg, "D: ':files' %s, 'hostsfiles' %s, 'hosts: dns' alone %s (%d %d %d) (NULL NULL NULL)", d1, d2, d3, w1,
             w2, w3);
    check(w1 == 0 && w2 == 0 && w3 == 0 && strcmp(d1, "NULL") == 0 && strcmp(d2, "NULL") == 0 && strcmp(d3, "NULL") == 0, msg);

    long u1 = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf"), u3 = unlink("/etc/resolv.conf");
    snprintf(msg, sizeof msg, "E: unlink %ld %ld %ld (0 0 0)", u1, u2, u3);
    check(u1 == 0 && u2 == 0 && u3 == 0, msg);
    print(failures ? "hello536: FAIL\n" : "hello536: PASS\n");
    return failures ? 1 : 0;
}
