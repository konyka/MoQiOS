/* hello545: getnameinfo NI_NOFQDN (glibc 2.44 nrl_domainname, measured with "hosts: files"). The local domain is what follows the
 * first dot of the first dotted name among localhost's name, the host name, the host name's name and 127.0.0.1's name; it is
 * found once per process and kept. A name is cut before ".domain" only when the domain's first occurrence follows a dot. Each
 * case runs in a new process (the domain is per process). A: localhost.lan.test names the domain: web.lan.test is "web",
 * web.other.test and lan.test are kept, a.b.lan.test is "a.b", a 4-byte buffer takes "web" but not web.other.test; B: the domain
 * is kept after /etc/hosts changes; C: the host name's line (moqios.hd.test) names it; D: 127.0.0.1's line names it; E: no
 * domain anywhere keeps the whole name; F: cleanup. Needs root (/etc). Measured with -DHOST through glibc in
 * `unshare -r -u -m -n` with the host name set to moqios and hosts and nsswitch.conf bind-mounted. */
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
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define SA(p) ((const struct sockaddr *)(p))
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/netdb.h"
#define SA(p) ((const uint8_t *)(p))
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello545:   ok   " : "hello545:   FAIL ");
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
/* getnameinfo of 10.1.1.<d> with `flags` into a `len`-byte buffer, appended to `out` as "<code>:<name>;". */
static void ask(unsigned d, unsigned len, int flags, char *out, size_t cap) {
    unsigned char sa[16];
    memset(sa, 0, sizeof sa);
    sa[0] = AF_INET;
    sa[4] = 10; sa[5] = 1; sa[6] = 1; sa[7] = (unsigned char)d;
    char host[128];
    int r = getnameinfo(SA(sa), 16, host, len, 0, 0, flags);
    size_t n = strlen(out);
    snprintf(out + n, cap - n, "%d:%s;", r, r ? "-" : host);
}
/* Run one case in a child: write /etc/hosts, ask the addresses with NI_NOFQDN (after the first answer /etc/hosts becomes `later`
 * when given), and check the answers. */
static void run_case(const char *tag, const char *hosts, const char *later, const unsigned *ds, unsigned nd, const char *want) {
    int wh = write_file("/etc/hosts", hosts);
    long pid = (long)fork();
    if (pid == 0) {
        char got[300] = "";
        for (unsigned i = 0; i < nd; i++) {
            if (i == 1 && later) write_file("/etc/hosts", later);
            unsigned len = ds[i] >= 100 ? 4 : 128;
            ask(ds[i] % 100, len, NI_NOFQDN, got, sizeof got);
        }
        snprintf(msg, sizeof msg, "%s (hosts %d): '%s' ('%s')", tag, wh, got, want);
        check(wh == 0 && strcmp(got, want) == 0, msg);
        _exit(failures ? 1 : 0);
    }
    int st = -1;
    if (pid < 0 || waitpid(pid, &st, 0) != pid || st != 0) failures++;
}
int main(void) {
    print("hello545: getnameinfo NI_NOFQDN\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int wn = write_file("/etc/nsswitch.conf", "hosts: files\n");
    char ow[64];
    snprintf(ow, sizeof ow, "%d:-;", EAI_OVERFLOW);
    char want[300];
    static const unsigned a[] = {1, 2, 4, 5, 101, 102};
    snprintf(want, sizeof want, "0:web;0:web.other.test;0:lan.test;0:a.b;0:web;%s", ow);
    char tag[80];
    snprintf(tag, sizeof tag, "A: localhost.lan.test (nsswitch %d)", wn);
    run_case(tag, "127.0.0.1 localhost.lan.test localhost\n10.1.1.1 web.lan.test\n10.1.1.2 web.other.test\n10.1.1.4 lan.test\n"
             "10.1.1.5 a.b.lan.test\n", 0, a, 6, want);
    if (wn != 0) failures++;
    static const unsigned b[] = {1, 2};
    run_case("B: kept after /etc/hosts changes", "127.0.0.1 localhost.one.test\n10.1.1.1 web.one.test\n10.1.1.2 web.two.test\n",
             "127.0.0.1 localhost.two.test\n10.1.1.1 web.one.test\n10.1.1.2 web.two.test\n", b, 2, "0:web;0:web.two.test;");
    static const unsigned c[] = {1};
    run_case("C: the host name's line", "127.0.0.1 localhost\n10.1.1.9 moqios.hd.test moqios\n10.1.1.1 web.hd.test\n", 0, c, 1,
             "0:web;");
    run_case("D: 127.0.0.1's line", "127.0.0.1 lo.rv.test\n10.1.1.1 web.rv.test\n", 0, c, 1, "0:web;");
    run_case("E: no domain", "127.0.0.1 localhost\n10.1.1.1 web.none.test\n", 0, c, 1, "0:web.none.test;");
#ifdef HOST
    long u = 0, u2 = 0; /* the host files are bind-mount targets */
#else
    long u = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf");
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld %ld (0 0)", u, u2);
    check(u == 0 && u2 == 0, msg);
    print(failures ? "hello545: FAIL\n" : "hello545: PASS\n");
    return failures ? 1 : 0;
}
