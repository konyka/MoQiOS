/* hello504: getnameinfo names an address from /etc/hosts (glibc's "files" reverse lookup). A creates /etc/hosts; B the first line
 * with the address gives its first name, also under NI_NAMEREQD; C NI_NUMERICHOST stays numeric and a buffer one byte short of the
 * name is EAI_OVERFLOW; D an address not in the file is numeric, NI_NAMEREQD makes it EAI_NONAME; E 127.0.0.1 is localhost;
 * F cleanup, after which the address is numeric again. Measured with -DHOST in a mount namespace with /etc/hosts bind-mounted. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H504") ? getenv("H504") : "/etc/hosts")
#define SA(p) ((const struct sockaddr *)(p))
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
#define SA(p) (p)
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello504:   ok   " : "hello504:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] = "127.0.0.1 localhost\n# 10.5.0.4 commented504\n10.5.0.4\tFirst504.example  alias504\n"
                            "10.5.0.4 second504\n10.5.0.9 nine504.example\n";
static unsigned char sa[16];
static int name_of(unsigned char d, int flags, unsigned int len, char *out) {
    memset(sa, 0, sizeof sa);
    sa[0] = 2;
    sa[4] = 10;
    sa[5] = 5;
    sa[6] = 0;
    sa[7] = d;
    if (d == 0) { sa[4] = 127; sa[5] = 0; sa[7] = 1; }
    out[0] = 0;
    return getnameinfo(SA(sa), 16, out, len, 0, 0, flags);
}
int main(void) {
    print("hello504: getnameinfo from /etc/hosts\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello504:   .. "); print(msg); print("\n");
    /* Only the "files" source: an address the file does not name must not go to the kernel's DNS server (hello548), whose answer
     * depends on the network the test runs in. */
    int nfd = (int)open("/etc/nsswitch.conf", 0x041 | 0x200, 0644);
    long nw = nfd >= 0 ? (long)write(nfd, "hosts: files\n", 13) : -1;
    if (nfd >= 0) close(nfd);
    snprintf(msg, sizeof msg, "setup: nsswitch.conf hosts: files %ld (13)", nw);
    print("hello504:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);
    char h1[64], h2[64], h3[64], h4[64], h5[64];
    int b1 = name_of(4, 0, sizeof h1, h1), b2 = name_of(4, NI_NAMEREQD, sizeof h2, h2);
    snprintf(msg, sizeof msg, "B: 10.5.0.4 %d '%s', NI_NAMEREQD %d '%s' (0 First504.example twice)", b1, h1, b2, h2);
    check(b1 == 0 && strcmp(h1, "First504.example") == 0 && b2 == 0 && strcmp(h2, "First504.example") == 0, msg);
    int c1 = name_of(4, NI_NUMERICHOST, sizeof h3, h3), c2 = name_of(4, 0, 16, h4), c3 = name_of(4, 0, 17, h5);
    snprintf(msg, sizeof msg, "C: NI_NUMERICHOST %d '%s', len 16 %d, len 17 %d '%s' (0 10.5.0.4 -12 0 First504.example)", c1, h3,
             c2, c3, h5);
    check(c1 == 0 && strcmp(h3, "10.5.0.4") == 0 && c2 == EAI_OVERFLOW && c3 == 0 && strcmp(h5, "First504.example") == 0, msg);
    int d1 = name_of(7, 0, sizeof h1, h1), d2 = name_of(7, NI_NAMEREQD, sizeof h2, h2);
    snprintf(msg, sizeof msg, "D: 10.5.0.7 %d '%s', NI_NAMEREQD %d (0 10.5.0.7 -2)", d1, h1, d2);
    check(d1 == 0 && strcmp(h1, "10.5.0.7") == 0 && d2 == EAI_NONAME, msg);
    int e1 = name_of(0, 0, sizeof h1, h1), e2 = name_of(9, 0, sizeof h2, h2);
    snprintf(msg, sizeof msg, "E: 127.0.0.1 %d '%s', 10.5.0.9 %d '%s' (0 localhost 0 nine504.example)", e1, h1, e2, h2);
    check(e1 == 0 && strcmp(h1, "localhost") == 0 && e2 == 0 && strcmp(h2, "nine504.example") == 0, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
    int f1 = 0;
    strcpy(h1, "10.5.0.4");
#else
    long u = unlink(HOSTS_PATH);
    unlink("/etc/nsswitch.conf");
    int f1 = name_of(4, 0, sizeof h1, h1);
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld, then 10.5.0.4 %d '%s' (0 0 10.5.0.4)", u, f1, h1);
    check(u == 0 && f1 == 0 && strcmp(h1, "10.5.0.4") == 0, msg);
    print(failures ? "hello504: FAIL\n" : "hello504: PASS\n");
    return failures ? 1 : 0;
}
