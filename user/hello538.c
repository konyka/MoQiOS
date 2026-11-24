/* hello538: a hosts line of /etc/nsswitch.conf has no limit on its sources (glibc 2.44 keeps them all, measured). A: "files"
 * after twelve unknown sources answers gethostbyname from /etc/hosts; B: getaddrinfo the same; C: a name /etc/hosts does not
 * have, after ten unknown sources and "files [NOTFOUND=return] dns", is HOST_NOT_FOUND from the files source (not
 * NETDB_INTERNAL); D: cleanup. Measured with -DHOST through glibc in `unshare -r -m -n` with a tmpfs on /etc, so both builds
 * create and remove the same files. */
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
static char conf[512];
static void check(int ok, const char *w) {
    print(ok ? "hello538:   ok   " : "hello538:   FAIL ");
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
/* conf = "hosts:", `n` times " bogus", then tail. */
static int build(int n, const char *tail) {
    strcpy(conf, "hosts:");
    for (int i = 0; i < n; i++) strcat(conf, " bogus");
    strcat(conf, tail);
    return write_file("/etc/nsswitch.conf", conf);
}
int main(void) {
    print("hello538: a hosts line has no limit on its sources\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int wh = write_file("/etc/hosts", "10.5.38.1 many538.test\n");
    int wr = write_file("/etc/resolv.conf", "nameserver 127.0.0.1\noptions timeout:1 attempts:1\n");

    int w = build(12, " files\n");
    struct hostent *h = gethostbyname("many538.test");
    const char *a = h && (unsigned char)h->h_addr_list[0][3] == 1 ? "hit" : "NULL";
    snprintf(msg, sizeof msg, "A: 'files' after 12 unknown sources (%d %d %d): %s (hit)", wh, wr, w, a);
    check(wh == 0 && wr == 0 && w == 0 && strcmp(a, "hit") == 0, msg);

    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int g = getaddrinfo("many538.test", 0, &hints, &res);
    int b_ok = g == 0 && res && ((unsigned char *)res->ai_addr)[7] == 1;
    if (g == 0) freeaddrinfo(res);
    snprintf(msg, sizeof msg, "B: getaddrinfo with the same line: %d (0)", g);
    check(b_ok, msg);

    w = build(10, " files [NOTFOUND=return] dns\n");
    h_errno = 0;
    h = gethostbyname("absent538.test");
    int he = h_errno;
    snprintf(msg, sizeof msg, "C: absent name after 10 unknown sources (%d): %s h_errno %d (NULL 1)", w, h ? "hit" : "NULL", he);
    check(w == 0 && !h && he == HOST_NOT_FOUND, msg);

    long u1 = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf"), u3 = unlink("/etc/resolv.conf");
    snprintf(msg, sizeof msg, "D: unlink %ld %ld %ld (0 0 0)", u1, u2, u3);
    check(u1 == 0 && u2 == 0 && u3 == 0, msg);
    print(failures ? "hello538: FAIL\n" : "hello538: PASS\n");
    return failures ? 1 : 0;
}
