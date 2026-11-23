/* hello512: /proc/net/if_inet6 and AI_ADDRCONFIG (Linux and glibc semantics, measured). A /proc/net/if_inet6 is in /proc/net and
 * lists ::1 on lo as "00000000000000000000000000000001 01 80 10 80       lo"; B when eth0 is up (SIOCGIFHWADDR answers) it also has
 * the EUI-64 link-local address built from the MAC, on the index SIOCGIFINDEX gives, prefix 0x40, scope 0x20, permanent; C the
 * file is read-only (EACCES for writing); D with a non-loopback address of both families, AI_ADDRCONFIG changes nothing: AF_UNSPEC
 * of a name in /etc/hosts gives both families, AF_INET and AF_INET6 their own, and the literals behave as without the flag;
 * E cleanup. Run with -DHOST in `unshare -n` with a dummy interface that has an IPv4 address (its link-local makes IPv6
 * configured as well). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H512") ? getenv("H512") : "/etc/hosts")
#define DEV (getenv("D512") ? getenv("D512") : "eth0")
static long rd(const char *path, char *buf, long cap, int flags) {
    int fd = open(path, flags);
    if (fd < 0) return -errno;
    long n = read(fd, buf, (size_t)cap);
    close(fd);
    return n < 0 ? -errno : n;
}
static long ifioctl(unsigned long cmd, const char *name, unsigned char out[40]) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    memset(out, 0, 40);
    strncpy((char *)out, name, 15);
    long rc = ioctl(s, cmd, out) < 0 ? -errno : 0;
    close(s);
    return rc;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
#define DEV "eth0"
static long rd(const char *path, char *buf, long cap, int flags) {
    long fd = syscall3(SYS_open, (long)path, flags, 0);
    if (fd < 0) return fd;
    long n = syscall3(SYS_read, fd, (long)buf, cap);
    syscall1(SYS_close, fd);
    return n;
}
static long ifioctl(unsigned long cmd, const char *name, unsigned char out[40]) {
    long s = syscall3(SYS_socket, 2, 2, 0);
    memset(out, 0, 40);
    strncpy((char *)out, name, 15);
    long rc = syscall3(SYS_ioctl, s, (long)cmd, (long)out);
    syscall1(SYS_close, s);
    return rc;
}
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello512:   ok   " : "hello512:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] = "10.5.2.1 dual512\n2001:db8::121 dual512\n";
/* "fam,fam,..." of a lookup (one SOCK_STREAM entry per address), or "E<code>". */
static void lookup(const char *node, int family, int flags, char *out, size_t cap) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = family;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = flags;
    int rc = getaddrinfo(node, "80", &hints, &res);
    if (rc) { snprintf(out, cap, "E%d", rc); return; }
    size_t n = 0;
    out[0] = 0;
    for (struct addrinfo *p = res; p && n < cap; p = p->ai_next) n += (size_t)snprintf(out + n, cap - n, "%s%d", n ? "," : "", p->ai_family);
    freeaddrinfo(res);
}
int main(void) {
    print("hello512: /proc/net/if_inet6 and AI_ADDRCONFIG\n");
    static char text[1024];
    long n = rd("/proc/net/if_inet6", text, sizeof text - 1, 0);
    if (n < 0) n = 0;
    text[n] = 0;
    const char *lo_line = "00000000000000000000000000000001 01 80 10 80       lo\n";
    print("hello512:   .. /proc/net/if_inet6:\n");
    print(text);
    snprintf(msg, sizeof msg, "A: read %ld bytes, lo line %s", n, strstr(text, lo_line) ? "present" : "missing");
    check(n > 0 && strstr(text, lo_line) != 0, msg);

    unsigned char hw[40], ix[40];
    long h = ifioctl(0x8927 /* SIOCGIFHWADDR */, DEV, hw), x = ifioctl(0x8933 /* SIOCGIFINDEX */, DEV, ix);
    char want[80] = "";
    if (h == 0 && x == 0) {
        const unsigned char *m = hw + 18;
        unsigned idx = (unsigned)ix[16] | (unsigned)ix[17] << 8;
        snprintf(want, sizeof want, "fe80000000000000%02x%02x%02xfffe%02x%02x%02x %02x 40 20 80 %8s\n", m[0] ^ 2, m[1], m[2], m[3], m[4], m[5], idx,
                 DEV);
    }
    snprintf(msg, sizeof msg, "B: %s up %d, link-local line %s", DEV, h == 0 && x == 0, want[0] && strstr(text, want) ? "present" : want);
    check(h == 0 && x == 0 && strstr(text, want) != 0, msg);

    long w = rd("/proc/net/if_inet6", text, 1, 1 /* O_WRONLY */);
    snprintf(msg, sizeof msg, "C: open for writing %ld (-13)", w);
    check(w == -EACCES, msg);

#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello512:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long wr = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    char d1[64], d2[64], d3[64], d4[64], d5[64], d6[64];
    lookup("dual512", AF_UNSPEC, AI_ADDRCONFIG, d1, sizeof d1);
    lookup("dual512", AF_INET, AI_ADDRCONFIG, d2, sizeof d2);
    lookup("dual512", AF_INET6, AI_ADDRCONFIG, d3, sizeof d3);
    lookup("127.0.0.1", AF_INET6, AI_ADDRCONFIG, d4, sizeof d4);
    lookup("::1", AF_UNSPEC, AI_ADDRCONFIG, d5, sizeof d5);
    lookup((const char *)0, AF_UNSPEC, AI_ADDRCONFIG, d6, sizeof d6);
    snprintf(msg, sizeof msg, "D: hosts %d/%ld; UNSPEC %s, INET %s, INET6 %s, 127.0.0.1 under INET6 %s, ::1 %s, NULL %s (10,2 2 10 E-9 10 10,2)", fd,
             wr, d1, d2, d3, d4, d5, d6);
    check(fd >= 0 && strcmp(d1, "10,2") == 0 && strcmp(d2, "2") == 0 && strcmp(d3, "10") == 0 && strcmp(d4, "E-9") == 0 &&
              strcmp(d5, "10") == 0 && strcmp(d6, "10,2") == 0, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "E: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello512: FAIL\n" : "hello512: PASS\n");
    return failures ? 1 : 0;
}
