/* hello548: reverse DNS with no nameserver line in /etc/resolv.conf asks the kernel's own server (DHCP's), as names do through
 * dns_resolve (glibc 2.44 asks its default 127.0.0.1 then, measured). A: dns_ptr (508) with a NULL server is not refused with
 * EFAULT or EINVAL: it answers with a DNS result (0 and a name, or -ENOENT, -ENODATA, -EAGAIN, -ECONNREFUSED, -EPROTO,
 * -ETIMEDOUT); B: an out-of-range server pointer is still EFAULT; C: getnameinfo of 10.0.2.2 with a resolv.conf that has no
 * nameserver and "hosts: dns" gives a name or the numeric form, never EAI_SYSTEM; D: cleanup. The answer itself depends on the
 * network QEMU forwards to, so only the kind of result is checked. Needs root (/etc). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/netdb.h"
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello548:   ok   " : "hello548:   FAIL ");
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
static int dns_result(long r) { return r == 0 || r == -2 || r == -61 || r == -11 || r == -111 || r == -71 || r == -110; }
int main(void) {
    print("hello548: reverse DNS without a resolv.conf nameserver\n");
    mkdir("/etc", 0755);
    unsigned char a4[4] = {10, 0, 2, 2};
    char name[256];
    long r = syscall6(SYS_dns_ptr, (long)a4, 2, 0, 2000, (long)name, (long)sizeof name);
    snprintf(msg, sizeof msg, "A: dns_ptr(10.0.2.2, NULL server) = %ld%s%s (a DNS result, not -14 or -22)", r, r == 0 ? " " : "", r == 0 ? name : "");
    check(dns_result(r) && (r != 0 || name[0] != 0), msg);

    r = syscall6(SYS_dns_ptr, (long)a4, 2, 0x0000800000000000L, 2000, (long)name, (long)sizeof name);
    snprintf(msg, sizeof msg, "B: dns_ptr with a kernel-half server pointer = %ld (-14)", r);
    check(r == -14, msg);

    int wc = write_file("/etc/resolv.conf", "options timeout:2 attempts:1\n");
    int wn = write_file("/etc/nsswitch.conf", "hosts: dns\n");
    unsigned char sa[16] = {2, 0, 0, 80, 10, 0, 2, 2};
    char host[128];
    int e = getnameinfo(sa, 16, host, sizeof host, 0, 0, 0);
    snprintf(msg, sizeof msg, "C: getnameinfo(10.0.2.2) with no nameserver (conf %d nss %d) = %d %s (0 and a name or 10.0.2.2, or %d)", wc, wn, e,
             e ? "-" : host, EAI_AGAIN);
    check(wc == 0 && wn == 0 && (e == 0 ? host[0] != 0 : e == EAI_AGAIN), msg);

    long u = unlink("/etc/resolv.conf"), u2 = unlink("/etc/nsswitch.conf");
    snprintf(msg, sizeof msg, "D: unlink %ld %ld (0 0)", u, u2);
    check(u == 0 && u2 == 0, msg);
    print(failures ? "hello548: FAIL\n" : "hello548: PASS\n");
    return failures ? 1 : 0;
}
