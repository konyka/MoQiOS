/* hello510: the reentrant resolver functions (glibc semantics, measured). A creates /etc/hosts; B gethostbyname_r of an alias
 * fills the caller's hostent and buffer with the canonical name, aliases and address; C gethostbyname2_r(AF_INET6) lists both
 * IPv6 lines; D gethostbyaddr_r names an IPv4 and an IPv6 address; E a buffer too small is ERANGE with NETDB_INTERNAL and a
 * NULL result, and growing it one byte at a time succeeds; F a miss is 0 with a NULL result and HOST_NOT_FOUND, another family is
 * EAFNOSUPPORT; G none of this touched the static gethostbyname result or h_errno; H two threads resolve different names 200 times
 * each with no cross-talk; I cleanup. Measured with -DHOST in a mount namespace with /etc/hosts bind-mounted to a scratch file. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H510") ? getenv("H510") : "/etc/hosts")
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/pthread.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
#endif
static int failures;
static char msg[420];
static void check(int ok, const char *w) {
    print(ok ? "hello510:   ok   " : "hello510:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] =
    "127.0.0.1 localhost\n10.5.1.1 One510.example a510 b510\n10.5.1.2 Two510.example\n"
    "2001:db8::51 Six510 s510\n2001:db8::52 Six510\n";
/* "name|alias..|type/len:last-byte,.." of a result. */
static void describe(const struct hostent *h, char *out, size_t cap) {
    size_t n = (size_t)snprintf(out, cap, "%s", h->h_name);
    for (char **a = h->h_aliases; *a && n < cap; a++) n += (size_t)snprintf(out + n, cap - n, "|%s", *a);
    if (n < cap) n += (size_t)snprintf(out + n, cap - n, "|%d/%d:", h->h_addrtype, h->h_length);
    for (char **a = h->h_addr_list; *a && n < cap; a++)
        n += (size_t)snprintf(out + n, cap - n, "%u,", (unsigned)(unsigned char)(*a)[h->h_length - 1]);
}
static int inside(const void *p, const char *buf, size_t len) { return (const char *)p >= buf && (const char *)p < buf + len; }

struct worker { const char *name; unsigned char last; int bad; };
static void *resolve_loop(void *arg) {
    struct worker *w = (struct worker *)arg;
    for (int i = 0; i < 200; i++) {
        struct hostent he, *res = (struct hostent *)0;
        char buf[256];
        int herr = -5;
        int rc = gethostbyname_r(w->name, &he, buf, sizeof buf, &res, &herr);
        /* *h_errnop is only meaningful on a failure (glibc leaves HOST_NOT_FOUND there after an /etc/hosts hit, measured). */
        if (rc != 0 || res != &he || (unsigned char)he.h_addr_list[0][3] != w->last) w->bad++;
    }
    return (void *)0;
}

int main(void) {
    print("hello510: gethostbyname_r, gethostbyname2_r, gethostbyaddr_r\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello510:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);

    /* The static result, to check later that the reentrant calls leave it alone. */
    struct hostent *stat = gethostbyname("Two510.example");
    char before[120] = "NULL";
    if (stat) describe(stat, before, sizeof before);
    h_errno = 77;

    struct hostent he, *res;
    char buf[512];
    int herr;
    char b[160], c[160], d1[160], d2[160];
    res = (struct hostent *)0; herr = -5;
    int rb = gethostbyname_r("B510", &he, buf, sizeof buf, &res, &herr);
    strcpy(b, "NULL");
    if (res) describe(res, b, sizeof b);
    int bin = res && inside(he.h_name, buf, sizeof buf) && inside(he.h_aliases, buf, sizeof buf) && inside(he.h_addr_list[0], buf, sizeof buf);
    snprintf(msg, sizeof msg, "B: gethostbyname_r rc %d %s, in buffer %d (0 One510.example|a510|b510|2/4:1, 1)", rb, b, bin);
    check(rb == 0 && res == &he && strcmp(b, "One510.example|a510|b510|2/4:1,") == 0 && bin, msg);

    res = (struct hostent *)0; herr = -5;
    int rc2 = gethostbyname2_r("six510", AF_INET6, &he, buf, sizeof buf, &res, &herr);
    strcpy(c, "NULL");
    if (res) describe(res, c, sizeof c);
    snprintf(msg, sizeof msg, "C: gethostbyname2_r AF_INET6 rc %d %s (0 Six510|s510|10/16:81,82,)", rc2, c);
    check(rc2 == 0 && res == &he && strcmp(c, "Six510|s510|10/16:81,82,") == 0, msg);

    static const unsigned char a4[4] = {10, 5, 1, 2};
    static const unsigned char a6[16] = {0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x51};
    res = (struct hostent *)0; herr = -5;
    int rd1 = gethostbyaddr_r(a4, 4, AF_INET, &he, buf, sizeof buf, &res, &herr);
    strcpy(d1, "NULL");
    if (res) describe(res, d1, sizeof d1);
    res = (struct hostent *)0; herr = -5;
    int rd2 = gethostbyaddr_r(a6, 16, AF_INET6, &he, buf, sizeof buf, &res, &herr);
    strcpy(d2, "NULL");
    if (res) describe(res, d2, sizeof d2);
    snprintf(msg, sizeof msg, "D: gethostbyaddr_r %d %s, %d %s (0 Two510.example|2/4:2, 0 Six510|s510|10/16:81,)", rd1, d1, rd2, d2);
    check(rd1 == 0 && strcmp(d1, "Two510.example|2/4:2,") == 0 && rd2 == 0 && strcmp(d2, "Six510|s510|10/16:81,") == 0, msg);

    res = (struct hostent *)1; herr = -5; errno = 0;
    int re = gethostbyname_r("a510", &he, buf, 16, &res, &herr);
    int re_errno = errno, re_herr = herr, re_null = res == (struct hostent *)0;
    size_t need = 0;
    for (size_t n = 17; n <= sizeof buf; n++) {
        res = (struct hostent *)0;
        if (gethostbyname_r("a510", &he, buf, n, &res, &herr) == 0 && res == &he) { need = n; break; }
    }
    snprintf(msg, sizeof msg, "E: 16-byte buffer rc %d herr %d errno %d NULL %d; first size that fits %zu (34 -1 34 1, 17..512)", re, re_herr,
             re_errno, re_null, need);
    check(re == ERANGE && re_herr == NETDB_INTERNAL && re_errno == ERANGE && re_null && need > 16, msg);

    res = (struct hostent *)1; herr = -5;
    int rf1 = gethostbyname_r("nosuch510.invalid.", &he, buf, sizeof buf, &res, &herr);
    int f1null = res == (struct hostent *)0, f1herr = herr;
    static const unsigned char miss4[4] = {10, 5, 1, 99};
    res = (struct hostent *)1; herr = -5;
    int rf2 = gethostbyaddr_r(miss4, 4, AF_INET, &he, buf, sizeof buf, &res, &herr);
    int f2null = res == (struct hostent *)0, f2herr = herr;
    res = (struct hostent *)1; herr = -5;
    int rf3 = gethostbyname2_r("a510", 1, &he, buf, sizeof buf, &res, &herr);
    snprintf(msg, sizeof msg, "F: name miss %d/%d/%d, addr miss %d/%d/%d, family 1 %d/%d (0/1/1 0/1/1 97/4)", rf1, f1null, f1herr, rf2, f2null,
             f2herr, rf3, herr);
    check(rf1 == 0 && f1null && f1herr == HOST_NOT_FOUND && rf2 == 0 && f2null && f2herr == HOST_NOT_FOUND && rf3 == EAFNOSUPPORT &&
              herr == NO_DATA, msg);

    char after[120] = "NULL";
    if (stat) describe(stat, after, sizeof after);
    snprintf(msg, sizeof msg, "G: static result %s -> %s, h_errno %d (unchanged, 77)", before, after, h_errno);
    check(stat && strcmp(before, after) == 0 && strcmp(before, "Two510.example|2/4:2,") == 0 && h_errno == 77, msg);

    struct worker w1 = {"one510.example", 1, 0}, w2 = {"two510.example", 2, 0};
    pthread_t t1, t2;
    int c1 = pthread_create(&t1, 0, resolve_loop, &w1), c2 = pthread_create(&t2, 0, resolve_loop, &w2);
    if (c1 == 0) pthread_join(t1, 0);
    if (c2 == 0) pthread_join(t2, 0);
    snprintf(msg, sizeof msg, "H: two threads, create %d %d, wrong answers %d %d (0 0 0 0)", c1, c2, w1.bad, w2.bad);
    check(c1 == 0 && c2 == 0 && w1.bad == 0 && w2.bad == 0, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "I: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello510: FAIL\n" : "hello510: PASS\n");
    return failures ? 1 : 0;
}
