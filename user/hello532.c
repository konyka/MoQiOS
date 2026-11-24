/* hello532: loopback has no built-in name (glibc 2.44, measured with "hosts: files"). A: no /etc/hosts: getnameinfo gives
 * 127.0.0.1 and ::1, NI_NAMEREQD is EAI_NONAME, gethostbyaddr(127.0.0.1) is NULL; B: an empty /etc/hosts: the same, h_errno
 * HOST_NOT_FOUND; C: with "127.0.0.1 localhost" and "::1 ip6-localhost" lines both are named; D: cleanup. Measured with -DHOST
 * through glibc in `unshare -m -n` with a tmpfs on /etc, so both builds create and remove the same files. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define SA(p) ((const struct sockaddr *)(p))
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define SA(p) ((const uint8_t *)(p))
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello532:   ok   " : "hello532:   FAIL ");
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
static unsigned char sa4[16], sa6[28];
/* getnameinfo of the IPv4 and IPv6 loopback, plain and with NI_NAMEREQD, then gethostbyaddr(127.0.0.1), as one string. */
static void names(char *out, size_t cap) {
    char h1[64], h2[64], h3[64] = "", h4[64] = "";
    int r1 = getnameinfo(SA(sa4), 16, h1, sizeof h1, 0, 0, 0);
    int r2 = getnameinfo(SA(sa4), 16, h3, sizeof h3, 0, 0, NI_NAMEREQD);
    int r3 = getnameinfo(SA(sa6), 28, h2, sizeof h2, 0, 0, 0);
    int r4 = getnameinfo(SA(sa6), 28, h4, sizeof h4, 0, 0, NI_NAMEREQD);
    struct hostent *he = gethostbyaddr(sa4 + 4, 4, AF_INET);
    char g[80];
    if (he) snprintf(g, sizeof g, "%s", he->h_name);
    else snprintf(g, sizeof g, "NULL/%d", h_errno);
    snprintf(out, cap, "%d %s %d %s | %d %s %d %s | %s", r1, r1 ? "-" : h1, r2, r2 ? "-" : h3, r3, r3 ? "-" : h2, r4,
             r4 ? "-" : h4, g);
}
int main(void) {
    print("hello532: loopback has no built-in name\n");
    memset(sa4, 0, sizeof sa4);
    sa4[0] = AF_INET;
    sa4[4] = 127;
    sa4[7] = 1;
    memset(sa6, 0, sizeof sa6);
    sa6[0] = AF_INET6;
    sa6[23] = 1;
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    unlink("/etc/hosts");
    int wn = write_file("/etc/nsswitch.conf", "hosts: files\n");
    char got[300], want[300];
    names(got, sizeof got);
    snprintf(want, sizeof want, "0 127.0.0.1 %d - | 0 ::1 %d - | NULL/0", EAI_NONAME, EAI_NONAME);
    snprintf(msg, sizeof msg, "A: no /etc/hosts (nsswitch %d): '%s' ('%s')", wn, got, want);
    check(wn == 0 && strcmp(got, want) == 0, msg);

    int wh = write_file("/etc/hosts", "");
    names(got, sizeof got);
    snprintf(want, sizeof want, "0 127.0.0.1 %d - | 0 ::1 %d - | NULL/%d", EAI_NONAME, EAI_NONAME, HOST_NOT_FOUND);
    snprintf(msg, sizeof msg, "B: empty /etc/hosts (%d): '%s' ('%s')", wh, got, want);
    check(wh == 0 && strcmp(got, want) == 0, msg);

    wh = write_file("/etc/hosts", "127.0.0.1 localhost\n::1 ip6-localhost\n");
    names(got, sizeof got);
    snprintf(msg, sizeof msg, "C: with loopback lines (%d): '%s' ('0 localhost 0 localhost | 0 ip6-localhost 0 ip6-localhost | localhost')",
             wh, got);
    check(wh == 0 && strcmp(got, "0 localhost 0 localhost | 0 ip6-localhost 0 ip6-localhost | localhost") == 0, msg);

    long u1 = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf");
    snprintf(msg, sizeof msg, "D: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello532: FAIL\n" : "hello532: PASS\n");
    return failures ? 1 : 0;
}
