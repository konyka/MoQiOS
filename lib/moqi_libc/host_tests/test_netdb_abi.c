#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include "../include/moqi_syscalls.h"
#include "../include/netdb.h"

/* Stub syscall layer: the host build links netdb.c against these so the wrapper can be driven without a kernel.
 * They record the call and answer from a script. */
long moqi_test_last_nr;
long moqi_test_last_a1;
long moqi_test_last_a2;
long moqi_test_reply;
unsigned char moqi_test_fill[4];

long moqi_test_syscall2(long nr, long a1, long a2) {
    moqi_test_last_nr = nr;
    moqi_test_last_a1 = a1;
    moqi_test_last_a2 = a2;
    if (moqi_test_reply == 0) {
        unsigned char *out = (unsigned char *)a2;
        for (int i = 0; i < 4; i++) out[i] = moqi_test_fill[i];
    }
    return moqi_test_reply;
}

/* /etc/resolv.conf for netdb.c (NULL: no file), and dns_query (507) replies from a script: each call takes the next entry,
 * logging the name, server's last octet and limit. A reply of 0 writes 10.0.0.<call number>. */
const char *moqi_test_resolv_conf;
/* /etc/nsswitch.conf and /etc/hosts for netdb.c (NULL: no file). */
const char *moqi_test_nsswitch_conf;
const char *moqi_test_etc_hosts;
unsigned moqi_test_rotate_seed = 1;
static long q_reply[32];
static int q_n, q_calls;
static char q_log[2048];
/* When set, the next successful dns_query also writes this encoded answer (count bytes, addresses, names) to its buffer. */
static const unsigned char *q_answer;
static size_t q_answer_len;
static long q_last_anslen;
/* dns_ptr (508): the next scripted reply, the family and the asked address's last byte logged as "ptr<fam>:<byte>@<server>;";
 * a reply of 0 writes q_ptr_name. */
static const char *q_ptr_name = "ptr.test";
long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    q_last_anslen = a6;
    if (nr == SYS_dns_ptr) {
        long r = q_calls < q_n ? q_reply[q_calls] : -38;
        q_calls++;
        size_t l = strlen(q_log);
        const unsigned char *ad = (const unsigned char *)a1;
        unsigned last = a2 == 2 ? ad[3] : ad[15];
        int six = (a4 & 0x80000000L) != 0;
        char sc[16] = "";
        if (a4 & 0x40000000L) {
            uint32_t v;
            memcpy(&v, (const unsigned char *)a3 + 16, 4);
            snprintf(sc, sizeof sc, "%%%u", v);
        }
        int w = snprintf(q_log + l, sizeof q_log - l, "ptr%ld:%u@%s%u%s%s%s;", a2, last, six ? "v" : "", six ? ((const unsigned char *)a3)[15] : ((const unsigned char *)a3)[3], sc,
                         (a4 & 0x20000000L) ? "/tcp" : "", (a4 & 0x10000000L) ? "/e" : "");
        (void)w;
        (void)a4;
        if (r == 0) {
            if (a6 < 256) return -34;
            strcpy((char *)a5, q_ptr_name);
        }
        return r;
    }
    if (nr == SYS_dns_query2) {
        /* dns_query2 (510): the next two scripted replies (A, then AAAA), logged as "name/2@server/limit;"; an answering half
         * gets 10.0.0.<call number> or 2001:db8::<call number> under the asked name. */
        long ra = q_calls < q_n ? q_reply[q_calls] : -38;
        long rb = q_calls + 1 < q_n ? q_reply[q_calls + 1] : -38;
        q_calls += 2;
        size_t l2 = strlen(q_log);
        const unsigned char *sv = (const unsigned char *)a2;
        int six2 = (a3 & 0x80000000L) != 0;
        snprintf(q_log + l2, sizeof q_log - l2, "%s/2@%s%u/%ld%s%s;", (const char *)a1, six2 ? "v" : "", (six2 ? sv[15] : sv[3]) % 10,
                 (a3 & 0x0fffffffL) / 1000, (a3 & 0x20000000L) ? "/tcp" : "", (a3 & 0x10000000L) ? "/e" : "");
        long rr[2] = {ra, rb};
        unsigned char *dst[2] = {(unsigned char *)a4, (unsigned char *)a5};
        for (int k = 0; k < 2; k++) {
            if (rr[k] != 0) continue;
            size_t al = k ? 16 : 4;
            unsigned char *ans = dst[k];
            ans[0] = 1; ans[1] = 0; ans[2] = (unsigned char)al;
            memset(ans + 3, 0, al);
            if (al == 4) { ans[3] = 10; ans[6] = (unsigned char)(q_calls - 1 + k); }
            else { ans[3] = 0x20; ans[4] = 0x01; ans[5] = 0x0d; ans[6] = 0xb8; ans[18] = (unsigned char)(q_calls - 1 + k); }
            strcpy((char *)ans + 3 + al, (const char *)a1);
        }
        (void)a6;
        return (-ra & 0xff) | (-rb & 0xff) << 8;
    }
    long r = (nr == SYS_dns_query || nr == SYS_dns_query6) && q_calls < q_n ? q_reply[q_calls] : -38;
    q_calls++;
    size_t l = strlen(q_log);
    const char *name = (const char *)a1;
    const unsigned char *srv = (const unsigned char *)a3;
    size_t k = strlen(name);
    if (l + k + 24 < sizeof q_log) {
        memcpy(q_log + l, name, k);
        l += k;
        if (nr == SYS_dns_query6) { q_log[l++] = '/'; q_log[l++] = '6'; }
        q_log[l++] = '@';
        /* An IPv6 server (bit 31 of the timeout) is logged as "v" and its last byte. */
        int six = (a4 & 0x80000000L) != 0;
        if (six) q_log[l++] = 'v';
        q_log[l++] = (char)('0' + (six ? srv[15] : srv[3]) % 10);
        if (a4 & 0x40000000L) {
            /* A scoped IPv6 server: the scope id follows the 16 bytes. */
            uint32_t v;
            memcpy(&v, srv + 16, 4);
            l += (size_t)snprintf(q_log + l, sizeof q_log - l, "%%%u", v);
        }
        q_log[l++] = '/';
        long ms = (a4 & 0x0fffffffL) / 1000;
        if (ms >= 10) q_log[l++] = (char)('0' + ms / 10 % 10);
        q_log[l++] = (char)('0' + ms % 10);
        if (a4 & 0x20000000L) { memcpy(q_log + l, "/tcp", 4); l += 4; }
        if (a4 & 0x10000000L) { memcpy(q_log + l, "/e", 2); l += 2; }
        q_log[l++] = ';';
        q_log[l] = 0;
    }
    if (r == 0) {
        unsigned char *out = (unsigned char *)a2;
        out[0] = 10; out[1] = 0; out[2] = 0; out[3] = (unsigned char)q_calls;
        if (a6 >= 256 && a5) {
            unsigned char *ans = (unsigned char *)a5;
            if (q_answer && q_answer_len <= (size_t)a6) {
                memcpy(ans, q_answer, q_answer_len);
                memcpy(out, q_answer + 3, q_answer[2]);
            } else {
                /* The kernel's form for one address under the asked name: counts, the address length, the address, the name. An
                 * AAAA query gets 2001:db8::<call number>. */
                size_t al = nr == SYS_dns_query6 ? 16 : 4;
                if (al == 16) {
                    memset(out, 0, 16);
                    out[0] = 0x20; out[1] = 0x01; out[2] = 0x0d; out[3] = 0xb8; out[15] = (unsigned char)q_calls;
                }
                ans[0] = 1; ans[1] = 0; ans[2] = (unsigned char)al;
                memcpy(ans + 3, out, al);
                strcpy((char *)ans + 3 + al, name);
            }
        }
    }
    return r;
}
static void q_script(const char *conf, const long *replies, int n) {
    moqi_test_resolv_conf = conf;
    for (int i = 0; i < n; i++) q_reply[i] = replies[i];
    q_n = n;
    q_calls = 0;
    q_log[0] = 0;
    q_answer = 0;
    q_answer_len = 0;
}

/* getaddrinfo allocates through malloc/free; the host test links only netdb.o, so it supplies a counting bump
 * allocator. (It cannot forward to the host malloc: with -fno-builtin that would call back into this function.) */
#include <stdlib.h>
static unsigned char arena[1 << 16];
static size_t arena_used, arena_last;
static int live_allocs;
void *malloc(size_t n) {
    n = (n + 15) & ~(size_t)15;
    if (arena_used + n > sizeof(arena)) return (void *)0;
    void *p = arena + arena_used;
    arena_last = arena_used;
    arena_used += n;
    live_allocs++;
    return p;
}
/* The most recent block is given back, so a temporary buffer (getaddrinfo's AF_UNSPEC pair, hello530) does not use up the arena. */
void free(void *p) {
    if (!p) return;
    live_allocs--;
    if (p == arena + arena_last) arena_used = arena_last;
}

/* Scripted socket layer for tcp_connect_host(): records every call number in order and answers per call number. */
#define STUB_LOG_MAX 64
long stub_log[STUB_LOG_MAX];
int stub_log_n;
long stub_socket_reply = 7;      /* the fd socket() returns (or a -errno) */
long stub_connect_replies[8];    /* successive connect() results; the last one repeats */
int stub_connect_n, stub_connect_calls;
long stub_last_connect_addr[2];

/* The kernel's netdevice ioctls (kernel/fs/ioctl.zig netdeviceIoctl) over two interfaces, lo = 1 and eth0 = 2: SIOCGIFINDEX
 * looks the NUL-terminated name up, SIOCGIFNAME the index at byte 16; an unknown one is -ENODEV. */
static const char *const stub_ifnames[] = {"lo", "eth0"};
int stub_ifs = 2;
unsigned char stub_eth0_ip[4];
static long stub_ioctl(long cmd, unsigned char *req) {
    if (cmd == 0x8933) {
        for (int i = 0; i < stub_ifs; i++) {
            if (memchr(req, 0, 16) && strcmp((const char *)req, stub_ifnames[i]) == 0) {
                unsigned idx = (unsigned)i + 1;
                memset(req + 16, 0, 24);
                req[16] = (unsigned char)idx;
                return 0;
            }
        }
        return -19;
    }
    if (cmd == 0x8912) {
        /* SIOCGIFCONF: struct ifconf { int len; char *buf; }; one 40-byte record per interface that fits. lo is 127.0.0.1;
         * eth0 is listed with address 0.0.0.0 unless stub_eth0_ip is set, so by default no IPv4 address is "configured". */
        int len;
        unsigned char *buf;
        memcpy(&len, req, 4);
        memcpy(&buf, req + 8, 8);
        int wrote = 0;
        if (!buf) {
            wrote = 40 * stub_ifs;
        } else {
            for (int i = 0; i < stub_ifs && wrote + 40 <= len; i++) {
                unsigned char *r = buf + wrote;
                memset(r, 0, 40);
                strcpy((char *)r, stub_ifnames[i]);
                r[16] = 2;
                if (i == 0) { r[20] = 127; r[23] = 1; } else memcpy(r + 20, stub_eth0_ip, 4);
                wrote += 40;
            }
        }
        memcpy(req, &wrote, 4);
        return 0;
    }
    if (cmd == 0x8910) {
        unsigned idx = (unsigned)req[16] | (unsigned)req[17] << 8 | (unsigned)req[18] << 16 | (unsigned)req[19] << 24;
        if (idx < 1 || idx > (unsigned)stub_ifs) return -19;
        memset(req, 0, 16);
        strcpy((char *)req, stub_ifnames[idx - 1]);
        return 0;
    }
    return -25;
}

long moqi_test_syscall3(long nr, long a1, long a2, long a3) {
    if (stub_log_n < STUB_LOG_MAX) stub_log[stub_log_n++] = nr;
    if (nr == SYS_ioctl) return stub_ioctl(a2, (unsigned char *)a3);
    if (nr == SYS_socket) return stub_socket_reply;
    if (nr == SYS_connect) {
        stub_last_connect_addr[0] = a1;
        stub_last_connect_addr[1] = a2;
        int k = stub_connect_calls < stub_connect_n ? stub_connect_calls : stub_connect_n - 1;
        stub_connect_calls++;
        return stub_connect_replies[k];
    }
    return 0;
}

static int stub_count(long nr) {
    int n = 0;
    for (int i = 0; i < stub_log_n; i++) if (stub_log[i] == nr) n++;
    return n;
}
static void stub_reset(void) {
    stub_log_n = 0; stub_connect_calls = 0; stub_connect_n = 1; stub_connect_replies[0] = 0; stub_socket_reply = 7;
}

int main(void) {
    /* The number is the kernel's. */
    assert(SYS_dns_resolve == 495);

    /* The wrapper passes the name and the output pointer straight through. */
    uint8_t ip[4] = {0xAA, 0xAA, 0xAA, 0xAA};
    moqi_test_reply = 0;
    moqi_test_fill[0] = 10; moqi_test_fill[1] = 0; moqi_test_fill[2] = 2; moqi_test_fill[3] = 2;
    long r = gethostbyname_ipv4("gateway", ip);
    assert(r == 0);
    assert(moqi_test_last_nr == 495);
    assert(moqi_test_last_a2 == (long)ip);
    assert(ip[0] == 10 && ip[1] == 0 && ip[2] == 2 && ip[3] == 2);

    /* A failure is the kernel's -errno, unchanged, and the output is left as it was. */
    for (int i = 0; i < 4; i++) ip[i] = 0xAA;
    moqi_test_reply = -2;
    assert(gethostbyname_ipv4("nope.invalid", ip) == -2);
    assert(ip[0] == 0xAA && ip[3] == 0xAA);

    /* /etc/hosts lines (glibc files backend, measured): the first line naming the host wins, any of its names counts, case does
     * not matter, '#' starts a comment, fields are separated by spaces or tabs; a trailing dot does not match; a line whose
     * address is not dotted IPv4 is skipped here. */
    {
        static const char hosts[] =
            "127.0.0.1 localhost\n# a comment line\n  10.1.2.3\tfoo.example\tfoo  # trailing comment\n"
            "::1 v6only\n10.9.9.9 Foo other\nbogus line\n192.168.0.7 last";
        uint8_t h[4] = {0, 0, 0, 0};
        assert(hosts_find(hosts, sizeof(hosts) - 1, "foo", h) == 1 && h[0] == 10 && h[1] == 1 && h[2] == 2 && h[3] == 3);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "FOO.example", h) == 1 && h[3] == 3);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "other", h) == 1 && h[0] == 10 && h[3] == 9);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "last", h) == 1 && h[0] == 192 && h[3] == 7);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "localhost", h) == 1 && h[0] == 127);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "foo.example.", h) == 0);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "v6only", h) == 0);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "comment", h) == 0);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "fo", h) == 0);
        assert(hosts_find(hosts, sizeof(hosts) - 1, "bar", h) == 0);
        assert(hosts_find(hosts, 0, "foo", h) == 0);
    }

    /* The matched line's names, for h_name/h_aliases and AI_CANONNAME (glibc returns the canonical name and the aliases). */
    {
        static const char hosts[] = "10.1.2.3\tCanon.example  alias \t# note\n10.1.2.3 later\n10.1.2.4 solo";
        uint8_t h[4] = {0, 0, 0, 0};
        const char *names = 0;
        size_t k = hosts_find_names(hosts, sizeof(hosts) - 1, "ALIAS", h, &names);
        assert(k == 20 && memcmp(names, "Canon.example  alias", 20) == 0 && h[3] == 3);
        k = hosts_find_names(hosts, sizeof(hosts) - 1, "later", h, &names);
        assert(k == 5 && memcmp(names, "later", 5) == 0);
        k = hosts_find_names(hosts, sizeof(hosts) - 1, "solo", h, &names);
        assert(k == 4 && memcmp(names, "solo", 4) == 0 && h[3] == 4);
        names = 0;
        assert(hosts_find_names(hosts, sizeof(hosts) - 1, "none", h, &names) == 0 && names == 0);
    }

    /* Every address of a name, for getaddrinfo: IPv6 lines first, then IPv4 lines, each in file order (glibc, measured). */
    {
        static const char hosts[] = "2001:db8::6 dup\n10.5.0.6 Dup other\n2001:db8::7 x dup\n10.5.0.7 dup\nbad::addr::x dup\n10.5.0.8 nodup\n";
        struct hosts_addr got[8];
        const char *names = 0;
        size_t nl = 0;
        size_t k = hosts_collect(hosts, sizeof(hosts) - 1, "DUP", AF_UNSPEC, got, 8, &names, &nl);
        assert(k == 4 && got[0].family == AF_INET6 && got[0].addr[15] == 6 && got[1].family == AF_INET6 && got[1].addr[15] == 7);
        assert(got[2].family == AF_INET && got[2].addr[3] == 6 && got[3].family == AF_INET && got[3].addr[3] == 7);
        assert(nl == 3 && memcmp(names, "dup", 3) == 0); /* the first matching line in the file */
        assert(hosts_collect(hosts, sizeof(hosts) - 1, "dup", AF_INET6, got, 8, &names, &nl) == 2 && got[1].addr[15] == 7);
        assert(hosts_collect(hosts, sizeof(hosts) - 1, "dup", AF_INET, got, 8, (const char **)0, (size_t *)0) == 2 && got[0].addr[3] == 6);
        assert(hosts_collect(hosts, sizeof(hosts) - 1, "other", AF_INET6, got, 8, &names, &nl) == 0);
        k = hosts_collect(hosts, sizeof(hosts) - 1, "other", AF_UNSPEC, got, 8, &names, &nl);
        assert(k == 1 && got[0].family == AF_INET && nl == 9 && memcmp(names, "Dup other", 9) == 0);
        assert(hosts_collect(hosts, sizeof(hosts) - 1, "dup", AF_UNSPEC, got, 3, &names, &nl) == 3);
        assert(hosts_collect(hosts, sizeof(hosts) - 1, "missing", AF_UNSPEC, got, 8, &names, &nl) == 0);
    }

    /* Reverse: the first matching line's first name (glibc getnameinfo with /etc/hosts, measured). */
    {
        static const char hosts[] =
            "127.0.0.1 localhost\n# 10.5.0.4 commented\n10.5.0.4\n 10.5.0.4\tFirst.example  alias\n10.5.0.4 second\n"
            "10.05.0.9 bad\n10.5.0.9 nine # note\n10.5.0.10 last";
        const char *n = 0;
        size_t k = hosts_reverse(hosts, sizeof(hosts) - 1, (const uint8_t[]){10, 5, 0, 4}, &n);
        assert(k == 13 && memcmp(n, "First.example", 13) == 0);
        k = hosts_reverse(hosts, sizeof(hosts) - 1, (const uint8_t[]){10, 5, 0, 9}, &n);
        assert(k == 4 && memcmp(n, "nine", 4) == 0);
        k = hosts_reverse(hosts, sizeof(hosts) - 1, (const uint8_t[]){10, 5, 0, 10}, &n);
        assert(k == 4 && memcmp(n, "last", 4) == 0);
        k = hosts_reverse(hosts, sizeof(hosts) - 1, (const uint8_t[]){127, 0, 0, 1}, &n);
        assert(k == 9 && memcmp(n, "localhost", 9) == 0);
        n = 0;
        assert(hosts_reverse(hosts, sizeof(hosts) - 1, (const uint8_t[]){10, 5, 0, 7}, &n) == 0 && n == 0);
        assert(hosts_reverse(hosts, 0, (const uint8_t[]){10, 5, 0, 4}, &n) == 0);
    }

    /* Reverse for IPv6: an IPv6 line with the same 16 bytes, written in any form (glibc, measured). */
    {
        static const char hosts[] = "::1 localhost6 ip6-localhost\n2001:DB8:0::6 Six.example s6\n10.5.0.6 four\n2001:db8::6 later\n";
        static const uint8_t six[16] = {32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6};
        static const uint8_t lo[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
        static const uint8_t nine[16] = {32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9};
        const char *n = 0;
        assert(hosts_reverse6(hosts, sizeof(hosts) - 1, six, &n) == 11 && memcmp(n, "Six.example", 11) == 0);
        assert(hosts_reverse6(hosts, sizeof(hosts) - 1, lo, &n) == 10 && memcmp(n, "localhost6", 10) == 0);
        n = 0;
        assert(hosts_reverse6(hosts, sizeof(hosts) - 1, nine, &n) == 0 && n == 0);
        /* An IPv4 line never answers an IPv6 address: ::ffff:a.b.c.d is looked up as a.b.c.d by getnameinfo itself. */
        static const uint8_t mapped[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 10, 5, 0, 6};
        assert(hosts_reverse6(hosts, sizeof(hosts) - 1, mapped, &n) == 0);
    }

    /* gethostbyaddr needs the whole names field, not only the canonical name that getnameinfo returns (glibc, measured). */
    {
        static const char hosts[] = "10.5.0.9 First.example alias other\n10.5.0.9 second\n2001:db8::9 Six.example s6\n";
        static const uint8_t four[4] = {10, 5, 0, 9};
        static const uint8_t six[16] = {32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9};
        const char *n = 0;
        size_t k = hosts_reverse_names(hosts, sizeof(hosts) - 1, AF_INET, four, &n);
        assert(k == 25 && memcmp(n, "First.example alias other", 25) == 0);
        k = hosts_reverse_names(hosts, sizeof(hosts) - 1, AF_INET6, six, &n);
        assert(k == 14 && memcmp(n, "Six.example s6", 14) == 0);
        n = 0;
        assert(hosts_reverse_names(hosts, sizeof(hosts) - 1, AF_INET6, four, &n) == 0 && n == 0);
        assert(hosts_reverse_names(hosts, sizeof(hosts) - 1, 1, four, &n) == 0 && n == 0);
    }

    /* Without /etc/hosts a valid reverse lookup is HOST_NOT_FOUND. Bad families and short lengths are
     * NETDB_INTERNAL/EAFNOSUPPORT; a length greater than the family needs is TRY_AGAIN (glibc, measured). */
    {
        static const uint8_t addr[16] = {10, 5, 0, 9};
        errno = 0; h_errno = 0;
        assert(gethostbyaddr(addr, 3, AF_INET) == 0 && h_errno == NETDB_INTERNAL && errno == EAFNOSUPPORT);
        errno = 0; h_errno = 0;
        assert(gethostbyaddr(addr, 5, AF_INET) == 0 && h_errno == TRY_AGAIN && errno == 0);
        errno = 0; h_errno = 0;
        assert(gethostbyaddr(addr, 4, AF_INET6) == 0 && h_errno == NETDB_INTERNAL && errno == EAFNOSUPPORT);
        errno = 0; h_errno = 0;
        assert(gethostbyaddr(addr, 17, AF_INET6) == 0 && h_errno == TRY_AGAIN && errno == 0);
        errno = 0; h_errno = 0;
        assert(gethostbyaddr(addr, 4, 1) == 0 && h_errno == NETDB_INTERNAL && errno == EAFNOSUPPORT);
        errno = 0; h_errno = 0;
        assert(gethostbyaddr(addr, 16, AF_UNSPEC) == 0 && h_errno == NETDB_INTERNAL && errno == EAFNOSUPPORT);
        errno = 0; h_errno = 0;
        assert(gethostbyaddr(addr, 4, AF_UNSPEC) == 0 && h_errno == NETDB_INTERNAL && errno == EAFNOSUPPORT);
        assert(gethostbyaddr((const void *)0, 4, AF_INET) == 0 && h_errno == HOST_NOT_FOUND);
    }

    /* The reentrant forms (glibc, measured): everything goes into the caller's buffer and *result; the return value is 0, ERANGE
     * (buffer too small, *h_errnop NETDB_INTERNAL, errno ERANGE) or EAFNOSUPPORT. A miss is 0 with *result NULL; the static
     * gethostbyname storage and the global h_errno are left alone. */
    {
        struct hostent he, *res;
        char buf[512];
        int herr;
        h_errno = 77;
        struct hostent *stat = gethostbyname("5.6.7.8");
        h_errno = 77;
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyname_r("1.2.3.4", &he, buf, sizeof buf, &res, &herr) == 0 && res == &he && herr == 0);
        assert(strcmp(he.h_name, "1.2.3.4") == 0 && he.h_addrtype == AF_INET && he.h_length == 4 && he.h_aliases[0] == 0);
        assert((uint8_t)he.h_addr_list[0][0] == 1 && (uint8_t)he.h_addr_list[0][3] == 4 && he.h_addr_list[1] == 0);
        assert(he.h_name >= buf && he.h_name < buf + sizeof buf && (char *)he.h_addr_list >= buf && (char *)he.h_addr_list < buf + sizeof buf);
        assert(h_errno == 77 && stat && (uint8_t)stat->h_addr_list[0][0] == 5); /* the static result is untouched */
        /* Too small for the literal: ERANGE, NETDB_INTERNAL, errno ERANGE, *result NULL. */
        res = (struct hostent *)1; herr = 12345; errno = 0;
        assert(gethostbyname_r("1.2.3.4", &he, buf, 16, &res, &herr) == ERANGE && res == 0 && herr == NETDB_INTERNAL && errno == ERANGE);
        res = (struct hostent *)1; herr = 12345; errno = 0;
        assert(gethostbyname_r("1.2.3.4", &he, buf, 0, &res, &herr) == ERANGE && res == 0 && herr == NETDB_INTERNAL);
        /* gethostbyname2_r: IPv6 literals, family mismatch is a miss, another family is EAFNOSUPPORT with NO_DATA. */
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyname2_r("2001:db8::9", AF_INET6, &he, buf, sizeof buf, &res, &herr) == 0 && res == &he && herr == 0);
        assert(he.h_addrtype == AF_INET6 && he.h_length == 16 && (uint8_t)he.h_addr_list[0][15] == 9 && he.h_addr_list[1] == 0);
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyname2_r("1.2.3.4", AF_INET6, &he, buf, sizeof buf, &res, &herr) == 0 && res == 0 && herr == HOST_NOT_FOUND);
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyname2_r("2001:db8::9", AF_INET, &he, buf, sizeof buf, &res, &herr) == 0 && res == 0 && herr == HOST_NOT_FOUND);
        res = (struct hostent *)1; herr = 12345; errno = 0;
        assert(gethostbyname2_r("x", 1, &he, buf, sizeof buf, &res, &herr) == EAFNOSUPPORT && res == 0 && herr == NO_DATA && errno == EAFNOSUPPORT);
        /* A name through the kernel resolver: a hit fills the buffer, a miss is 0/NULL/HOST_NOT_FOUND, a timeout TRY_AGAIN. */
        moqi_test_reply = 0;
        moqi_test_fill[0] = 10; moqi_test_fill[1] = 0; moqi_test_fill[2] = 2; moqi_test_fill[3] = 2;
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyname_r("gateway", &he, buf, sizeof buf, &res, &herr) == 0 && res == &he && strcmp(he.h_name, "gateway") == 0);
        assert((uint8_t)he.h_addr_list[0][0] == 10 && (uint8_t)he.h_addr_list[0][3] == 2);
        moqi_test_reply = -2;
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyname_r("nope.invalid", &he, buf, sizeof buf, &res, &herr) == 0 && res == 0 && herr == HOST_NOT_FOUND);
        moqi_test_reply = -110;
        res = (struct hostent *)1; herr = 12345;
        errno = 0;
        assert(gethostbyname_r("slow.example", &he, buf, sizeof buf, &res, &herr) == EAGAIN && res == 0 && herr == TRY_AGAIN && errno == EAGAIN);
        moqi_test_reply = 0;
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyname_r((const char *)0, &he, buf, sizeof buf, &res, &herr) == 0 && res == 0 && herr == HOST_NOT_FOUND);
        assert(h_errno == 77);
        /* gethostbyaddr_r: argument errors as in gethostbyaddr, but reported through the return value and *h_errnop. */
        static const uint8_t addr4[16] = {10, 5, 0, 9};
        res = (struct hostent *)1; herr = 12345; errno = 0;
        assert(gethostbyaddr_r(addr4, 3, AF_INET, &he, buf, sizeof buf, &res, &herr) == EAFNOSUPPORT && res == 0 && herr == NETDB_INTERNAL && errno == EAFNOSUPPORT);
        res = (struct hostent *)1; herr = 12345; errno = 0;
        assert(gethostbyaddr_r(addr4, 5, AF_INET, &he, buf, sizeof buf, &res, &herr) == 0 && res == 0 && herr == TRY_AGAIN && errno == 0);
        res = (struct hostent *)1; herr = 12345; errno = 0;
        assert(gethostbyaddr_r(addr4, 4, 1, &he, buf, sizeof buf, &res, &herr) == EAFNOSUPPORT && res == 0 && herr == NETDB_INTERNAL);
        res = (struct hostent *)1; herr = 12345;
        assert(gethostbyaddr_r(addr4, 4, AF_INET, &he, buf, sizeof buf, &res, &herr) == 0 && res == 0 && herr == HOST_NOT_FOUND);
        res = (struct hostent *)1; herr = 12345; errno = 0;
        assert(gethostbyaddr_r(addr4, 4, AF_UNSPEC, &he, buf, sizeof buf, &res, &herr) == EAFNOSUPPORT && res == 0 && herr == NETDB_INTERNAL);
        assert(h_errno == 77);
    }

    /* if_nametoindex / if_indextoname over SIOCGIFINDEX / SIOCGIFNAME (glibc, measured): 0 with ENODEV, NULL with ENXIO; a name of
     * IF_NAMESIZE characters or more never reaches the kernel; the socket used for the ioctl is closed every time. */
    {
        assert(IF_NAMESIZE == 16);
        stub_reset();
        errno = 0;
        assert(if_nametoindex("lo") == 1 && errno == 0);
        assert(if_nametoindex("eth0") == 2);
        assert(stub_count(SYS_socket) == 2 && stub_count(SYS_close) == 2 && stub_count(SYS_ioctl) == 2);
        errno = 0;
        assert(if_nametoindex("nosuch0") == 0 && errno == ENODEV);
        errno = 0;
        assert(if_nametoindex("LO") == 0 && errno == ENODEV);
        errno = 0;
        assert(if_nametoindex("") == 0 && errno == ENODEV);
        stub_reset();
        errno = 0;
        assert(if_nametoindex("0123456789abcdef") == 0 && errno == ENODEV && stub_count(SYS_ioctl) == 0);
        errno = 0;
        assert(if_nametoindex((const char *)0) == 0 && errno == ENODEV && stub_count(SYS_ioctl) == 0);
        /* No socket: the socket error, as glibc reports it. */
        stub_reset();
        stub_socket_reply = -24; /* EMFILE */
        errno = 0;
        assert(if_nametoindex("lo") == 0 && errno == EMFILE && stub_count(SYS_close) == 0);
        stub_reset();
        char nb[IF_NAMESIZE + 4];
        memset(nb, 'X', sizeof nb);
        errno = 0;
        assert(if_indextoname(1, nb) == nb && strcmp(nb, "lo") == 0 && errno == 0);
        assert(if_indextoname(2, nb) == nb && strcmp(nb, "eth0") == 0);
        assert(stub_count(SYS_socket) == 2 && stub_count(SYS_close) == 2);
        errno = 0;
        assert(if_indextoname(0, nb) == 0 && errno == ENXIO);
        errno = 0;
        assert(if_indextoname(3, nb) == 0 && errno == ENXIO);
        errno = 0;
        assert(if_indextoname(0xFFFFFFFFu, nb) == 0 && errno == ENXIO);
        assert(if_indextoname(1, (char *)0) == 0);
        stub_reset();
    }

    /* AI_ADDRCONFIG (glibc, measured with dummy interfaces in `unshare -n`, see the hello512 section of the review document):
     * a family counts as configured when a non-loopback address of it exists, and an IPv6 link-local address counts. */
    {
        /* /proc/net/if_inet6 text: ::1 alone is not IPv6; a link-local or global address is. */
        static const char only_lo[] = "00000000000000000000000000000001 01 80 10 80       lo\n";
        static const char with_ll[] = "fe80000000000000505400fffe123456 02 40 20 80     eth0\n00000000000000000000000000000001 01 80 10 80       lo\n";
        static const char with_global[] = "20010db8000000000000000000000051 02 40 00 00     eth0\n";
        assert(!if_inet6_has_nonloopback(only_lo, sizeof only_lo - 1));
        assert(if_inet6_has_nonloopback(with_ll, sizeof with_ll - 1));
        assert(if_inet6_has_nonloopback(with_global, sizeof with_global - 1));
        assert(!if_inet6_has_nonloopback("", 0));
        assert(!if_inet6_has_nonloopback("zz80000000000000505400fffe123456 02 40 20 80     eth0\n", 54)); /* not hex */
        /* SIOCGIFCONF records (40 bytes: name, then a sockaddr_in at 16): 127/8 is loopback. */
        uint8_t conf[2 * 40];
        memset(conf, 0, sizeof conf);
        memcpy(conf, "lo", 2);
        conf[16] = AF_INET; conf[20] = 127; conf[23] = 1;
        assert(!ifconf_has_nonloopback4(conf, 40));
        memcpy(conf + 40, "eth0", 4);
        conf[56] = AF_INET; conf[60] = 10; conf[62] = 2; conf[63] = 15;
        assert(ifconf_has_nonloopback4(conf, 80));
        conf[60] = 127;
        assert(!ifconf_has_nonloopback4(conf, 80));
        /* eth0 before DHCP is listed with 0.0.0.0: that is no address (Linux lists no IPv4 record for it at all). */
        memset(conf + 60, 0, 4);
        assert(!ifconf_has_nonloopback4(conf, 80));

        /* The rule: both or neither configured keeps AF_UNSPEC as it is; with exactly one, the other family is removed. An
         * explicit family that is not configured is EAI_NONAME (neither configured included). */
        assert(addrconfig_rule(AF_UNSPEC, 1, 1) == ADDRCONFIG_KEEP_ALL);
        assert(addrconfig_rule(AF_UNSPEC, 0, 0) == ADDRCONFIG_KEEP_ALL);
        assert(addrconfig_rule(AF_UNSPEC, 1, 0) == ADDRCONFIG_ONLY_INET);
        assert(addrconfig_rule(AF_UNSPEC, 0, 1) == ADDRCONFIG_ONLY_INET6);
        assert(addrconfig_rule(AF_INET, 1, 0) == ADDRCONFIG_KEEP_ALL && addrconfig_rule(AF_INET, 1, 1) == ADDRCONFIG_KEEP_ALL);
        assert(addrconfig_rule(AF_INET, 0, 1) == ADDRCONFIG_NONAME && addrconfig_rule(AF_INET, 0, 0) == ADDRCONFIG_NONAME);
        assert(addrconfig_rule(AF_INET6, 0, 1) == ADDRCONFIG_KEEP_ALL && addrconfig_rule(AF_INET6, 1, 0) == ADDRCONFIG_NONAME);
        assert(addrconfig_rule(AF_INET6, 0, 0) == ADDRCONFIG_NONAME);

        /* Through getaddrinfo on the host stub: SIOCGIFCONF answers lo only and there is no /proc file, so neither family is
         * configured: AF_UNSPEC is unchanged, an explicit family is EAI_NONAME, without the flag nothing changes. */
        struct addrinfo hints, *res;
        memset(&hints, 0, sizeof hints);
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags = AI_ADDRCONFIG;
        res = 0;
        assert(getaddrinfo("::1", "80", &hints, &res) == 0 && res && res->ai_family == AF_INET6);
        freeaddrinfo(res);
        hints.ai_family = AF_INET;
        assert(getaddrinfo("127.0.0.1", "80", &hints, &res) == EAI_NONAME);
        hints.ai_family = AF_INET6;
        assert(getaddrinfo("::1", "80", &hints, &res) == EAI_NONAME);
        hints.ai_flags = 0;
        res = 0;
        assert(getaddrinfo("::1", "80", &hints, &res) == 0);
        freeaddrinfo(res);
        stub_reset();
    }

    /* if_nameindex (glibc, measured): every interface in index order, then {0, NULL}; struct if_nameindex is 16 bytes. The array
     * and the names are malloc'd and if_freenameindex releases all of them; NULL is a no-op here (glibc crashes on it). */
    {
        assert(sizeof(struct if_nameindex) == 16 && offsetof(struct if_nameindex, if_index) == 0 &&
               offsetof(struct if_nameindex, if_name) == 8);
        stub_reset();
        int live0 = live_allocs;
        errno = 0;
        struct if_nameindex *ni = if_nameindex();
        assert(ni && errno == 0);
        assert(ni[0].if_index == 1 && strcmp(ni[0].if_name, "lo") == 0);
        assert(ni[1].if_index == 2 && strcmp(ni[1].if_name, "eth0") == 0);
        assert(ni[2].if_index == 0 && ni[2].if_name == 0);
        assert(stub_count(SYS_socket) == 1 && stub_count(SYS_close) == 1);
        if_freenameindex(ni);
        assert(live_allocs == live0);
        if_freenameindex((struct if_nameindex *)0);
        /* Only lo: one entry. */
        stub_ifs = 1;
        ni = if_nameindex();
        assert(ni && ni[0].if_index == 1 && ni[1].if_index == 0 && ni[1].if_name == 0);
        if_freenameindex(ni);
        stub_ifs = 2;
        /* No socket: NULL with the socket's error. */
        stub_reset();
        stub_socket_reply = -24;
        errno = 0;
        assert(if_nameindex() == 0 && errno == EMFILE);
        assert(live_allocs == live0);
        stub_reset();
    }

    /* Interface-name scopes: getaddrinfo takes "%name" on fe80::/10 and on multicast of scope 1 or 2 (glibc, measured), getnameinfo
     * prints "%name" for fe80::/10 and multicast of scope 2 whose index names an interface, otherwise the number. */
    {
        struct addrinfo hints, *res;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET6;
        hints.ai_socktype = SOCK_STREAM;
        #define SCOPE(p) ((unsigned)(p)->ai_addr[24] | (unsigned)(p)->ai_addr[25] << 8 | (unsigned)(p)->ai_addr[26] << 16 | (unsigned)(p)->ai_addr[27] << 24)
        static const char *const ok_nodes[] = {"fe80::1%lo", "febf::1%eth0", "ff02::1%lo", "ff01::1%lo", "ff12::1%eth0"};
        static const unsigned ok_scope[] = {1, 2, 1, 1, 2};
        for (unsigned i = 0; i < sizeof ok_nodes / sizeof ok_nodes[0]; i++) {
            res = 0;
            assert(getaddrinfo(ok_nodes[i], "80", &hints, &res) == 0 && res && SCOPE(res) == ok_scope[i]);
            freeaddrinfo(res);
        }
        static const char *const bad_nodes[] = {"2001:db8::1%lo", "fec0::1%lo", "ff05::1%lo", "fe80::1%nosuch0", "fe80::1%LO", "fe80::1%",
                                                "fe80::1%lo%1", "fe80::1%0123456789abcdef", "1.2.3.4%lo"};
        for (unsigned i = 0; i < sizeof bad_nodes / sizeof bad_nodes[0]; i++) {
            res = 0;
            assert(getaddrinfo(bad_nodes[i], "80", &hints, &res) == EAI_NONAME);
        }
        /* A numeric scope works on any address, as before. */
        res = 0;
        assert(getaddrinfo("2001:db8::1%1", "80", &hints, &res) == 0 && SCOPE(res) == 1);
        freeaddrinfo(res);

        uint8_t sa6[28];
        char host[64];
        struct { const char *addr; unsigned scope; const char *want; } rows[] = {
            {"fe80::1", 1, "fe80::1%lo"}, {"febf::1", 2, "febf::1%eth0"}, {"ff02::1", 1, "ff02::1%lo"}, {"ff12::1", 2, "ff12::1%eth0"},
            {"ff01::1", 1, "ff01::1%1"}, {"ff05::1", 1, "ff05::1%1"}, {"fec0::1", 1, "fec0::1%1"}, {"2001:db8::1", 1, "2001:db8::1%1"},
            {"::1", 1, "::1%1"}, {"fe80::1", 99, "fe80::1%99"},
        };
        for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++) {
            memset(sa6, 0, sizeof sa6);
            sa6[0] = AF_INET6;
            assert(ipv6_from_text(rows[i].addr, sa6 + 8));
            sa6[24] = (uint8_t)rows[i].scope;
            assert(getnameinfo(sa6, 28, host, sizeof host, 0, 0, NI_NUMERICHOST) == 0 && strcmp(host, rows[i].want) == 0);
        }
        /* The name has to fit: "fe80::1%lo" is 10 bytes, so 10 is EAI_OVERFLOW and 11 fits. */
        memset(sa6, 0, sizeof sa6);
        sa6[0] = AF_INET6;
        assert(ipv6_from_text("fe80::1", sa6 + 8));
        sa6[24] = 1;
        assert(getnameinfo(sa6, 28, host, 10, 0, 0, NI_NUMERICHOST) == EAI_OVERFLOW);
        assert(getnameinfo(sa6, 28, host, 11, 0, 0, NI_NUMERICHOST) == 0 && strcmp(host, "fe80::1%lo") == 0);
        #undef SCOPE
    }

    /* Packing a whole line into the caller's buffer: the exact size is what decides ERANGE, and nothing is written past it. */
    {
        static const char hosts[] = "10.5.0.9 First.example alias other\n";
        const char *names = 0;
        size_t nl = hosts_reverse_names(hosts, sizeof(hosts) - 1, AF_INET, (const uint8_t[]){10, 5, 0, 9}, &names);
        static const uint8_t a4[4] = {10, 5, 0, 9};
        const char *addrs[1] = {(const char *)a4};
        struct hostent he;
        char buf[256];
        size_t need = 0;
        for (size_t cap = 0; cap < sizeof buf; cap++) {
            memset(buf, 0x5A, sizeof buf);
            if (hostent_pack(&he, buf, cap, names, nl, AF_INET, addrs, 1) == 0) { need = cap; break; }
            for (size_t k = cap; k < sizeof buf; k++) assert((unsigned char)buf[k] == 0x5A);
        }
        assert(need > 0 && strcmp(he.h_name, "First.example") == 0 && strcmp(he.h_aliases[0], "alias") == 0);
        assert(strcmp(he.h_aliases[1], "other") == 0 && he.h_aliases[2] == 0 && he.h_addr_list[1] == 0);
        assert(memcmp(he.h_addr_list[0], a4, 4) == 0 && ((uintptr_t)he.h_aliases % sizeof(char *)) == 0);
        for (size_t k = need; k < sizeof buf; k++) assert((unsigned char)buf[k] == 0x5A);
    }

    /* gethostbyname2 without /etc/hosts (the host test has no file system): a literal answers only its own family, AF_INET6 has no
     * resolver fallback, another family is NO_DATA; AF_INET resolves through the kernel like gethostbyname (glibc, measured). */
    {
        struct hostent *h = gethostbyname2("2001:db8::9", AF_INET6);
        assert(h && h->h_addrtype == AF_INET6 && h->h_length == 16 && (unsigned char)h->h_addr_list[0][15] == 9 && h->h_addr_list[1] == 0);
        assert(strcmp(h->h_name, "2001:db8::9") == 0 && h->h_aliases[0] == 0 && h_errno == 0);
        assert(gethostbyname2("10.1.1.1", AF_INET6) == 0 && h_errno == HOST_NOT_FOUND);
        assert(gethostbyname2("2001:db8::9", AF_INET) == 0 && h_errno == HOST_NOT_FOUND);
        moqi_test_last_nr = 0;
        assert(gethostbyname2("nosuch.invalid", AF_INET6) == 0 && h_errno == HOST_NOT_FOUND && moqi_test_last_nr == 0);
        assert(gethostbyname2("x", 1) == 0 && h_errno == NO_DATA);
        assert(gethostbyname2((const char *)0, AF_INET6) == 0 && h_errno == HOST_NOT_FOUND);
        h = gethostbyname2("10.1.1.1", AF_INET);
        assert(h && h->h_addrtype == AF_INET && h->h_length == 4 && (unsigned char)h->h_addr_list[0][3] == 1 && h->h_addr_list[1] == 0);
    }

    /* /etc/resolv.conf nameserver lines (glibc res_init, measured): the keyword at the start of the line and in lower case, then a
     * blank or tab and a dotted IPv4 address, optionally followed by blanks and anything; at most 3, in file order. '#' and ';'
     * lines, a leading blank, "addr;x", a CR before the newline, IPv6 and invalid addresses are not servers here. */
    {
        uint8_t ns[3][4];
        static const char conf[] =
            "# comment\n; also\n  nameserver 1.1.1.1\nNameServer 2.2.2.2\nnameserver 300.1.1.1\nnameserver 7.7.7.7x\nnameserver ::1\n"
            "nameserver 10.0.2.3\nnameserver\t10.0.2.4 # trailing\nnameserver 10.0.2.5;x\nnameserver 10.0.2.6\r\noptions ndots:2\n"
            "nameserver 10.0.2.7\nnameserver 10.0.2.8\n";
        size_t k = resolv_conf_servers(conf, sizeof conf - 1, ns, 3);
        assert(k == 3);
        assert(ns[0][0] == 10 && ns[0][3] == 3 && ns[1][3] == 4 && ns[2][3] == 7);
        assert(resolv_conf_servers(conf, sizeof conf - 1, ns, 1) == 1 && ns[0][3] == 3);
        assert(resolv_conf_servers("", 0, ns, 3) == 0);
        assert(resolv_conf_servers("nameserver 10.9.9.9", 19, ns, 3) == 1 && ns[0][3] == 9); /* no final newline */
        /* The 0.0.0.0, broadcast and multicast addresses the kernel refuses are not servers either. */
        static const char odd[] = "nameserver 0.0.0.0\nnameserver 255.255.255.255\nnameserver 224.0.0.251\nnameserver 10.1.1.1\n";
        assert(resolv_conf_servers(odd, sizeof odd - 1, ns, 3) == 1 && ns[0][3] == 1);
    }

    /* /etc/resolv.conf "search", "domain" and "options ndots:N" (glibc res_init and res_search, measured): the names to ask for, in
     * order. Fewer dots than ndots (default 1): each search domain, then the name as given; at least ndots: the name first, then the
     * domains. A trailing dot is the name alone. The last search or domain line wins, a domain line is a one-entry search list, and
     * an empty one clears it; "." and "#" are words like any other except that a domain of "." adds nothing; options ndots takes a
     * plain number, the last one wins, a bad one is ignored. */
    {
        char c[8][256];
        static const char ab[] = "nameserver 127.0.0.1\nsearch a.test b.test\n";
        size_t k = resolv_conf_candidates(ab, sizeof ab - 1, "x", c, 8);
        assert(k == 3 && strcmp(c[0], "x.a.test") == 0 && strcmp(c[1], "x.b.test") == 0 && strcmp(c[2], "x") == 0);
        k = resolv_conf_candidates(ab, sizeof ab - 1, "x.y", c, 8);
        assert(k == 3 && strcmp(c[0], "x.y") == 0 && strcmp(c[1], "x.y.a.test") == 0 && strcmp(c[2], "x.y.b.test") == 0);
        k = resolv_conf_candidates(ab, sizeof ab - 1, "x.", c, 8);
        assert(k == 1 && strcmp(c[0], "x") == 0);
        assert(resolv_conf_candidates(ab, sizeof ab - 1, "x", c, 1) == 1 && strcmp(c[0], "x.a.test") == 0);
        static const char none[] = "nameserver 127.0.0.1\n";
        assert(resolv_conf_candidates(none, sizeof none - 1, "x", c, 8) == 1 && strcmp(c[0], "x") == 0);
        assert(resolv_conf_candidates("", 0, "x", c, 8) == 1 && strcmp(c[0], "x") == 0);
        static const char dom[] = "domain d.test\n";
        k = resolv_conf_candidates(dom, sizeof dom - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.d.test") == 0 && strcmp(c[1], "x") == 0);
        static const char last1[] = "domain d.test\nsearch s.test\n";
        k = resolv_conf_candidates(last1, sizeof last1 - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.s.test") == 0);
        static const char last2[] = "search s.test\ndomain d.test\n";
        k = resolv_conf_candidates(last2, sizeof last2 - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.d.test") == 0);
        static const char twice[] = "search a.test\nsearch b.test\n";
        k = resolv_conf_candidates(twice, sizeof twice - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.b.test") == 0);
        static const char cleared[] = "search a.test\nsearch\n";
        assert(resolv_conf_candidates(cleared, sizeof cleared - 1, "x", c, 8) == 1);
        static const char blank[] = "search a.test\nsearch \n";
        assert(resolv_conf_candidates(blank, sizeof blank - 1, "x", c, 8) == 1);
        static const char ddot[] = "domain .\n";
        assert(resolv_conf_candidates(ddot, sizeof ddot - 1, "x", c, 8) == 1);
        static const char sdot[] = "search .\n";
        assert(resolv_conf_candidates(sdot, sizeof sdot - 1, "x", c, 8) == 1 && strcmp(c[0], "x") == 0);
        static const char fq[] = "search a.test.\n";
        k = resolv_conf_candidates(fq, sizeof fq - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.a.test") == 0);
        static const char indented[] = " search a.test\n";
        assert(resolv_conf_candidates(indented, sizeof indented - 1, "x", c, 8) == 1);
        static const char words[] = "search  a.test\tb.test  # c\n";
        k = resolv_conf_candidates(words, sizeof words - 1, "x", c, 8);
        assert(k == 5 && strcmp(c[1], "x.b.test") == 0 && strcmp(c[2], "x.#") == 0 && strcmp(c[3], "x.c") == 0);
        /* hello541: "options no-tld-query" (glibc 2.44, measured): a name with no dot is not asked as given after the search list;
         * a dotted name, a name with no search list, ndots:0 and a "." on the list still are. Matched by its first 12 characters. */
        static const char ntq[] = "search a.test b.test\noptions no-tld-query\n";
        k = resolv_conf_candidates(ntq, sizeof ntq - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.a.test") == 0 && strcmp(c[1], "x.b.test") == 0);
        k = resolv_conf_candidates(ntq, sizeof ntq - 1, "x.y", c, 8);
        assert(k == 3 && strcmp(c[0], "x.y") == 0);
        static const char ntq2[] = "search a.test\noptions no-tld-query ndots:2\n";
        k = resolv_conf_candidates(ntq2, sizeof ntq2 - 1, "x.y", c, 8);
        assert(k == 2 && strcmp(c[0], "x.y.a.test") == 0 && strcmp(c[1], "x.y") == 0);
        static const char ntq0[] = "search a.test\noptions no-tld-query ndots:0\n";
        k = resolv_conf_candidates(ntq0, sizeof ntq0 - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x") == 0 && strcmp(c[1], "x.a.test") == 0);
        static const char ntqn[] = "nameserver 127.0.0.1\noptions no-tld-query\n";
        assert(resolv_conf_candidates(ntqn, sizeof ntqn - 1, "x", c, 8) == 1 && strcmp(c[0], "x") == 0);
        static const char ntqx[] = "search a.test\noptions no-tld-queryx\n";
        assert(resolv_conf_candidates(ntqx, sizeof ntqx - 1, "x", c, 8) == 1 && strcmp(c[0], "x.a.test") == 0);
        static const char ntqs[] = "search a.test\noptions no-tld-quer\n";
        assert(resolv_conf_candidates(ntqs, sizeof ntqs - 1, "x", c, 8) == 2 && strcmp(c[1], "x") == 0);
        static const char ntqr[] = "search a.test .\noptions no-tld-query\n";
        k = resolv_conf_candidates(ntqr, sizeof ntqr - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.a.test") == 0 && strcmp(c[1], "x") == 0);
        static const char ntql[] = "search a.test\noptions no-tld-query\noptions timeout:1\n";
        assert(resolv_conf_candidates(ntql, sizeof ntql - 1, "x", c, 8) == 1);
        /* A "." on the search list asks the name as given in its place, and then not again at the end (glibc 2.44, measured);
         * when the name was already asked first (at least ndots dots), the "." adds nothing. */
        static const char rmid[] = "search a.test . b.test\n";
        k = resolv_conf_candidates(rmid, sizeof rmid - 1, "x", c, 8);
        assert(k == 3 && strcmp(c[0], "x.a.test") == 0 && strcmp(c[1], "x") == 0 && strcmp(c[2], "x.b.test") == 0);
        static const char rfirst[] = "search . a.test\n";
        k = resolv_conf_candidates(rfirst, sizeof rfirst - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x") == 0 && strcmp(c[1], "x.a.test") == 0);
        k = resolv_conf_candidates(rfirst, sizeof rfirst - 1, "x.y", c, 8);
        assert(k == 2 && strcmp(c[0], "x.y") == 0 && strcmp(c[1], "x.y.a.test") == 0);
        static const char n2[] = "search a.test\noptions ndots:2\n";
        k = resolv_conf_candidates(n2, sizeof n2 - 1, "x.y", c, 8);
        assert(k == 2 && strcmp(c[0], "x.y.a.test") == 0 && strcmp(c[1], "x.y") == 0);
        static const char n0[] = "search a.test\noptions ndots:0\n";
        k = resolv_conf_candidates(n0, sizeof n0 - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x") == 0 && strcmp(c[1], "x.a.test") == 0);
        static const char nlast[] = "search a.test\noptions ndots:3 ndots:0\n";
        assert(resolv_conf_candidates(nlast, sizeof nlast - 1, "x", c, 8) == 2 && strcmp(c[0], "x") == 0);
        static const char nx[] = "search a.test\noptions ndots:x\n";
        assert(resolv_conf_candidates(nx, sizeof nx - 1, "x", c, 8) == 2 && strcmp(c[0], "x") == 0);
        static const char nneg[] = "search a.test\noptions ndots:-1\n";
        assert(resolv_conf_candidates(nneg, sizeof nneg - 1, "a.b.c", c, 8) == 2 && strcmp(c[0], "a.b.c.a.test") == 0);
        static const char n2x[] = "search a.test\noptions ndots:2x\n";
        assert(resolv_conf_candidates(n2x, sizeof n2x - 1, "x.y", c, 8) == 2 && strcmp(c[0], "x.y.a.test") == 0);
        static const char nother[] = "search a.test\noptions\tfoo  ndots:2\n";
        assert(resolv_conf_candidates(nother, sizeof nother - 1, "x.y", c, 8) == 2 && strcmp(c[0], "x.y.a.test") == 0);
        static const char nbig[] = "search a.test\noptions ndots:20\n";
        k = resolv_conf_candidates(nbig, sizeof nbig - 1, "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p", c, 8);
        assert(k == 2 && strcmp(c[0], "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p") == 0);
        /* A domain that would make the name longer than 253 characters ends the list: later domains are not asked (glibc). */
        char longconf[400];
        strcpy(longconf, "search ");
        for (int i = 0; i < 4; i++) {
            strcat(longconf, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
            if (i < 3) strcat(longconf, ".");
        }
        strcat(longconf, ".aaaaaaaaaa s.test\n"); /* a 254-character domain */
        k = resolv_conf_candidates(longconf, strlen(longconf), "x", c, 8);
        assert(k == 1 && strcmp(c[0], "x") == 0);
        static const char before[] = "search s.test d.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa t.test\n";
        k = resolv_conf_candidates(before, sizeof before - 1, "x", c, 8);
        assert(k == 2 && strcmp(c[0], "x.s.test") == 0 && strcmp(c[1], "x") == 0);
        /* At the limit (measured): a 250-character domain takes "xx" (253) but not "xxx" (254). A label over 63 is skipped. */
        char edge[300] = "search ";
        size_t e = strlen(edge);
        for (int i = 0; i < 250; i++) edge[e++] = (i % 61 == 60) ? '.' : 'a';
        edge[e++] = '\n';
        edge[e] = 0;
        assert(resolv_conf_candidates(edge, e, "xx", c, 8) == 2 && strlen(c[0]) == 253);
        assert(resolv_conf_candidates(edge, e, "xxx", c, 8) == 1 && strcmp(c[0], "xxx") == 0);
        char lab64[100] = "search d.";
        e = strlen(lab64);
        for (int i = 0; i < 64; i++) lab64[e++] = 'q';
        strcpy(lab64 + e, " s.test\n");
        k = resolv_conf_candidates(lab64, strlen(lab64), "x", c, 8);
        assert(k == 1 && strcmp(c[0], "x") == 0);
        assert(resolv_conf_candidates(ab, sizeof ab - 1, (const char *)0, c, 8) == 0);
        assert(resolv_conf_candidates(ab, sizeof ab - 1, "", c, 8) == 0);
    }

    /* resolv.conf timeout and attempts, and what each reply means (glibc res_send/res_search, measured). Replies: 0 an address,
     * -2 NXDOMAIN, -61 NODATA, -11 SERVFAIL, -111 NOTIMP/REFUSED, -71 another RCODE, -110 no reply. */
    {
        uint8_t a4[4];
        static const char three[] = "nameserver 10.0.0.1\nnameserver 10.0.0.2\nnameserver 10.0.0.3\noptions timeout:2 attempts:2\n";
        static const long silent6[] = {-110, -110, -110, -110, -110, -110};
        q_script(three, silent6, 6);
        /* Rounds over the servers; server i waits (timeout << i) / nservers seconds: 2, 1 (4/3), 2 (8/3). */
        assert(gethostbyname_ipv4("x.y", a4) == -110);
        assert(strcmp(q_log, "x.y@1/2;x.y@2/1;x.y@3/2;x.y@1/2;x.y@2/1;x.y@3/2;") == 0);
        static const long late[] = {-110, -110, 0};
        q_script(three, late, 3);
        assert(gethostbyname_ipv4("x.y", a4) == 0 && a4[3] == 3 && q_calls == 3);
        /* SERVFAIL and REFUSED move on to the next server; NXDOMAIN, NODATA and an address end the query. */
        static const long sf[] = {-11, -111, 0};
        q_script(three, sf, 3);
        assert(gethostbyname_ipv4("x.y", a4) == 0 && q_calls == 3);
        static const long nx[] = {-11, -2};
        q_script(three, nx, 2);
        assert(gethostbyname_ipv4("x.y", a4) == -2 && q_calls == 2);
        static const long nd[] = {-61};
        q_script(three, nd, 1);
        assert(gethostbyname_ipv4("x.y", a4) == -61 && q_calls == 1);
        static const long fe[] = {-71};
        q_script(three, fe, 1);
        assert(gethostbyname_ipv4("x.y", a4) == -71 && q_calls == 1);
        /* Every server failing: EAGAIN when any replied with a server error, ETIMEDOUT when none replied. */
        static const long sfall[] = {-11, -110, -110, -110, -110, -110};
        q_script(three, sfall, 6);
        assert(gethostbyname_ipv4("x.y", a4) == -11 && q_calls == 6);
        /* Defaults: timeout 5, attempts 2. One server waits 5 s each time. */
        static const long two[] = {-110, -110};
        q_script("nameserver 10.0.0.1\n", two, 2);
        assert(gethostbyname_ipv4("x.y", a4) == -110 && strcmp(q_log, "x.y@1/5;x.y@1/5;") == 0);
        /* Limits: attempts at most 5, 0 asks nobody; timeout at most 30, 0 is the 1 s minimum. */
        static const long many[] = {-110, -110, -110, -110, -110, -110, -110, -110};
        q_script("nameserver 10.0.0.1\noptions attempts:9 timeout:99\n", many, 8);
        assert(gethostbyname_ipv4("x.y", a4) == -110 && q_calls == 5 && strncmp(q_log, "x.y@1/30;", 9) == 0);
        q_script("nameserver 10.0.0.1\noptions attempts:0\n", many, 8);
        assert(gethostbyname_ipv4("x.y", a4) == -110 && q_calls == 0);
        q_script("nameserver 10.0.0.1\noptions timeout:0 attempts:1\n", many, 8);
        assert(gethostbyname_ipv4("x.y", a4) == -110 && strcmp(q_log, "x.y@1/1;") == 0);
        q_script("nameserver 10.0.0.1\noptions timeout:3\noptions attempts:1\n", many, 8);
        assert(gethostbyname_ipv4("x.y", a4) == -110 && strcmp(q_log, "x.y@1/3;") == 0);
        /* The last reply decides between SERVFAIL and REFUSED when every server fails. */
        static const long sfref[] = {-11, -111, -110, -110, -110, -110};
        q_script(three, sfref, 6);
        assert(gethostbyname_ipv4("x.y", a4) == -111 && q_calls == 6);
        /* The search list: NXDOMAIN, NODATA and SERVFAIL go on to the next domain; REFUSED, another RCODE or no reply ends the
         * domain list, but the name as given is still asked. With nothing found: NODATA if a domain had it, else SERVFAIL if one
         * had that, else the as-given query's result. */
        static const char srch[] = "nameserver 10.0.0.1\nsearch a.test b.test\noptions attempts:1\n";
        static const long s1[] = {-61, -2, -11};
        q_script(srch, s1, 3);
        assert(gethostbyname_ipv4("x", a4) == -61 && strcmp(q_log, "x.a.test@1/5;x.b.test@1/5;x@1/5;") == 0);
        static const long s2[] = {-11, -2, -2};
        q_script(srch, s2, 3);
        assert(gethostbyname_ipv4("x", a4) == -11 && q_calls == 3);
        static const long s3[] = {-2, -2, -2};
        q_script(srch, s3, 3);
        assert(gethostbyname_ipv4("x", a4) == -2 && q_calls == 3);
        static const long s4[] = {-111, -2};
        q_script(srch, s4, 2);
        assert(gethostbyname_ipv4("x", a4) == -2 && strcmp(q_log, "x.a.test@1/5;x@1/5;") == 0);
        static const long s5[] = {-2, -71, -2};
        q_script(srch, s5, 3);
        assert(gethostbyname_ipv4("x", a4) == -2 && strcmp(q_log, "x.a.test@1/5;x.b.test@1/5;x@1/5;") == 0);
        static const long s6[] = {-110, -110};
        q_script(srch, s6, 2);
        assert(gethostbyname_ipv4("x", a4) == -110 && strcmp(q_log, "x.a.test@1/5;x@1/5;") == 0);
        static const long s7[] = {-2, -11, 0};
        q_script(srch, s7, 3);
        assert(gethostbyname_ipv4("x", a4) == 0 && q_calls == 3);
        static const long s8[] = {-61, -71, -2};
        q_script(srch, s8, 3);
        assert(gethostbyname_ipv4("x", a4) == -61 && q_calls == 3);
        /* The name as given first (ndots:0): its result is the lookup's when nothing answers. */
        static const char first[] = "nameserver 10.0.0.1\nsearch a.test\noptions attempts:1 ndots:0\n";
        static const long f1[] = {-11, -2};
        q_script(first, f1, 2);
        assert(gethostbyname_ipv4("x", a4) == -11 && strcmp(q_log, "x@1/5;x.a.test@1/5;") == 0);
        static const long f2[] = {-2, -61};
        q_script(first, f2, 2);
        assert(gethostbyname_ipv4("x", a4) == -2 && q_calls == 2);
        static const long f3[] = {-2, 0};
        q_script(first, f3, 2);
        assert(gethostbyname_ipv4("x", a4) == 0 && a4[3] == 2);
        /* h_errno and getaddrinfo for each (glibc): NODATA is NO_DATA / EAI_NODATA, another RCODE NO_RECOVERY / EAI_NONAME,
         * SERVFAIL and no reply TRY_AGAIN / EAI_AGAIN. */
        static const long r_nd[] = {-61}, r_fe[] = {-71}, r_sf[] = {-11}, r_to[] = {-110}, r_nx[] = {-2};
        static const char one[] = "nameserver 10.0.0.1\noptions attempts:1\n";
        struct addrinfo hints, *res = 0;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        q_script(one, r_nd, 1);
        assert(gethostbyname("x.y") == 0 && h_errno == NO_DATA);
        q_script(one, r_nd, 1);
        assert(getaddrinfo("x.y", 0, &hints, &res) == EAI_NODATA);
        q_script(one, r_fe, 1);
        assert(gethostbyname("x.y") == 0 && h_errno == NO_RECOVERY);
        q_script(one, r_fe, 1);
        assert(getaddrinfo("x.y", 0, &hints, &res) == EAI_NONAME);
        q_script(one, r_sf, 1);
        assert(gethostbyname("x.y") == 0 && h_errno == TRY_AGAIN);
        q_script(one, r_sf, 1);
        assert(getaddrinfo("x.y", 0, &hints, &res) == EAI_AGAIN);
        q_script(one, r_to, 1);
        assert(gethostbyname("x.y") == 0 && h_errno == TRY_AGAIN);
        q_script(one, r_nx, 1);
        assert(gethostbyname("x.y") == 0 && h_errno == HOST_NOT_FOUND);
        assert(strcmp(gai_strerror(EAI_NODATA), "No address associated with hostname") == 0);

        /* hello520: the whole answer of dns_query. a.test CNAME b.test, two addresses: h_name is b.test, h_aliases {a.test}, both
         * addresses in h_addr_list; getaddrinfo lists both, with ai_canonname b.test. */
        static const unsigned char cn[] = {2, 1, 4, 10, 9, 9, 1, 10, 9, 9, 2, 'b', '.', 't', 'e', 's', 't', 0, 'a', '.', 't', 'e', 's', 't', 0};
        static const long ok1[] = {0};
        q_script(one, ok1, 1);
        q_answer = cn;
        q_answer_len = sizeof cn;
        struct hostent *hc = gethostbyname("a.test");
        assert(hc && strcmp(hc->h_name, "b.test") == 0);
        assert(hc->h_aliases[0] && strcmp(hc->h_aliases[0], "a.test") == 0 && hc->h_aliases[1] == 0);
        assert(hc->h_addr_list[0] && (unsigned char)hc->h_addr_list[0][3] == 1 && (unsigned char)hc->h_addr_list[1][3] == 2 && hc->h_addr_list[2] == 0);
        q_script(one, ok1, 1);
        q_answer = cn;
        q_answer_len = sizeof cn;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags = AI_CANONNAME;
        assert(getaddrinfo("a.test", 0, &hints, &res) == 0);
        assert(res && res->ai_canonname && strcmp(res->ai_canonname, "b.test") == 0);
        assert(res->ai_next && res->ai_next->ai_addr[7] == 2 && res->ai_next->ai_next == 0 && res->ai_addr[7] == 1);
        freeaddrinfo(res);
        /* A search domain and a CNAME together: the canonical name is the chain's end, the asked name (with its domain) an alias. */
        static const unsigned char cn2[] = {1, 1, 4, 10, 9, 9, 3, 'z', '.', 't', 'e', 's', 't', 0, 'x', '.', 'a', '.', 't', 'e', 's', 't', 0};
        q_script("nameserver 10.0.0.1\nsearch a.test\noptions attempts:1\n", ok1, 1);
        q_answer = cn2;
        q_answer_len = sizeof cn2;
        hc = gethostbyname("x");
        assert(hc && strcmp(hc->h_name, "z.test") == 0 && strcmp(hc->h_aliases[0], "x.a.test") == 0 && strcmp(q_log, "x.a.test@1/5;") == 0);
        /* hello523: 40 addresses and a 12-step chain are all kept (glibc 2.44, measured: 60 addresses, 12 aliases). */
        static unsigned char big523[4608];
        size_t mn = 0;
        big523[mn++] = 40;
        big523[mn++] = 12;
        big523[mn++] = 4;
        for (int i = 0; i < 40; i++) { big523[mn++] = 10; big523[mn++] = 9; big523[mn++] = 0; big523[mn++] = (unsigned char)(i + 1); }
        mn += (size_t)sprintf((char *)big523 + mn, "w12.test") + 1;
        mn += (size_t)sprintf((char *)big523 + mn, "w.test") + 1;
        for (int i = 1; i < 12; i++) mn += (size_t)sprintf((char *)big523 + mn, "w%d.test", i) + 1;
        q_script(one, ok1, 1);
        q_answer = big523;
        q_answer_len = mn;
        hc = gethostbyname("w.test");
        int na = 0, nal = 0;
        while (hc && hc->h_addr_list[na]) na++;
        while (hc && hc->h_aliases[nal]) nal++;
        assert(hc && strcmp(hc->h_name, "w12.test") == 0 && na == 40 && nal == 12 && (unsigned char)hc->h_addr_list[39][3] == 40);
        assert(strcmp(hc->h_aliases[11], "w11.test") == 0);
        q_script(one, ok1, 1);
        q_answer = big523;
        q_answer_len = mn;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        assert(getaddrinfo("w.test", 0, &hints, &res) == 0);
        int ng = 0;
        for (struct addrinfo *x = res; x; x = x->ai_next) ng++;
        assert(ng == 40);
        freeaddrinfo(res);

        /* Without a CNAME the asked name is canonical and there are no aliases. 507 gets an answer buffer of at least 256 bytes. */
        q_script(one, ok1, 1);
        hc = gethostbyname("plain.test");
        assert(hc && strcmp(hc->h_name, "plain.test") == 0 && hc->h_aliases[0] == 0 && hc->h_addr_list[1] == 0);
        assert(q_last_anslen >= 256);
        moqi_test_resolv_conf = (const char *)0;
    }

    /* options rotate (glibc res_send, measured): each query starts at the next server, the first one of the process at a random
     * one (the host test's seed is 1: the second server); the rest follow in file order with the usual waits. PTR queries share
     * the counter. Without rotate every query starts at the first server. */
    {
        static const char rot[] = "nameserver 10.0.0.1\nnameserver 10.0.0.2\nnameserver 10.0.0.3\noptions rotate attempts:1 timeout:3\n";
        static const long silent3[] = {-110, -110, -110}, ok[] = {0};
        uint8_t a4[4];
        q_script(rot, silent3, 3);
        assert(gethostbyname_ipv4("x.y", a4) == -110);
        assert(strcmp(q_log, "x.y@2/3;x.y@3/2;x.y@1/4;") == 0);
        q_script(rot, ok, 1);
        assert(gethostbyname_ipv4("x.y", a4) == 0 && strcmp(q_log, "x.y@3/3;") == 0);
        q_script(rot, ok, 1);
        assert(gethostbyname_ipv4("x.y", a4) == 0 && strcmp(q_log, "x.y@1/3;") == 0);
        static const char rot2[] = "nameserver 10.0.0.1\nnameserver 10.0.0.2\nnameserver 10.0.0.3\noptions rotate attempts:2 timeout:1\n";
        static const long silent6[] = {-110, -110, -110, -110, -110, -110};
        q_script(rot2, silent6, 6);
        assert(gethostbyname_ipv4("x.y", a4) == -110 && strcmp(q_log, "x.y@2/1;x.y@3/1;x.y@1/1;x.y@2/1;x.y@3/1;x.y@1/1;") == 0);
        /* rotate as a word among others, and a word that only starts with it, are told apart. */
        q_script("nameserver 10.0.0.1\nnameserver 10.0.0.2\noptions attempts:1 rotatex\n", ok, 1);
        assert(gethostbyname_ipv4("x.y", a4) == 0 && strcmp(q_log, "x.y@1/5;") == 0);
        /* The counter has moved four times since the seed (1): the fifth rotated query starts at 5 % 2, the second server. */
        q_script("nameserver 10.0.0.1\nnameserver 10.0.0.2\noptions attempts:1 timeout:1 rotate\n", ok, 1);
        assert(gethostbyname_ipv4("x.y", a4) == 0 && strcmp(q_log, "x.y@2/1;") == 0);
        moqi_test_resolv_conf = (const char *)0;
    }

    /* hello525: AAAA. gethostbyname2(AF_INET6) asks AAAA records through dns_query6 (509); getaddrinfo AF_UNSPEC asks AAAA then A
     * and lists IPv6 first; AF_INET6 + AI_V4MAPPED asks A only when there is no AAAA (and both with AI_ALL); when no family
     * answers, NXDOMAIN wins over NODATA, which wins over a failure (glibc 2.44, measured). */
    {
        static const char one[] = "nameserver 10.0.0.1\noptions attempts:1\n";
        static const long ok[] = {0}, ok2[] = {0, 0}, nd_ok[] = {-61, 0}, ok_nd[] = {0, -61};
        static const long nd_nx[] = {-61, -2}, nx_nd[] = {-2, -61}, sf_nd[] = {-11, -61}, nd_sf[] = {-61, -11}, sf_sf[] = {-11, -11};
        q_script(one, ok, 1);
        struct hostent *h6 = gethostbyname2("v6.test", AF_INET6);
        assert(h6 && h6->h_length == 16 && h6->h_addrtype == AF_INET6 && (unsigned char)h6->h_addr_list[0][0] == 0x20);
        assert(strcmp(q_log, "v6.test/6@1/5;") == 0);
        q_script(one, nd_ok, 1);
        assert(gethostbyname2("v4only.test", AF_INET6) == 0 && h_errno == NO_DATA);
        /* No nameserver: AF_INET6 is not asked of the kernel's DHCP server (it answers A only). */
        q_script("search x.test\n", ok, 1);
        assert(gethostbyname2("v6.test", AF_INET6) == 0 && h_errno == HOST_NOT_FOUND && q_calls == 0);

        struct addrinfo hints, *res = 0;
        memset(&hints, 0, sizeof hints);
        hints.ai_socktype = SOCK_STREAM;
        /* hello530: AF_UNSPEC sends both at once through dns_query2 (510); the scripted replies are A first, then AAAA. */
        q_script(one, ok2, 2);
        assert(getaddrinfo("both.test", 0, &hints, &res) == 0);
        assert(res && res->ai_family == AF_INET6 && res->ai_next && res->ai_next->ai_family == AF_INET && res->ai_next->ai_next == 0);
        assert(strcmp(q_log, "both.test/2@1/5;") == 0);
        freeaddrinfo(res);
        q_script(one, ok_nd, 2);
        assert(getaddrinfo("v4.test", 0, &hints, &res) == 0 && res->ai_family == AF_INET && res->ai_next == 0);
        freeaddrinfo(res);
        q_script(one, nd_ok, 2);
        assert(getaddrinfo("v6.test", 0, &hints, &res) == 0 && res->ai_family == AF_INET6 && res->ai_next == 0);
        freeaddrinfo(res);
        q_script(one, nd_nx, 2);
        assert(getaddrinfo("x.test", 0, &hints, &res) == EAI_NONAME);
        q_script(one, nx_nd, 2);
        assert(getaddrinfo("x.test", 0, &hints, &res) == EAI_NONAME);
        q_script(one, sf_nd, 2);
        assert(getaddrinfo("x.test", 0, &hints, &res) == EAI_NODATA);
        q_script(one, nd_sf, 2);
        assert(getaddrinfo("x.test", 0, &hints, &res) == EAI_NODATA);
        q_script(one, sf_sf, 2);
        assert(getaddrinfo("x.test", 0, &hints, &res) == EAI_AGAIN);
        /* The pair's combined result drives the search list (glibc 2.44, measured): one half answering ends it, even when the
         * other half failed and a later domain has both; both failing softly goes on; FORMERR or REFUSED ends the domains. */
        {
            static const char srch[] = "nameserver 10.0.0.1\nsearch d1 d2\noptions attempts:1\n";
            static const long a_only[] = {0, -2, 0, 0}, soft[] = {-2, -61, 0, 0}, sf2[] = {-11, -11, 0, 0}, fe2[] = {-71, -2, -2, -2};
            static const long rf2[] = {-111, -11, -2, -2}, nd_end[] = {-2, -2, -2, -2, -61, -61}, sf_end[] = {-2, -2, -2, -2, -11, -11};
            hints.ai_family = AF_UNSPEC;
            hints.ai_flags = 0;
            q_script(srch, a_only, 4);
            assert(getaddrinfo("x", 0, &hints, &res) == 0 && res->ai_family == AF_INET && res->ai_next == 0 && strcmp(q_log, "x.d1/2@1/5;") == 0);
            freeaddrinfo(res);
            q_script(srch, soft, 4);
            assert(getaddrinfo("x", 0, &hints, &res) == 0 && res->ai_next && strcmp(q_log, "x.d1/2@1/5;x.d2/2@1/5;") == 0);
            freeaddrinfo(res);
            q_script(srch, sf2, 4);
            assert(getaddrinfo("x", 0, &hints, &res) == 0 && strcmp(q_log, "x.d1/2@1/5;x.d2/2@1/5;") == 0);
            freeaddrinfo(res);
            q_script(srch, fe2, 4);
            assert(getaddrinfo("x", 0, &hints, &res) == EAI_NONAME && strcmp(q_log, "x.d1/2@1/5;x/2@1/5;") == 0);
            q_script(srch, rf2, 4);
            assert(getaddrinfo("x", 0, &hints, &res) == EAI_NONAME && strcmp(q_log, "x.d1/2@1/5;x/2@1/5;") == 0);
            q_script(srch, nd_end, 6);
            assert(getaddrinfo("x", 0, &hints, &res) == EAI_NODATA);
            q_script(srch, sf_end, 6);
            assert(getaddrinfo("x", 0, &hints, &res) == EAI_AGAIN);
            /* hello531: "options single-request" (glibc 2.44, measured; any word starting with it, so single-request-reopen
             * too): the A query, its reply, then the AAAA query, each through dns_query/dns_query6; the pair rule is unchanged. A
             * failure of the A half that ends the pair (no reply) skips the AAAA query. */
            static const char sr[] = "nameserver 10.0.0.1\noptions attempts:1 single-request\n";
            static const char srr[] = "nameserver 10.0.0.1\noptions attempts:1 single-request-reopenx\n";
            static const char notsr[] = "nameserver 10.0.0.1\noptions attempts:1 single-req\n";
            static const long both_ok[] = {0, 0}, a_to[] = {-110, 0};
            q_script(sr, both_ok, 2);
            assert(getaddrinfo("s.test", 0, &hints, &res) == 0 && res->ai_family == AF_INET6 && res->ai_next && strcmp(q_log, "s.test@1/5;s.test/6@1/5;") == 0);
            freeaddrinfo(res);
            q_script(srr, both_ok, 2);
            assert(getaddrinfo("s.test", 0, &hints, &res) == 0 && strcmp(q_log, "s.test@1/5;s.test/6@1/5;") == 0);
            freeaddrinfo(res);
            q_script(notsr, both_ok, 2);
            assert(getaddrinfo("s.test", 0, &hints, &res) == 0 && strcmp(q_log, "s.test/2@1/5;") == 0);
            freeaddrinfo(res);
            q_script(sr, a_to, 2);
            assert(getaddrinfo("s.test", 0, &hints, &res) == EAI_AGAIN && strcmp(q_log, "s.test@1/5;") == 0);
            q_script("nameserver 10.0.0.1\nsearch d1 d2\noptions attempts:1 single-request\n", a_only, 4);
            assert(getaddrinfo("x", 0, &hints, &res) == 0 && res->ai_family == AF_INET && res->ai_next == 0 && strcmp(q_log, "x.d1@1/5;x.d1/6@1/5;") == 0);
            freeaddrinfo(res);
            /* A server that does not reply moves to the next one with the pair. */
            static const char two[] = "nameserver 10.0.0.1\nnameserver 10.0.0.2\noptions attempts:1 timeout:2\n";
            static const long to_ok[] = {-110, -110, 0, 0};
            q_script(two, to_ok, 4);
            assert(getaddrinfo("y.test", 0, &hints, &res) == 0 && res->ai_next && strcmp(q_log, "y.test/2@1/2;y.test/2@2/2;") == 0);
            freeaddrinfo(res);
            hints.ai_family = AF_UNSPEC;
        }
        /* AF_INET6: AAAA only; AI_V4MAPPED maps the A answer when there is no AAAA; with an AAAA it is not asked unless AI_ALL. */
        hints.ai_family = AF_INET6;
        q_script(one, nd_ok, 2);
        assert(getaddrinfo("v4.test", 0, &hints, &res) == EAI_NODATA && q_calls == 1);
        hints.ai_flags = AI_V4MAPPED;
        q_script(one, nd_ok, 2);
        assert(getaddrinfo("v4.test", 0, &hints, &res) == 0 && res->ai_family == AF_INET6 && res->ai_addr[18] == 0xff && res->ai_addr[19] == 0xff);
        freeaddrinfo(res);
        q_script(one, ok2, 2);
        assert(getaddrinfo("both.test", 0, &hints, &res) == 0 && res->ai_next == 0 && q_calls == 1);
        freeaddrinfo(res);
        hints.ai_flags = AI_V4MAPPED | AI_ALL;
        q_script(one, ok2, 2);
        assert(getaddrinfo("both.test", 0, &hints, &res) == 0 && res->ai_next && res->ai_next->ai_addr[19] == 0xff && q_calls == 2);
        freeaddrinfo(res);
        /* AF_INET: A only. */
        hints.ai_family = AF_INET;
        hints.ai_flags = 0;
        q_script(one, ok, 1);
        assert(getaddrinfo("v4.test", 0, &hints, &res) == 0 && strcmp(q_log, "v4.test@1/5;") == 0);
        freeaddrinfo(res);
        moqi_test_resolv_conf = (const char *)0;
    }

    /* hello526: IPv6 nameservers. They are kept with the IPv4 ones in file order, up to three (glibc res_init, measured); the kernel
     * gets the 16-byte address with bit 31 of the timeout set. ::, multicast and "%scope" lines are left out. */
    {
        struct resolv_server sv[3];
        static const char mix[] = "nameserver ::1\nnameserver 10.0.0.1\nnameserver 2001:db8::53 # x\nnameserver 10.0.0.2\n";
        assert(resolv_conf_servers_any(mix, sizeof mix - 1, sv, 3) == 3);
        assert(sv[0].v6 && sv[0].addr[15] == 1 && !sv[1].v6 && sv[1].addr[3] == 1 && sv[2].v6 && sv[2].addr[15] == 0x53);
        static const char odd[] = "nameserver ::\nnameserver ff02::1\nnameserver ff02::1%eth0\nnameserver 2001:db8::zz\nnameserver [::1]\n"
                                  "nameserver ::ffff:10.0.0.5\n";
        assert(resolv_conf_servers_any(odd, sizeof odd - 1, sv, 3) == 1 && sv[0].v6 && sv[0].addr[10] == 0xff && sv[0].addr[15] == 5);
        /* hello529: a "%scope" (glibc 2.44 res_init, measured). A link-local server keeps its slot either way; it needs the scope of
         * an interface, by name or number (digits only: no sign, no overflow; the name's case kept), else it is unusable. Any other
         * address ignores the suffix. The kernel gets the scope after the address, with bit 30 of the timeout set. */
        static const char sc[] = "nameserver fe80::53%eth0\nnameserver fe80::53%02\nnameserver ::1%bogus\n";
        assert(resolv_conf_servers_any(sc, sizeof sc - 1, sv, 3) == 3);
        assert(sv[0].v6 && sv[0].scope == 2 && !sv[0].unusable && sv[0].addr[0] == 0xfe && sv[0].addr[15] == 0x53);
        assert(sv[1].scope == 2 && !sv[1].unusable && sv[2].scope == 0 && !sv[2].unusable && sv[2].addr[15] == 1);
        static const char sc2[] = "nameserver fe80::53%lo\nnameserver fe80::53%99\nnameserver ff02::1%eth0\n";
        assert(resolv_conf_servers_any(sc2, sizeof sc2 - 1, sv, 3) == 2 && sv[0].scope == 1 && sv[1].scope == 99);
        static const char bad[] = "nameserver fe80::53\nnameserver fe80::53%bogus\nnameserver fe80::53%\nnameserver fe80::53%+2\n"
                                  "nameserver fe80::53%2x\nnameserver fe80::53%4294967296\nnameserver FE80::53%ETH0\n";
        size_t off = 0;
        for (int k = 0; k < 7; k++) {
            size_t e = off;
            while (bad[e] != '\n') e++;
            assert(resolv_conf_servers_any(bad + off, e - off + 1, sv, 3) == 1 && sv[0].v6 && sv[0].unusable);
            off = e + 1;
        }
        /* An unusable server is never asked and fails at once, like a server the kernel cannot reach (ENETUNREACH for a scope that
         * is not the NIC's): the next one is asked, and with none left the lookup is TRY_AGAIN. Three of them fill the list. */
        {
            static const char c1[] = "nameserver fe80::53\nnameserver 10.0.0.2\noptions attempts:1 timeout:2\n";
            static const char c2[] = "nameserver fe80::53%lo\nnameserver fe80::53%99\nnameserver fe80::53\nnameserver 10.0.0.2\n"
                                     "options attempts:1\n";
            static const char c3[] = "nameserver fe80::53%eth0\noptions attempts:1 timeout:2\n";
            static const long okr[] = {0}, unr[] = {-101, -101};
            uint8_t o4[4];
            q_script(c1, okr, 1);
            assert(gethostbyname_ipv4("x.y", o4) == 0 && strcmp(q_log, "x.y@2/2;") == 0);
            q_script(c2, unr, 2);
            assert(gethostbyname_ipv4("x.y", o4) == -110 && strcmp(q_log, "x.y@v3%1/5;x.y@v3%99/3;") == 0);
            q_script(c2, unr, 2);
            assert(!gethostbyname("x.y") && h_errno == TRY_AGAIN && q_calls == 2);
            q_script(c3, okr, 1);
            assert(gethostbyname_ipv4("x.y", o4) == 0 && strcmp(q_log, "x.y@v3%2/2;") == 0);
            q_script(c3, okr, 1);
            uint8_t pa4[4] = {10, 2, 3, 4};
            assert(gethostbyaddr(pa4, 4, AF_INET) && strcmp(q_log, "ptr2:4@v83%2;") == 0);
            static const char c4[] = "nameserver fe80::53\noptions attempts:1\n";
            q_script(c4, okr, 1);
            assert(!gethostbyaddr(pa4, 4, AF_INET) && h_errno == TRY_AGAIN && q_calls == 0);
        }
        /* The IPv4-only list is unchanged. */
        uint8_t n4[3][4];
        assert(resolv_conf_servers(mix, sizeof mix - 1, n4, 3) == 2 && n4[0][3] == 1 && n4[1][3] == 2);
        /* Queries go to the IPv6 server first, then the IPv4 one, with the usual waits; PTR the same. */
        static const char conf6[] = "nameserver ::1\nnameserver 10.0.0.2\noptions attempts:1 timeout:2\n";
        static const long t_ok[] = {-110, 0}, ok[] = {0};
        uint8_t a4[4];
        q_script(conf6, t_ok, 2);
        assert(gethostbyname_ipv4("x.y", a4) == 0 && strcmp(q_log, "x.y@v1/2;x.y@2/2;") == 0);
        q_script(conf6, ok, 1);
        uint8_t pa[4] = {10, 2, 3, 4};
        q_ptr_name = "p.test";
        assert(gethostbyaddr(pa, 4, AF_INET) && strcmp(q_log, "ptr2:4@v1;") == 0);
        q_ptr_name = "ptr.test";
        moqi_test_resolv_conf = (const char *)0;
    }

    /* hello521: reverse DNS. An address /etc/hosts does not name gets a PTR query (dns_ptr, 508) to the resolv.conf nameservers,
     * with their timeout and attempts; a mapped ::ffff:a.b.c.d asks the IPv4 name. h_errno and getnameinfo follow glibc. */
    {
        static const char one[] = "nameserver 10.0.0.1\noptions attempts:1\n";
        static const char two[] = "nameserver 10.0.0.1\nnameserver 10.0.0.2\noptions attempts:1\n";
        static const long ok[] = {0}, nx[] = {-2}, nd[] = {-61}, fe[] = {-71}, sf_ok[] = {-11, 0}, to[] = {-110};
        uint8_t a4[4] = {10, 2, 3, 4};
        uint8_t m6[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 2, 3, 9};
        uint8_t v6[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7};
        q_script(one, ok, 1);
        q_ptr_name = "host4.test";
        struct hostent *hp = gethostbyaddr(a4, 4, AF_INET);
        assert(hp && strcmp(hp->h_name, "host4.test") == 0 && hp->h_aliases[0] == 0 && (unsigned char)hp->h_addr_list[0][3] == 4);
        assert(strcmp(q_log, "ptr2:4@1;") == 0);
        q_script(one, ok, 1);
        hp = gethostbyaddr(m6, 16, AF_INET6);
        assert(hp && strcmp(hp->h_name, "host4.test") == 0 && hp->h_addrtype == AF_INET && hp->h_length == 4 && (unsigned char)hp->h_addr_list[0][3] == 9);
        assert(strcmp(q_log, "ptr2:9@1;") == 0);
        q_script(one, ok, 1);
        q_ptr_name = "v6.test";
        hp = gethostbyaddr(v6, 16, AF_INET6);
        assert(hp && strcmp(hp->h_name, "v6.test") == 0 && strcmp(q_log, "ptr10:7@1;") == 0);
        q_script(two, sf_ok, 2);
        hp = gethostbyaddr(a4, 4, AF_INET);
        assert(hp && strcmp(q_log, "ptr2:4@1;ptr2:4@2;") == 0);
        q_script(one, nx, 1);
        assert(gethostbyaddr(a4, 4, AF_INET) == 0 && h_errno == HOST_NOT_FOUND);
        q_script(one, nd, 1);
        assert(gethostbyaddr(a4, 4, AF_INET) == 0 && h_errno == NO_DATA);
        q_script(one, fe, 1);
        assert(gethostbyaddr(a4, 4, AF_INET) == 0 && h_errno == NO_RECOVERY);
        q_script(one, to, 1);
        assert(gethostbyaddr(a4, 4, AF_INET) == 0 && h_errno == TRY_AGAIN);
        /* No nameserver line: no query, HOST_NOT_FOUND as before. */
        q_script("search x.test\n", ok, 1);
        assert(gethostbyaddr(a4, 4, AF_INET) == 0 && h_errno == HOST_NOT_FOUND && q_calls == 0);
        /* getnameinfo: the PTR name; any failure is the numeric form, or EAI_NONAME with NI_NAMEREQD. */
        uint8_t sa[16] = {2, 0, 0, 80, 10, 2, 3, 4};
        char hb[64];
        q_script(one, ok, 1);
        q_ptr_name = "gni.test";
        assert(getnameinfo(sa, 16, hb, sizeof hb, 0, 0, 0) == 0 && strcmp(hb, "gni.test") == 0);
        q_script(one, nx, 1);
        assert(getnameinfo(sa, 16, hb, sizeof hb, 0, 0, 0) == 0 && strcmp(hb, "10.2.3.4") == 0);
        q_script(one, to, 1);
        assert(getnameinfo(sa, 16, hb, sizeof hb, 0, 0, NI_NAMEREQD) == EAI_AGAIN);
        q_script(one, to, 1);
        assert(getnameinfo(sa, 16, hb, sizeof hb, 0, 0, 0) == EAI_AGAIN);
        q_script(one, nx, 1);
        assert(getnameinfo(sa, 16, hb, sizeof hb, 0, 0, NI_NAMEREQD) == EAI_NONAME);
        q_script(one, ok, 1);
        assert(getnameinfo(sa, 16, hb, sizeof hb, 0, 0, NI_NUMERICHOST) == 0 && strcmp(hb, "10.2.3.4") == 0 && q_calls == 0);
        q_ptr_name = "ptr.test";
        moqi_test_resolv_conf = (const char *)0;
    }

    /* hello540: "options use-vc" (glibc 2.44, measured; any word starting with it, "use-v" is not it): every query is asked over
     * TCP only, without a UDP query first: bit 29 of the timeout argument of 507, 509, 510 and 508. */
    {
        static const char vc[] = "nameserver 10.0.0.1\noptions attempts:1 use-vc\n";
        static const char vcx[] = "nameserver 10.0.0.1\noptions attempts:1 timeout:3 use-vcx\n";
        static const char notvc[] = "nameserver 10.0.0.1\noptions attempts:1 use-v\n";
        static const long ok[] = {0}, ok2[] = {0, 0};
        uint8_t a4[4];
        q_script(vc, ok, 1);
        assert(gethostbyname_ipv4("v.test", a4) == 0 && strcmp(q_log, "v.test@1/5/tcp;") == 0);
        q_script(vcx, ok, 1);
        assert(gethostbyname_ipv4("v.test", a4) == 0 && strcmp(q_log, "v.test@1/3/tcp;") == 0);
        q_script(notvc, ok, 1);
        assert(gethostbyname_ipv4("v.test", a4) == 0 && strcmp(q_log, "v.test@1/5;") == 0);
        q_script(vc, ok, 1);
        assert(gethostbyname2("v.test", AF_INET6) && strcmp(q_log, "v.test/6@1/5/tcp;") == 0);
        struct addrinfo hints, *res = (struct addrinfo *)0;
        memset(&hints, 0, sizeof hints);
        hints.ai_socktype = SOCK_STREAM;
        q_script(vc, ok2, 2);
        assert(getaddrinfo("v.test", 0, &hints, &res) == 0 && strcmp(q_log, "v.test/2@1/5/tcp;") == 0);
        freeaddrinfo(res);
        /* hello543: with use-vc, single-request still asks the pair on one connection, both before any reply (glibc 2.44,
         * measured): one dns_query2 call. */
        q_script("nameserver 10.0.0.1\noptions attempts:1 use-vc single-request\n", ok2, 2);
        assert(getaddrinfo("v.test", 0, &hints, &res) == 0 && strcmp(q_log, "v.test/2@1/5/tcp;") == 0);
        freeaddrinfo(res);
        uint8_t pa[4] = {10, 2, 3, 4};
        q_script(vc, ok, 1);
        assert(gethostbyaddr(pa, 4, AF_INET) && strcmp(q_log, "ptr2:4@1/tcp;") == 0);
        moqi_test_resolv_conf = (const char *)0;
    }

    /* hello542: "options edns0" (glibc 2.44, measured; matched by its first 5 characters, "edns" is not it): every query carries
     * an OPT record: bit 28 of the timeout argument of 507, 509, 510 and 508, logged as "/e". */
    {
        static const char ed[] = "nameserver 10.0.0.1\noptions attempts:1 edns0\n";
        static const char edx[] = "nameserver 10.0.0.1\noptions attempts:1 timeout:3 edns0x\n";
        static const char noted[] = "nameserver 10.0.0.1\noptions attempts:1 edns\n";
        static const long ok[] = {0}, ok2[] = {0, 0};
        uint8_t a4[4];
        q_script(ed, ok, 1);
        assert(gethostbyname_ipv4("e.test", a4) == 0 && strcmp(q_log, "e.test@1/5/e;") == 0);
        q_script(edx, ok, 1);
        assert(gethostbyname_ipv4("e.test", a4) == 0 && strcmp(q_log, "e.test@1/3/e;") == 0);
        q_script(noted, ok, 1);
        assert(gethostbyname_ipv4("e.test", a4) == 0 && strcmp(q_log, "e.test@1/5;") == 0);
        q_script("nameserver 10.0.0.1\noptions attempts:1 edns0 use-vc\n", ok, 1);
        assert(gethostbyname_ipv4("e.test", a4) == 0 && strcmp(q_log, "e.test@1/5/tcp/e;") == 0);
        q_script(ed, ok, 1);
        assert(gethostbyname2("e.test", AF_INET6) && strcmp(q_log, "e.test/6@1/5/e;") == 0);
        struct addrinfo hints, *res = (struct addrinfo *)0;
        memset(&hints, 0, sizeof hints);
        hints.ai_socktype = SOCK_STREAM;
        q_script(ed, ok2, 2);
        assert(getaddrinfo("e.test", 0, &hints, &res) == 0 && strcmp(q_log, "e.test/2@1/5/e;") == 0);
        freeaddrinfo(res);
        q_script("nameserver 10.0.0.1\noptions attempts:1 edns0 single-request\n", ok2, 2);
        assert(getaddrinfo("e.test", 0, &hints, &res) == 0 && strcmp(q_log, "e.test@1/5/e;e.test/6@1/5/e;") == 0);
        freeaddrinfo(res);
        uint8_t pa[4] = {10, 2, 3, 4};
        q_script(ed, ok, 1);
        assert(gethostbyaddr(pa, 4, AF_INET) && strcmp(q_log, "ptr2:4@1/e;") == 0);
        moqi_test_resolv_conf = (const char *)0;
    }

    /* hello528: the "hosts:" line of /etc/nsswitch.conf (glibc 2.44, measured). */
    {
        struct nss_source s[NSS_HOSTS_MAX];
#define NSS(t) nsswitch_hosts((t), sizeof(t) - 1, s, NSS_HOSTS_MAX)
        const unsigned char ok_only = 1u << NSS_STATUS_SUCCESS;
        assert(nsswitch_hosts((const char *)0, 0, s, NSS_HOSTS_MAX) == 2 && s[0].service == NSS_SERVICE_FILES &&
               s[1].service == NSS_SERVICE_DNS && s[0].stop == ok_only && s[1].stop == ok_only);
        assert(NSS("passwd: files\n") == 2 && s[0].service == NSS_SERVICE_FILES);
        assert(NSS("hosts: dns files\n") == 2 && s[0].service == NSS_SERVICE_DNS && s[1].service == NSS_SERVICE_FILES);
        assert(NSS("hosts: files\n") == 1 && s[0].service == NSS_SERVICE_FILES);
        assert(NSS("hosts:dns") == 1 && s[0].service == NSS_SERVICE_DNS);
        assert(NSS(" hosts :\tdns  files # c\n") == 4 && s[0].service == NSS_SERVICE_DNS && s[2].service == NSS_SERVICE_OTHER);
        assert(NSS("Hosts: dns\n") == 2 && s[0].service == NSS_SERVICE_FILES); /* the keyword's case matters */
        assert(NSS("hosts: dns\nHosts: files\n") == 1 && s[0].service == NSS_SERVICE_DNS);
        assert(NSS("hosts: files dns#c\n") == 2 && s[1].service == NSS_SERVICE_OTHER);
        assert(NSS("hosts: DNS FILES\n") == 2 && s[0].service == NSS_SERVICE_OTHER && s[1].service == NSS_SERVICE_OTHER);
        assert(NSS("hosts: dns\n#hosts: files\n  # hosts: files\n") == 1 && s[0].service == NSS_SERVICE_DNS);
        assert(NSS("hosts: files\nhosts: dns\n") == 1 && s[0].service == NSS_SERVICE_DNS);
        /* glibc's process_line (glibc 2.44, measured): the database name ends at the first blank or colon, and any mix of
         * blanks and colons separates it from the sources, so "hosts files", "hosts::files" and "hosts : : dns files" are
         * hosts lines and a bare "hosts" is an empty one; ":files" (no name) and "hostsfiles" (another name) are not. */
        assert(NSS("hosts files\n") == 1 && s[0].service == NSS_SERVICE_FILES);
        assert(NSS("hosts\tfiles\n") == 1 && s[0].service == NSS_SERVICE_FILES);
        assert(NSS("hosts::files\n") == 1 && s[0].service == NSS_SERVICE_FILES);
        assert(NSS("hosts : : dns files\n") == 2 && s[0].service == NSS_SERVICE_DNS && s[1].service == NSS_SERVICE_FILES);
        assert(NSS("hosts: dns\nhosts files\n") == 1 && s[0].service == NSS_SERVICE_FILES);
        assert(NSS("hosts: files\nhosts\n") == 0);
        assert(NSS("hosts: files\nhosts   \n") == 0);
        assert(NSS("hosts: dns\n:files\n") == 1 && s[0].service == NSS_SERVICE_DNS);
        assert(NSS("hosts: dns\nhostsfiles\n") == 1 && s[0].service == NSS_SERVICE_DNS);
        assert(NSS("hosts: dns files\nhosts:\n") == 0);
        assert(NSS("hosts:   \n") == 0);
        assert(NSS("hosts: files [NOTFOUND=return] dns\n") == 2 && s[0].stop == (ok_only | 1u << NSS_STATUS_NOTFOUND) && s[1].stop == ok_only);
        assert(NSS("hosts: dns[ notfound = Return ] files\n") == 2 && s[0].stop == (ok_only | 1u << NSS_STATUS_NOTFOUND));
        /* A second "[" where a service name should be ends the list there. */
        assert(NSS("hosts: dns [NOTFOUND=return] [UNAVAIL=return] files\n") == 1 && s[0].stop == (ok_only | 1u << NSS_STATUS_NOTFOUND));
        assert(NSS("hosts: dns [UNAVAIL=return]files\n") == 2 && s[1].service == NSS_SERVICE_FILES);
        assert(NSS("hosts: dns [UNAVAIL=return]] files\n") == 3 && s[1].service == NSS_SERVICE_OTHER);
        assert(NSS("hosts: dns [] files\n") == 0 && NSS("hosts: dns [UNAVAIL=]\n") == 0 && NSS("hosts: dns [UNAVAIL return] files\n") == 0);
        assert(NSS("hosts: dns [UNAVAIL=return SUCCESS]\n") == 0 && NSS("hosts: dns [NOTFOUND=return UNAVAIL=return] files\n") == 2);
        assert(NSS("hosts: dns [!UNAVAIL=return] files\n") == 2 &&
               s[0].stop == (ok_only | 1u << NSS_STATUS_NOTFOUND | 1u << NSS_STATUS_TRYAGAIN));
        assert(NSS("hosts: files [SUCCESS=continue] dns\n") == 2 && s[0].stop == 0);
        assert(NSS("hosts: dns [SUCCESS=return NOTFOUND=continue] files\n") == 2 && s[0].stop == ok_only);
        assert(NSS("hosts: dns [NOTFOUND=merge] files\n") == 2 && s[0].stop == ok_only);
        assert(NSS("hosts: [NOTFOUND=return] dns files\n") == 0);
        assert(NSS("hosts: dns [NOTFOUND=foo] files\n") == 0);
        assert(NSS("hosts: files [FOO=return] dns\n") == 0);
        assert(NSS("hosts: files [NOTFOUND=return dns\n") == 0);
        assert(NSS("hosts: files files dns\n") == 3);
        assert(nsswitch_hosts("hosts: dns files", 10, s, NSS_HOSTS_MAX) == 1); /* only `len` bytes are read */
        assert(nsswitch_hosts("hosts: files dns", 16, s, 1) == 1 && s[0].service == NSS_SERVICE_FILES);
#undef NSS

        /* The lookups follow the line. */
        static const char one[] = "nameserver 10.0.0.1\noptions attempts:1\n";
        static const long ok[] = {0}, nx[] = {-2}, to[] = {-110}, fe[] = {-71}, sf[] = {-11};
        moqi_test_etc_hosts = "10.1.1.1 filehost.test fh\n10.2.3.4 filerev.test\n";
        struct hostent *hp;
        moqi_test_nsswitch_conf = "hosts: files dns\n";
        q_script(one, ok, 1);
        hp = gethostbyname("filehost.test");
        assert(hp && (unsigned char)hp->h_addr_list[0][3] == 1 && q_calls == 0);
        moqi_test_nsswitch_conf = "hosts: dns files\n";
        q_script(one, ok, 1);
        hp = gethostbyname("filehost.test");
        assert(hp && (unsigned char)hp->h_addr_list[0][0] == 10 && (unsigned char)hp->h_addr_list[0][3] == 1 && q_calls == 1);
        assert(strcmp(q_log, "filehost.test@1/5;") == 0 && hp->h_addr_list[0][1] == 0); /* 10.0.0.1 from the stub, not 10.1.1.1 */
        moqi_test_nsswitch_conf = "hosts: dns files\n";
        q_script(one, nx, 1);
        hp = gethostbyname("filehost.test");
        assert(hp && hp->h_addr_list[0][1] == 1 && q_calls == 1); /* NXDOMAIN, then the file */
        q_script(one, to, 1);
        hp = gethostbyname("nosuch.test");
        assert(!hp && h_errno == HOST_NOT_FOUND && q_calls == 1); /* the last source's status */
        moqi_test_nsswitch_conf = "hosts: dns [UNAVAIL=return] files\n";
        q_script(one, to, 1);
        assert(!gethostbyname("filehost.test") && h_errno == TRY_AGAIN);
        q_script(one, sf, 1);
        assert(!gethostbyname("filehost.test") && h_errno == TRY_AGAIN);
        q_script(one, fe, 1);
        assert(gethostbyname("filehost.test")); /* FORMERR is NOTFOUND */
        moqi_test_nsswitch_conf = "hosts: dns [NOTFOUND=return] files\n";
        q_script(one, nx, 1);
        assert(!gethostbyname("filehost.test") && h_errno == HOST_NOT_FOUND);
        q_script(one, to, 1);
        assert(gethostbyname("filehost.test")); /* a timeout is UNAVAIL */
        moqi_test_nsswitch_conf = "hosts: files\n";
        q_script(one, ok, 1);
        assert(!gethostbyname("a.test") && h_errno == HOST_NOT_FOUND && q_calls == 0);
        moqi_test_nsswitch_conf = "hosts: files [NOTFOUND=return] dns\n";
        q_script(one, ok, 1);
        assert(!gethostbyname("a.test") && h_errno == HOST_NOT_FOUND && q_calls == 0);
        moqi_test_nsswitch_conf = "hosts: files [SUCCESS=continue] dns\n";
        q_script(one, nx, 1);
        assert(!gethostbyname("filehost.test") && h_errno == HOST_NOT_FOUND && q_calls == 1);
        moqi_test_nsswitch_conf = "hosts:\n";
        q_script(one, ok, 1);
        assert(!gethostbyname("filehost.test") && h_errno == NETDB_INTERNAL && q_calls == 0);
        assert(gethostbyname("10.1.1.1")); /* a literal needs no source */
        moqi_test_nsswitch_conf = "hosts: bogus\n";
        assert(!gethostbyname("filehost.test") && h_errno == NETDB_INTERNAL);
        moqi_test_nsswitch_conf = "hosts: files bogus\n";
        assert(!gethostbyname("a.test") && h_errno == HOST_NOT_FOUND);
        {
            struct hostent he, *res = (struct hostent *)0;
            char buf[512];
            int herr = 0;
            moqi_test_nsswitch_conf = "hosts:\n";
            assert(gethostbyname_r("a.test", &he, buf, sizeof buf, &res, &herr) == 0 && !res && herr == NETDB_INTERNAL);
        }

        /* getaddrinfo: the last source's code; an unknown service last is EAI_SYSTEM. */
        struct addrinfo hints, *res = (struct addrinfo *)0;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        moqi_test_nsswitch_conf = "hosts: dns files\n";
        q_script(one, ok, 1);
        assert(getaddrinfo("filehost.test", 0, &hints, &res) == 0 && ((unsigned char *)res->ai_addr)[5] == 0 && q_calls == 1);
        freeaddrinfo(res);
        q_script(one, nx, 1);
        assert(getaddrinfo("filehost.test", 0, &hints, &res) == 0 && ((unsigned char *)res->ai_addr)[5] == 1);
        freeaddrinfo(res);
        q_script(one, to, 1);
        assert(getaddrinfo("nosuch.test", 0, &hints, &res) == EAI_NONAME);
        moqi_test_nsswitch_conf = "hosts: dns [UNAVAIL=return] files\n";
        q_script(one, to, 1);
        assert(getaddrinfo("filehost.test", 0, &hints, &res) == EAI_AGAIN);
        moqi_test_nsswitch_conf = "hosts: files\n";
        q_script(one, ok, 1);
        assert(getaddrinfo("a.test", 0, &hints, &res) == EAI_NONAME && q_calls == 0);
        moqi_test_nsswitch_conf = "hosts: files dns bogus\n";
        q_script(one, nx, 1);
        assert(getaddrinfo("nosuch.test", 0, &hints, &res) == EAI_SYSTEM);
        moqi_test_nsswitch_conf = "hosts: files bogus dns\n";
        q_script(one, nx, 1);
        assert(getaddrinfo("nosuch.test", 0, &hints, &res) == EAI_NONAME);
        moqi_test_nsswitch_conf = "hosts:\n";
        q_script(one, ok, 1);
        assert(getaddrinfo("filehost.test", 0, &hints, &res) == EAI_SYSTEM && q_calls == 0);
        assert(getaddrinfo("10.1.1.1", 0, &hints, &res) == 0);
        freeaddrinfo(res);

        /* Reverse lookups: every DNS failure is NOTFOUND. */
        uint8_t r4[4] = {10, 2, 3, 4}, r9[4] = {10, 2, 3, 9};
        uint8_t sa4[16] = {2, 0, 0, 80, 10, 2, 3, 4};
        char hb[64];
        moqi_test_nsswitch_conf = "hosts: dns files\n";
        q_script(one, ok, 1);
        q_ptr_name = "host4.test";
        hp = gethostbyaddr(r4, 4, AF_INET);
        assert(hp && strcmp(hp->h_name, "host4.test") == 0 && q_calls == 1);
        moqi_test_nsswitch_conf = "hosts: files\n";
        q_script(one, ok, 1);
        assert(!gethostbyaddr(r9, 4, AF_INET) && h_errno == HOST_NOT_FOUND && q_calls == 0);
        hp = gethostbyaddr(r4, 4, AF_INET);
        assert(hp && strcmp(hp->h_name, "filerev.test") == 0);
        moqi_test_nsswitch_conf = "hosts: dns [NOTFOUND=return] files\n";
        q_script(one, to, 1);
        assert(!gethostbyaddr(r4, 4, AF_INET) && h_errno == TRY_AGAIN);
        moqi_test_nsswitch_conf = "hosts: dns [UNAVAIL=return] files\n";
        q_script(one, sf, 1);
        hp = gethostbyaddr(r4, 4, AF_INET);
        assert(hp && strcmp(hp->h_name, "filerev.test") == 0);
        moqi_test_nsswitch_conf = "hosts:\n";
        q_script(one, ok, 1);
        assert(!gethostbyaddr(r4, 4, AF_INET) && h_errno == NETDB_INTERNAL && q_calls == 0);
        assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, 0) == EAI_SYSTEM);
        moqi_test_nsswitch_conf = "hosts: dns\n";
        q_script(one, ok, 1);
        assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, 0) == 0 && strcmp(hb, "host4.test") == 0 && q_calls == 1);
        moqi_test_nsswitch_conf = "hosts: files\n";
        q_script(one, ok, 1);
        assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, 0) == 0 && strcmp(hb, "filerev.test") == 0 && q_calls == 0);
        sa4[7] = 9;
        assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, 0) == 0 && strcmp(hb, "10.2.3.9") == 0 && q_calls == 0);
        assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, NI_NAMEREQD) == EAI_NONAME);
        moqi_test_nsswitch_conf = "hosts: files bogus\n";
        assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, NI_NAMEREQD) == EAI_NONAME);
        moqi_test_nsswitch_conf = "hosts: files dns\n";
        q_script(one, to, 1);
        assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, 0) == EAI_AGAIN);
        {
            /* Without /etc/hosts the files source is UNAVAIL: when it decides, h_errno and *h_errnop are left as they were,
             * errno is ENOENT and the reentrant functions return it; an unknown source after it, or [UNAVAIL=return], changes
             * nothing (glibc 2.44, measured in a fresh process). An empty file is HOST_NOT_FOUND. */
            static const char *const confs[] = {"hosts: files\n", "hosts: files bogus\n", "hosts: bogus files\n",
                                                "hosts: files [UNAVAIL=return] dns\n"};
            const char *saved_hosts = moqi_test_etc_hosts;
            moqi_test_etc_hosts = (const char *)0;
            for (unsigned i = 0; i < sizeof confs / sizeof confs[0]; i++) {
                moqi_test_nsswitch_conf = confs[i];
                q_script(one, ok, 1);
                struct hostent he, *rp = (struct hostent *)1;
                char buf[512];
                int herr = 77;
                h_errno = 77; errno = 0;
                assert(!gethostbyaddr(r4, 4, AF_INET) && h_errno == 77 && errno == ENOENT);
                h_errno = 77; errno = 0;
                assert(!gethostbyname("a.test") && h_errno == 77 && errno == ENOENT);
                errno = 0;
                assert(gethostbyaddr_r(r4, 4, AF_INET, &he, buf, sizeof buf, &rp, &herr) == ENOENT && !rp && herr == 77 &&
                       errno == ENOENT);
                rp = (struct hostent *)1;
                assert(gethostbyname_r("a.test", &he, buf, sizeof buf, &rp, &herr) == ENOENT && !rp && herr == 77);
                sa4[7] = 4;
                assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, 0) == 0 && strcmp(hb, "10.2.3.4") == 0);
                assert(getnameinfo(sa4, 16, hb, sizeof hb, 0, 0, NI_NAMEREQD) == EAI_NONAME);
                assert(q_calls == 0);
            }
            moqi_test_nsswitch_conf = "hosts: files\n";
            moqi_test_etc_hosts = "";
            struct hostent he, *rp = (struct hostent *)1;
            char buf[512];
            int herr = 77;
            h_errno = 77;
            assert(!gethostbyaddr(r4, 4, AF_INET) && h_errno == HOST_NOT_FOUND);
            assert(gethostbyname_r("a.test", &he, buf, sizeof buf, &rp, &herr) == 0 && !rp && herr == HOST_NOT_FOUND);
            moqi_test_etc_hosts = saved_hosts;
        }
        {
            /* getaddrinfo when the files source decides without an /etc/hosts (glibc 2.44 getaddrinfo.c, measured in fresh
             * processes): the module leaves h_errno alone, so the code comes from the h_errno the call started with.
             * AF_INET without AI_CANONNAME (try_simple_gethostbyname): NETDB_INTERNAL is EAI_SYSTEM, TRY_AGAIN EAI_AGAIN,
             * anything else EAI_NODATA. AF_INET with AI_CANONNAME and AF_INET6 (gethosts): the same except that only NO_DATA
             * is EAI_NODATA and the rest EAI_NONAME. AF_UNSPEC (gethostbyname4_r answers NO_DATA): EAI_NODATA. errno is
             * ENOENT. An empty file is EAI_NONAME whatever h_errno was. */
            static const struct { int h0, family, flags, want; } rows[] = {
                {0, AF_INET, 0, EAI_NODATA},             {HOST_NOT_FOUND, AF_INET, 0, EAI_NODATA},
                {TRY_AGAIN, AF_INET, 0, EAI_AGAIN},      {NO_DATA, AF_INET, 0, EAI_NODATA},
                {NETDB_INTERNAL, AF_INET, 0, EAI_SYSTEM}, {0, AF_INET, AI_CANONNAME, EAI_NONAME},
                {TRY_AGAIN, AF_INET, AI_CANONNAME, EAI_AGAIN}, {NO_DATA, AF_INET, AI_CANONNAME, EAI_NODATA},
                {0, AF_INET6, 0, EAI_NONAME},            {HOST_NOT_FOUND, AF_INET6, 0, EAI_NONAME},
                {TRY_AGAIN, AF_INET6, 0, EAI_AGAIN},     {NO_DATA, AF_INET6, 0, EAI_NODATA},
                {NETDB_INTERNAL, AF_INET6, 0, EAI_SYSTEM}, {0, AF_INET6, AI_V4MAPPED, EAI_NONAME},
                {0, AF_UNSPEC, 0, EAI_NODATA},           {TRY_AGAIN, AF_UNSPEC, 0, EAI_NODATA},
                {NETDB_INTERNAL, AF_UNSPEC, 0, EAI_NODATA},
            };
            const char *saved_hosts = moqi_test_etc_hosts;
            moqi_test_etc_hosts = (const char *)0;
            moqi_test_nsswitch_conf = "hosts: files\n";
            for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++) {
                struct addrinfo h, *r = (struct addrinfo *)0;
                memset(&h, 0, sizeof h);
                h.ai_family = rows[i].family;
                h.ai_flags = rows[i].flags;
                q_script(one, ok, 1);
                h_errno = rows[i].h0;
                errno = 0;
                assert(getaddrinfo("a.test", 0, &h, &r) == rows[i].want && errno == ENOENT && q_calls == 0);
            }
            moqi_test_nsswitch_conf = "hosts: files [UNAVAIL=return] dns\n";
            {
                struct addrinfo h, *r = (struct addrinfo *)0;
                memset(&h, 0, sizeof h);
                h.ai_family = AF_INET6;
                q_script(one, ok, 1);
                h_errno = 0;
                assert(getaddrinfo("a.test", 0, &h, &r) == EAI_NONAME && q_calls == 0);
            }
            {
                /* The whole of /etc/nsswitch.conf is read, however long (glibc 2.44, measured with 100000 bytes): the last
                 * hosts line decides even past the first 2048 bytes, and a line longer than the line buffer does not hide the
                 * next one. A last line without its newline is ignored (glibc's getline loop stops at end of file). */
                static char big[9000];
                size_t o = 0;
                memcpy(big + o, "hosts:\n", 7);
                o += 7;
                while (o < 5000) {
                    memcpy(big + o, "# padding padding padding padding paddi\n", 40);
                    o += 40;
                }
                big[o++] = '#';
                while (o < 8000) big[o++] = 'x';
                big[o++] = '\n';
                memcpy(big + o, "hosts: files\n", 13);
                o += 13;
                big[o] = 0;
                const char *hosts_was = moqi_test_etc_hosts;
                moqi_test_etc_hosts = "10.5.34.1 late534.test\n";
                moqi_test_nsswitch_conf = big;
                q_script(one, ok, 1);
                struct hostent *lp = gethostbyname("late534.test");
                assert(lp && (unsigned char)lp->h_addr_list[0][3] == 1 && q_calls == 0);
                memcpy(big + o, "hosts:", 7);
                lp = gethostbyname("late534.test");
                assert(lp && q_calls == 0);
                memcpy(big + o, "hosts:\n", 8);
                h_errno = 0;
                assert(!gethostbyname("late534.test") && h_errno == NETDB_INTERNAL);
                moqi_test_nsswitch_conf = "hosts: dns";
                q_script(one, ok, 1);
                lp = gethostbyname("late534.test");
                assert(lp && (unsigned char)lp->h_addr_list[0][3] == 1 && q_calls == 0); /* no complete line: "files dns" */
                /* A line whose sources do not parse voids the whole file, whatever database it names and wherever it is
                 * (glibc 2.44 nss_database_reload_1 stops at the first __nss_action_parse failure and keeps no services):
                 * every lookup is then NETDB_INTERNAL with errno EINVAL, getaddrinfo and getnameinfo EAI_SYSTEM, and no
                 * source is asked. A database glibc does not know (sudoers, automount) and a comment are skipped. */
                static const char *const voids[] = {
                    "hosts: files\npasswd: files [\n", "passwd: files [\nhosts: files\n", "hosts: files\ngroup: x [FOO=bar]\n",
                    "hosts: files\nservices: files [\n", "hosts: files\nshadow: files [UNAVAIL=return\n",
                    "hosts: files\naliases: files [NOTFOUND=foo]\n", "hosts: dns []\nhosts: files\n",
                    "hosts: files\n  passwd : files [\n", "group_compat: x [\n", "hosts: dns\npasswd files [\n",
                };
                for (unsigned v = 0; v < sizeof voids / sizeof voids[0]; v++) {
                    moqi_test_nsswitch_conf = voids[v];
                    q_script(one, ok, 1);
                    struct hostent hv, *rv = (struct hostent *)1;
                    char bv[512];
                    int hv_err = 0;
                    uint8_t lateaddr[4] = {10, 5, 34, 1};
                    h_errno = 0;
                    errno = 0;
                    assert(!gethostbyname("late534.test") && h_errno == NETDB_INTERNAL && errno == EINVAL);
                    h_errno = 0;
                    errno = 0;
                    assert(!gethostbyaddr(lateaddr, 4, AF_INET) && h_errno == NETDB_INTERNAL && errno == EINVAL);
                    errno = 0;
                    assert(gethostbyname_r("late534.test", &hv, bv, sizeof bv, &rv, &hv_err) == EINVAL && !rv &&
                           hv_err == NETDB_INTERNAL);
                    struct addrinfo hints4, *r4 = (struct addrinfo *)0;
                    memset(&hints4, 0, sizeof hints4);
                    hints4.ai_family = AF_INET;
                    errno = 0;
                    h_errno = 0;
                    assert(getaddrinfo("late534.test", 0, &hints4, &r4) == EAI_SYSTEM && errno == EINVAL && h_errno == NETDB_INTERNAL);
                    /* Only AF_INET without AI_CANONNAME (try_simple_gethostbyname) sees gethostbyname2_r's EINVAL; the other
                     * requests find no service through get_nss_addresses and are EAI_NONAME with errno ENOENT. */
                    static const int other[][2] = {{AF_INET, AI_CANONNAME}, {AF_INET6, 0}, {AF_UNSPEC, 0}};
                    for (unsigned k = 0; k < 3; k++) {
                        struct addrinfo ho, *ro = (struct addrinfo *)0;
                        memset(&ho, 0, sizeof ho);
                        ho.ai_family = other[k][0];
                        ho.ai_flags = other[k][1];
                        errno = 0;
                        h_errno = 0;
                        assert(getaddrinfo("late534.test", 0, &ho, &ro) == EAI_NONAME && errno == ENOENT && h_errno == 0);
                        errno = 0;
                        h_errno = NETDB_INTERNAL; /* left by an earlier call: glibc maps it to EAI_SYSTEM */
                        assert(getaddrinfo("late534.test", 0, &ho, &ro) == EAI_SYSTEM && errno == ENOENT);
                    }
                    uint8_t sal[16] = {2, 0, 0, 80, 10, 5, 34, 1};
                    char hbuf[64];
                    assert(getnameinfo(sal, 16, hbuf, sizeof hbuf, 0, 0, 0) == EAI_SYSTEM);
                    assert(q_calls == 0);
                }
                /* Read from the file, "hosts files" is a hosts line and a bare "hosts" an empty one (no source: nothing is
                 * asked and the lookup fails), not a missing line that would mean "files dns". */
                moqi_test_nsswitch_conf = "hosts: dns\nhosts files\n";
                q_script(one, ok, 1);
                lp = gethostbyname("late534.test");
                assert(lp && (unsigned char)lp->h_addr_list[0][3] == 1 && q_calls == 0);
                moqi_test_nsswitch_conf = "hosts: files\nhosts\n";
                q_script(one, ok, 1);
                assert(!gethostbyname("late534.test") && q_calls == 0);
                {
                    /* A line has no length limit (glibc 2.44 getline, measured): "files" after 2000 blanks on the last hosts
                     * line is a source, and an action that does not parse 5000 bytes into a passwd line still voids the file. */
                    static char longl[8000];
                    size_t lo = 0;
                    memcpy(longl, "hosts: dns\nhosts:", 17);
                    lo = 17;
                    while (lo < 17 + 2000) longl[lo++] = ' ';
                    memcpy(longl + lo, "files\n", 7);
                    moqi_test_nsswitch_conf = longl;
                    q_script(one, ok, 1);
                    lp = gethostbyname("late534.test");
                    assert(lp && (unsigned char)lp->h_addr_list[0][3] == 1 && q_calls == 0);
                    memcpy(longl, "hosts: files\npasswd: files", 26);
                    lo = 26;
                    while (lo < 26 + 5000) longl[lo++] = ' ';
                    memcpy(longl + lo, "[NOTFOUND=foo]\n", 16);
                    q_script(one, ok, 1);
                    h_errno = 0;
                    errno = 0;
                    assert(!gethostbyname("late534.test") && h_errno == NETDB_INTERNAL && errno == EINVAL && q_calls == 0);
                    /* A hosts line has no limit on its sources either (glibc 2.44, measured): "files" after twelve unknown
                     * sources still answers, and twelve DNS sources are all asked before [UNAVAIL=return] on the last ends it. */
                    static const char many_other[] = "hosts: bogus bogus bogus bogus bogus bogus bogus bogus bogus bogus bogus bogus files\n";
                    moqi_test_nsswitch_conf = many_other;
                    q_script(one, ok, 1);
                    lp = gethostbyname("late534.test");
                    assert(lp && (unsigned char)lp->h_addr_list[0][3] == 1 && q_calls == 0);
                    {
                        struct addrinfo h, *r = (struct addrinfo *)0;
                        memset(&h, 0, sizeof h);
                        h.ai_family = AF_INET;
                        q_script(one, ok, 1);
                        assert(getaddrinfo("late534.test", 0, &h, &r) == 0 && r && q_calls == 0);
                        freeaddrinfo(r);
                    }
                    static const char many_dns[] = "hosts: dns dns dns dns dns dns dns dns dns dns dns dns [UNAVAIL=return] files\n";
                    static const long twelve_to[] = {-110, -110, -110, -110, -110, -110, -110, -110, -110, -110, -110, -110, 0};
                    moqi_test_nsswitch_conf = many_dns;
                    q_script(one, twelve_to, 13);
                    h_errno = 0;
                    assert(!gethostbyname("late534.test") && h_errno == TRY_AGAIN && q_calls == 12);
                }
                /* Unknown databases and comments do not void it. */
                static const char *const kept[] = {"hosts: files\nsudoers: files [\n", "hosts: files\nautomount: x [\n",
                                                   "hosts: files\nunknowndb: x [\n", "hosts: files\n#passwd: files [\n",
                                                   "hosts: files\npasswd:\n"};
                for (unsigned v = 0; v < sizeof kept / sizeof kept[0]; v++) {
                    moqi_test_nsswitch_conf = kept[v];
                    q_script(one, ok, 1);
                    lp = gethostbyname("late534.test");
                    assert(lp && (unsigned char)lp->h_addr_list[0][3] == 1 && q_calls == 0);
                }
                moqi_test_etc_hosts = hosts_was;
            }
            moqi_test_nsswitch_conf = "hosts: files\n";
            moqi_test_etc_hosts = "";
            {
                struct addrinfo h, *r = (struct addrinfo *)0;
                memset(&h, 0, sizeof h);
                h.ai_family = AF_INET;
                h_errno = TRY_AGAIN;
                assert(getaddrinfo("a.test", 0, &h, &r) == EAI_NONAME);
            }
            moqi_test_etc_hosts = saved_hosts;
        }
        q_ptr_name = "ptr.test";
        moqi_test_nsswitch_conf = (const char *)0;
        moqi_test_etc_hosts = (const char *)0;
        moqi_test_resolv_conf = (const char *)0;
    }

    /* A NULL name or output never reaches the kernel: the wrapper refuses it first with EINVAL. */
    moqi_test_last_nr = 0;
    assert(gethostbyname_ipv4((const char *)0, ip) == -22);
    assert(gethostbyname_ipv4("localhost", (uint8_t *)0) == -22);
    assert(moqi_test_last_nr == 0);

    /* Formatting helper: "a.b.c.d" for logs and for sockaddr_in construction by callers. */
    char text[16];
    uint8_t addr[4] = {192, 168, 7, 9};
    assert(ipv4_to_text(addr, text, sizeof(text)) == 11);
    assert(strcmp(text, "192.168.7.9") == 0);
    uint8_t zero[4] = {0, 0, 0, 0};
    assert(ipv4_to_text(zero, text, sizeof(text)) == 7);
    assert(strcmp(text, "0.0.0.0") == 0);
    uint8_t full[4] = {255, 255, 255, 255};
    assert(ipv4_to_text(full, text, sizeof(text)) == 15);
    assert(strcmp(text, "255.255.255.255") == 0);
    uint8_t mixed[4] = {10, 0, 100, 2};
    assert(ipv4_to_text(mixed, text, sizeof(text)) == 10);
    assert(strcmp(text, "10.0.100.2") == 0);
    /* A buffer that cannot hold the text plus its NUL is refused and written not at all. */
    char small[8] = {'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x'};
    assert(ipv4_to_text(full, small, sizeof(small)) == -34); /* ERANGE */
    assert(small[0] == 'x');
    /* The boundary exactly: "192.168.7.9" is 11 bytes, so 12 fit (with the NUL) and 11 do not. */
    char edge[12];
    for (int i = 0; i < 12; i++) edge[i] = 'x';
    assert(ipv4_to_text(addr, edge, 11) == -34);
    assert(edge[0] == 'x' && edge[10] == 'x');
    assert(ipv4_to_text(addr, edge, 12) == 11);
    assert(edge[11] == 0 && edge[10] == '9');
    assert(ipv4_to_text(addr, edge, 0) == -34);

    /* Parsing helper: inet_pton(AF_INET) semantics, checked against glibc. Strict dotted decimal, exactly four
     * fields, 0..255, no leading zeros, no whitespace, no trailing junk. 1 = parsed, 0 = not an address. */
    static const struct { const char *text; int ok; uint8_t v[4]; } cases[] = {
        {"1.2.3.4", 1, {1, 2, 3, 4}}, {"0.0.0.0", 1, {0, 0, 0, 0}}, {"255.255.255.255", 1, {255, 255, 255, 255}},
        {"1.2.3.0", 1, {1, 2, 3, 0}}, {"1.2.3.255", 1, {1, 2, 3, 255}}, {"10.0.2.15", 1, {10, 0, 2, 15}},
        {"256.1.1.1", 0, {0}}, {"1.2.3", 0, {0}}, {"1.2.3.4.5", 0, {0}}, {"01.2.3.4", 0, {0}},
        {"1.2.3.04", 0, {0}}, {"1..2.3", 0, {0}}, {"1.2.3.", 0, {0}}, {"", 0, {0}}, {".1.2.3", 0, {0}},
        {"1.2.3.4 ", 0, {0}}, {" 1.2.3.4", 0, {0}}, {"1.2.3.-4", 0, {0}}, {"a.b.c.d", 0, {0}},
        {"0x1.2.3.4", 0, {0}}, {"1.2.3.4\n", 0, {0}}, {"00.0.0.0", 0, {0}}, {"0.0.0.00", 0, {0}},
        {"1.2.3.1000", 0, {0}}, {"999.0.0.0", 0, {0}}, {"1.2.3.256", 0, {0}}, {"192.168.001.1", 0, {0}},
    };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        uint8_t got[4] = {0xAA, 0xAA, 0xAA, 0xAA};
        int r = ipv4_from_text(cases[i].text, got);
        assert(r == cases[i].ok);
        if (cases[i].ok) {
            assert(memcmp(got, cases[i].v, 4) == 0);
        } else {
            /* A failed parse leaves the output untouched. */
            assert(got[0] == 0xAA && got[1] == 0xAA && got[2] == 0xAA && got[3] == 0xAA);
        }
    }
    assert(ipv4_from_text((const char *)0, ip) == 0);
    assert(ipv4_from_text("1.2.3.4", (uint8_t *)0) == 0);

    /* inet_pton(AF_INET6) semantics; every expected value below is glibc's inet_pton output for the same text. */
    {
        static const struct { const char *text; int ok; uint8_t v[16]; } cases6[] = {
        {"::", 1, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"::1", 1, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}},
        {"1::", 1, {0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"2001:db8::6", 1, {32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6}},
        {"2001:DB8:0:0:0:0:0:1", 1, {32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}},
        {"1:2:3:4:5:6:7:8", 1, {0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8}},
        {"1:2:3:4:5:6:7::", 1, {0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 0}},
        {"::2:3:4:5:6:7:8", 1, {0, 0, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8}},
        {"1:2:3:4:5:6:7:8:9", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"1::2::3", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {":1::", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {":::", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"1:::2", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"12345::", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"fffff::", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"g::", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"::ffff:1.2.3.4", 1, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 1, 2, 3, 4}},
        {"::1.2.3.4", 1, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4}},
        {"1:2:3:4:5:6:1.2.3.4", 1, {0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 1, 2, 3, 4}},
        {"1:2:3:4:5:6:7:1.2.3.4", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"::ffff:1.2.3", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"::ffff:01.2.3.4", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"::1.2.3.4:5", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"1::2:3:4:5:6:7", 1, {0, 1, 0, 0, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7}},
        {"1:2:3:4:5:6:7", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"1:", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"::1 ", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"0000:0000::00001", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"0:0::0001", 1, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}},
        {"fe80::1%lo", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {"::ffff:256.1.1.1", 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        };
        for (unsigned i = 0; i < sizeof(cases6) / sizeof(cases6[0]); i++) {
            uint8_t got[16];
            memset(got, 0xAA, sizeof got);
            int r = ipv6_from_text(cases6[i].text, got);
            assert(r == cases6[i].ok);
            if (r) assert(memcmp(got, cases6[i].v, 16) == 0);
            else for (int k = 0; k < 16; k++) assert(got[k] == 0xAA);
        }
        /* inet_ntop(AF_INET6): every expected text is glibc's for the same bytes. */
        static const struct { uint8_t v[16]; const char *text; } ntop[] = {
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "::"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}, "::1"},
        {{0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "1::"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2}, "::2"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}, "::1"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4}, "::1.2.3.4"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 1, 2, 3, 4}, "::ffff:1.2.3.4"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 1, 2, 3, 4}, "::ffff:0:102:304"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0}, "::1:0:0"},
        {{0, 1, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3}, "1:0:0:2::3"},
        {{0, 1, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 3, 0, 4}, "1::2:0:0:3:4"},
        {{0, 1, 0, 0, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7}, "1:0:2:3:4:5:6:7"},
        {{0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 0}, "1:2:3:4:5:6:7:0"},
        {{0, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7}, "0:1:2:3:4:5:6:7"},
        {{32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::1"},
        {{32, 1, 13, 184, 171, 205, 0, 18, 0, 0, 0, 0, 0, 0, 0, 255}, "2001:db8:abcd:12::ff"},
        {{254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}, "fe80::1"},
        {{0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8}, "1:2:3:4:5:6:7:8"},
        {{0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "0:0:1::"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 254, 1, 2, 3, 4}, "::fffe:102:304"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0}, "::1:0:0:0"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0}, "::ffff:0.0.0.0"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0}, "::ffff:0.0.0.0"},
        {{0, 100, 255, 155, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4}, "64:ff9b::102:304"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0}, "::1.0.0.0"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1}, "::1.0.0.1"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255}, "::ffff"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0}, "::0.1.0.0"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0}, "::100"},
        {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 1}, "::ffff:0.0.0.1"},
        };
        for (unsigned i = 0; i < sizeof(ntop) / sizeof(ntop[0]); i++) {
            char t[46];
            long n = ipv6_to_text(ntop[i].v, t, sizeof t);
            assert(n == (long)strlen(ntop[i].text) && strcmp(t, ntop[i].text) == 0);
        }
        {
            /* "2001:db8::1" is 11 characters: 12 bytes fit, 11 is -ERANGE and leaves the buffer alone (glibc NULL for <= 11). */
            static const uint8_t d[16] = {32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
            char t[16];
            memset(t, 'X', sizeof t);
            assert(ipv6_to_text(d, t, 11) == -34 && t[0] == 'X');
            assert(ipv6_to_text(d, t, 12) == 11 && strcmp(t, "2001:db8::1") == 0);
        }
        uint8_t six[16];
        assert(ipv6_from_text((const char *)0, six) == 0);
        /* Edges also measured on glibc: "::" must stand for at least one zero group, a dotted quad needs the 96 bits before it. */
        assert(ipv6_from_text("1::2:3:4:5:6:7:8", six) == 0);
        assert(ipv6_from_text("::1:2:3:4:5:6:7", six) == 1 && six[0] == 0 && six[1] == 0 && six[15] == 7);
        assert(ipv6_from_text("1:2:3:4:5:6::1.2.3.4", six) == 0);
        assert(ipv6_from_text("::1.2.3.4.5", six) == 0);
        assert(ipv6_from_text("1.2.3.4", six) == 0);
        assert(ipv6_from_text("::1", (uint8_t *)0) == 0);
    }

    /* sockaddr_in builder: Linux layout, 16 bytes: family (u16 little-endian) = AF_INET, port in network byte
     * order, 4 address bytes, 8 zero bytes. */
    uint8_t sa[16];
    for (int i = 0; i < 16; i++) sa[i] = 0xEE;
    uint8_t sip[4] = {10, 0, 2, 2};
    ipv4_sockaddr(sip, 8080, sa);
    static const uint8_t want_sa[16] = {2, 0, 0x1F, 0x90, 10, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(memcmp(sa, want_sa, 16) == 0);
    ipv4_sockaddr(sip, 0, sa);
    assert(sa[2] == 0 && sa[3] == 0);
    ipv4_sockaddr(sip, 65535, sa);
    assert(sa[2] == 0xFF && sa[3] == 0xFF);
    ipv4_sockaddr(sip, 80, sa);
    assert(sa[2] == 0 && sa[3] == 80);
    ipv4_sockaddr(sip, 0x1234, sa);
    assert(sa[2] == 0x12 && sa[3] == 0x34);

    /* resolve_ipv4_sockaddr: a dotted-decimal host never reaches the kernel; any other host goes through
     * dns_resolve; failures are -errno from the kernel, or -EINVAL for NULL arguments. */
    for (int i = 0; i < 16; i++) sa[i] = 0xEE;
    moqi_test_last_nr = 0;
    assert(resolve_ipv4_sockaddr("192.168.7.9", 443, sa) == 0);
    assert(moqi_test_last_nr == 0);
    static const uint8_t want_num[16] = {2, 0, 0x01, 0xBB, 192, 168, 7, 9, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(memcmp(sa, want_num, 16) == 0);

    moqi_test_reply = 0;
    moqi_test_fill[0] = 1; moqi_test_fill[1] = 2; moqi_test_fill[2] = 3; moqi_test_fill[3] = 4;
    assert(resolve_ipv4_sockaddr("example.com", 53, sa) == 0);
    assert(moqi_test_last_nr == 495);
    static const uint8_t want_dns[16] = {2, 0, 0, 53, 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(memcmp(sa, want_dns, 16) == 0);

    /* A dotted-looking but invalid literal is NOT a number, so it is looked up as a name (and the kernel rejects
     * or resolves it); the helper does not guess. */
    moqi_test_last_nr = 0;
    moqi_test_reply = -22;
    for (int i = 0; i < 16; i++) sa[i] = 0xEE;
    assert(resolve_ipv4_sockaddr("1.2.3.256", 80, sa) == -22);
    assert(moqi_test_last_nr == 495);
    assert(sa[0] == 0xEE && sa[15] == 0xEE); /* output untouched on failure */
    moqi_test_reply = -2;
    assert(resolve_ipv4_sockaddr("nope.invalid", 80, sa) == -2);
    assert(sa[0] == 0xEE);
    assert(resolve_ipv4_sockaddr((const char *)0, 80, sa) == -22);
    assert(resolve_ipv4_sockaddr("localhost", 80, (uint8_t *)0) == -22);

    /* tcp_connect_host(): resolves, opens a stream socket, connects, and returns the descriptor. */
    stub_reset();
    moqi_test_last_nr = 0;
    assert(tcp_connect_host("10.1.2.3", 8080) == 7);
    assert(stub_count(SYS_socket) == 1 && stub_count(SYS_connect) == 1);
    assert(stub_count(SYS_dns_resolve) == 0 && moqi_test_last_nr == 0); /* a literal never reaches the resolver */
    assert(stub_count(SYS_close) == 0);

    /* A name goes through dns_resolve first (the 2-argument stub), then the socket calls. */
    stub_reset();
    moqi_test_reply = 0;
    moqi_test_fill[0] = 1; moqi_test_fill[1] = 2; moqi_test_fill[2] = 3; moqi_test_fill[3] = 4;
    assert(tcp_connect_host("example.com", 80) == 7);
    assert(moqi_test_last_nr == 495 && stub_count(SYS_socket) == 1 && stub_count(SYS_connect) == 1);

    /* A failed lookup stops before any socket exists. */
    stub_reset();
    moqi_test_reply = -2;
    assert(tcp_connect_host("nope.invalid", 80) == -2);
    assert(stub_count(SYS_socket) == 0 && stub_count(SYS_connect) == 0);
    moqi_test_reply = 0;

    /* NULL host is EINVAL without touching the socket layer. */
    stub_reset();
    assert(tcp_connect_host((const char *)0, 80) == -22);
    assert(stub_log_n == 0);

    /* socket() failing is returned as is, and nothing is connected or closed. */
    stub_reset();
    stub_socket_reply = -24; /* EMFILE */
    assert(tcp_connect_host("10.1.2.3", 80) == -24);
    assert(stub_count(SYS_connect) == 0 && stub_count(SYS_close) == 0);

    /* An in-progress connect is retried (with a netpoll between tries) until it succeeds. */
    stub_reset();
    stub_connect_n = 3;
    stub_connect_replies[0] = -115; stub_connect_replies[1] = -115; stub_connect_replies[2] = 0;
    assert(tcp_connect_host("10.1.2.3", 80) == 7);
    assert(stub_count(SYS_connect) == 3 && stub_count(SYS_netpoll) == 2 && stub_count(SYS_close) == 0);

    /* EISCONN on a retry means the earlier attempt completed. */
    stub_reset();
    stub_connect_n = 2;
    stub_connect_replies[0] = -115; stub_connect_replies[1] = -106;
    assert(tcp_connect_host("10.1.2.3", 80) == 7);
    assert(stub_count(SYS_close) == 0);

    /* A connect that never succeeds is bounded, reports the error, and closes the socket (no leak). */
    stub_reset();
    stub_connect_n = 1;
    stub_connect_replies[0] = -111; /* ECONNREFUSED */
    assert(tcp_connect_host("10.1.2.3", 80) == -111);
    assert(stub_count(SYS_connect) == 21 && stub_count(SYS_close) == 1); /* 1 try + 20 retries */

    /* gethostbyname(): a glibc-compatible struct hostent over the IPv4 resolver. Layout and results measured with
     * glibc: 32 bytes, h_name 0, h_aliases 8, h_addrtype 16, h_length 20, h_addr_list 24. */
    assert(sizeof(struct hostent) == 32);
    assert(offsetof(struct hostent, h_name) == 0 && offsetof(struct hostent, h_aliases) == 8);
    assert(offsetof(struct hostent, h_addrtype) == 16 && offsetof(struct hostent, h_length) == 20);
    assert(offsetof(struct hostent, h_addr_list) == 24);
    assert(AF_INET == 2 && HOST_NOT_FOUND == 1 && TRY_AGAIN == 2 && NO_RECOVERY == 3 && NO_DATA == 4);

    /* A dotted-decimal literal: the name is the literal, one address, no aliases, no lookup. */
    stub_reset();
    moqi_test_last_nr = 0;
    struct hostent *he = gethostbyname("1.2.3.4");
    assert(he != (struct hostent *)0 && moqi_test_last_nr == 0);
    assert(strcmp(he->h_name, "1.2.3.4") == 0 && he->h_addrtype == 2 && he->h_length == 4);
    assert(he->h_aliases != (char **)0 && he->h_aliases[0] == (char *)0);
    assert(he->h_addr_list[0] != (char *)0 && he->h_addr_list[1] == (char *)0);
    assert((uint8_t)he->h_addr_list[0][0] == 1 && (uint8_t)he->h_addr_list[0][3] == 4);
    assert(he->h_addr == he->h_addr_list[0]);
    assert(h_errno == 0);

    /* A name goes through dns_resolve; h_name is the name asked for. */
    moqi_test_reply = 0;
    moqi_test_fill[0] = 10; moqi_test_fill[1] = 0; moqi_test_fill[2] = 2; moqi_test_fill[3] = 2;
    he = gethostbyname("gateway");
    assert(he != (struct hostent *)0 && moqi_test_last_nr == 495);
    assert(strcmp(he->h_name, "gateway") == 0 && (uint8_t)he->h_addr_list[0][0] == 10 && (uint8_t)he->h_addr_list[0][3] == 2);

    /* The result lives in static storage, as in glibc: a second call reuses it. */
    struct hostent *first = gethostbyname("1.2.3.4");
    struct hostent *second = gethostbyname("5.6.7.8");
    assert(first == second && (uint8_t)second->h_addr_list[0][0] == 5);

    /* Failures return NULL and set h_errno. A name that does not exist, is malformed or is too long is
     * HOST_NOT_FOUND (glibc measured: "bad name!", "a..b", a 399-character name all give HOST_NOT_FOUND); a
     * timeout or any other failure is TRY_AGAIN. A NULL name makes glibc crash (SIGSEGV, measured); here it fails
     * cleanly with HOST_NOT_FOUND instead of faulting. */
    moqi_test_reply = -2;
    h_errno = 0;
    assert(gethostbyname("nope.invalid") == (struct hostent *)0 && h_errno == HOST_NOT_FOUND);
    moqi_test_reply = -22;
    h_errno = 0;
    assert(gethostbyname("bad name!") == (struct hostent *)0 && h_errno == HOST_NOT_FOUND);
    moqi_test_reply = -36; /* ENAMETOOLONG (Linux 36; -34 is ERANGE, which is a retry-worthy failure here) */
    h_errno = 0;
    assert(gethostbyname("x") == (struct hostent *)0 && h_errno == HOST_NOT_FOUND);
    moqi_test_reply = -34; /* ERANGE is not a "no such host" answer */
    h_errno = 0;
    assert(gethostbyname("x") == (struct hostent *)0 && h_errno == TRY_AGAIN);
    moqi_test_reply = -110; /* ETIMEDOUT: the server did not answer */
    h_errno = 0;
    assert(gethostbyname("slow.example") == (struct hostent *)0 && h_errno == TRY_AGAIN);
    moqi_test_reply = -5; /* EIO */
    h_errno = 0;
    assert(gethostbyname("broken.example") == (struct hostent *)0 && h_errno == TRY_AGAIN);
    moqi_test_reply = 0;
    h_errno = 0;
    assert(gethostbyname((const char *)0) == (struct hostent *)0 && h_errno == HOST_NOT_FOUND);
    /* A failed call does not clobber the previous successful result's contents beyond reuse: success resets h_errno. */
    h_errno = HOST_NOT_FOUND;
    assert(gethostbyname("9.9.9.9") != (struct hostent *)0 && h_errno == 0);

    /* getaddrinfo(): IPv4 only, glibc-measured behaviour. Layout: 48 bytes; flags 0, family 4, socktype 8,
     * protocol 12, addrlen 16, addr 24, canonname 32, next 40. */
    assert(sizeof(struct addrinfo) == 48);
    assert(offsetof(struct addrinfo, ai_flags) == 0 && offsetof(struct addrinfo, ai_family) == 4);
    assert(offsetof(struct addrinfo, ai_socktype) == 8 && offsetof(struct addrinfo, ai_protocol) == 12);
    assert(offsetof(struct addrinfo, ai_addrlen) == 16 && offsetof(struct addrinfo, ai_addr) == 24);
    assert(offsetof(struct addrinfo, ai_canonname) == 32 && offsetof(struct addrinfo, ai_next) == 40);
    assert(AI_PASSIVE == 1 && AI_CANONNAME == 2 && AI_NUMERICHOST == 4 && AI_NUMERICSERV == 1024);
    assert(EAI_BADFLAGS == -1 && EAI_NONAME == -2 && EAI_AGAIN == -3 && EAI_FAIL == -4 && EAI_FAMILY == -6);
    assert(EAI_SOCKTYPE == -7 && EAI_SERVICE == -8 && EAI_MEMORY == -10);
    assert(SOCK_STREAM == 1 && SOCK_DGRAM == 2 && SOCK_RAW == 3);
    assert(IPPROTO_TCP == 6 && IPPROTO_UDP == 17);

    struct addrinfo hints, *res;
    #define HINTS(fam, type, proto, fl) do { memset(&hints, 0, sizeof hints); hints.ai_family = (fam); \
        hints.ai_socktype = (type); hints.ai_protocol = (proto); hints.ai_flags = (fl); } while (0)
    #define SA(p) ((const uint8_t *)(p)->ai_addr)
    #define PORT(p) ((unsigned)(SA(p)[2] << 8 | SA(p)[3]))

    /* A literal with a stream socktype: one entry, TCP, port from the service, family 2, 16-byte sockaddr. */
    stub_reset();
    moqi_test_last_nr = 0;
    HINTS(AF_INET, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0 && res != (struct addrinfo *)0);
    assert(moqi_test_last_nr == 0); /* a literal never reaches the resolver */
    assert(res->ai_family == AF_INET && res->ai_socktype == SOCK_STREAM && res->ai_protocol == IPPROTO_TCP);
    assert(res->ai_addrlen == 16 && res->ai_canonname == (char *)0 && res->ai_next == (struct addrinfo *)0);
    assert(res->ai_flags == 0 && SA(res)[0] == 2 && SA(res)[1] == 0 && PORT(res) == 80);
    assert(SA(res)[4] == 1 && SA(res)[5] == 2 && SA(res)[6] == 3 && SA(res)[7] == 4);
    freeaddrinfo(res);

    /* No socktype: three entries in the order STREAM(6), DGRAM(17), RAW(0). */
    HINTS(AF_INET, 0, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0);
    assert(res->ai_socktype == SOCK_STREAM && res->ai_protocol == IPPROTO_TCP);
    assert(res->ai_next->ai_socktype == SOCK_DGRAM && res->ai_next->ai_protocol == IPPROTO_UDP);
    assert(res->ai_next->ai_next->ai_socktype == SOCK_RAW && res->ai_next->ai_next->ai_protocol == 0);
    assert(res->ai_next->ai_next->ai_next == (struct addrinfo *)0);
    freeaddrinfo(res);

    /* NULL hints behave as family UNSPEC, socktype 0, and the entries carry flags AI_V4MAPPED|AI_ADDRCONFIG = 0x40. */
    assert(getaddrinfo("1.2.3.4", "80", (const struct addrinfo *)0, &res) == 0);
    assert(res->ai_flags == 0x40 && res->ai_socktype == SOCK_STREAM && res->ai_next != (struct addrinfo *)0);
    freeaddrinfo(res);

    /* DGRAM selects UDP; an explicit matching protocol is accepted; a mismatching one is EAI_SOCKTYPE. */
    HINTS(AF_INET, SOCK_DGRAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "53", &hints, &res) == 0 && res->ai_protocol == IPPROTO_UDP && res->ai_next == (struct addrinfo *)0);
    freeaddrinfo(res);
    HINTS(AF_INET, SOCK_DGRAM, IPPROTO_UDP, 0);
    assert(getaddrinfo("1.2.3.4", "53", &hints, &res) == 0);
    freeaddrinfo(res);
    HINTS(AF_INET, SOCK_STREAM, IPPROTO_UDP, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_SOCKTYPE);
    HINTS(AF_INET, SOCK_DGRAM, IPPROTO_TCP, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_SOCKTYPE);
    /* Protocol only: the protocol picks the socktype. */
    HINTS(AF_INET, 0, IPPROTO_TCP, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0 && res->ai_socktype == SOCK_STREAM && res->ai_next == (struct addrinfo *)0);
    freeaddrinfo(res);
    HINTS(AF_INET, 0, IPPROTO_UDP, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0 && res->ai_socktype == SOCK_DGRAM && res->ai_next == (struct addrinfo *)0);
    freeaddrinfo(res);
    /* An unknown protocol, or a socktype this library does not serve, is rejected. */
    HINTS(AF_INET, 0, 99, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_SERVICE);
    HINTS(AF_INET, 77, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_SOCKTYPE);

    /* Family: UNSPEC, INET and INET6 are served, anything else is EAI_FAMILY. An IPv4 literal under AF_INET6 is
     * EAI_ADDRFAMILY (-9) unless AI_V4MAPPED maps it (glibc, measured). */
    HINTS(AF_UNSPEC, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0);
    freeaddrinfo(res);
    HINTS(1 /* AF_UNIX */, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_FAMILY);
    HINTS(AF_INET6, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_ADDRFAMILY);
    assert(strcmp(gai_strerror(EAI_ADDRFAMILY), "Address family for hostname not supported") == 0);

    /* IPv6 literals: a 28-byte sockaddr_in6 (family 10 little-endian, port big-endian, flowinfo 0, the address, scope id),
     * the bytes glibc writes for 2001:db8::1 port 443. */
    {
        static const uint8_t want[28] = {10, 0, 1, 187, 0, 0, 0, 0, 32, 1, 13, 184, 0, 0, 0, 0,
                                         0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0};
        HINTS(AF_INET6, SOCK_STREAM, 0, 0);
        assert(getaddrinfo("2001:db8::1", "443", &hints, &res) == 0);
        assert(res->ai_family == AF_INET6 && res->ai_addrlen == 28 && res->ai_protocol == IPPROTO_TCP && res->ai_flags == 0);
        assert(memcmp(res->ai_addr, want, 28) == 0 && res->ai_next == (struct addrinfo *)0);
        freeaddrinfo(res);
        /* AF_UNSPEC takes it as IPv6 too; AF_INET refuses it with EAI_ADDRFAMILY. */
        HINTS(AF_UNSPEC, SOCK_STREAM, 0, 0);
        assert(getaddrinfo("2001:db8::1", "443", &hints, &res) == 0 && res->ai_family == AF_INET6 && memcmp(res->ai_addr, want, 28) == 0);
        freeaddrinfo(res);
        HINTS(AF_INET, SOCK_STREAM, 0, 0);
        assert(getaddrinfo("2001:db8::1", "443", &hints, &res) == EAI_ADDRFAMILY);
        /* A literal never reaches the resolver, also under AI_NUMERICHOST; AI_CANONNAME echoes the text. */
        stub_reset();
        HINTS(AF_INET6, SOCK_STREAM, 0, AI_NUMERICHOST | AI_CANONNAME);
        assert(getaddrinfo("2001:db8::7", "80", &hints, &res) == 0 && moqi_test_last_nr == 0);
        assert(res->ai_canonname && strcmp(res->ai_canonname, "2001:db8::7") == 0);
        freeaddrinfo(res);
        /* A mapped literal stays IPv6. */
        HINTS(AF_INET6, SOCK_STREAM, 0, 0);
        assert(getaddrinfo("::ffff:1.2.3.4", "80", &hints, &res) == 0 && SA(res)[18] == 255 && SA(res)[19] == 255 && SA(res)[20] == 1 && SA(res)[23] == 4);
        freeaddrinfo(res);
        /* AI_V4MAPPED turns an IPv4 literal into ::ffff:a.b.c.d under AF_INET6. */
        HINTS(AF_INET6, SOCK_STREAM, 0, AI_V4MAPPED);
        assert(getaddrinfo("10.5.0.6", "80", &hints, &res) == 0 && res->ai_family == AF_INET6 && res->ai_addrlen == 28);
        assert(SA(res)[8] == 0 && SA(res)[17] == 0 && SA(res)[18] == 255 && SA(res)[19] == 255 && SA(res)[20] == 10 && SA(res)[23] == 6);
        assert(res->ai_flags == AI_V4MAPPED);
        freeaddrinfo(res);
    }
    /* Numeric scope ids: "%N" sets sin6_scope_id (decimal, leading zeros allowed, up to 2^32-1); an empty, negative, too large or
     * non-numeric scope, or a scope on an IPv4 literal, is EAI_NONAME (glibc, measured with AI_NUMERICHOST). Interface names
     * after '%' need if_nametoindex, which this library does not have: they are EAI_NONAME too. */
    {
        static const struct { const char *text; int rc; uint32_t scope; } scopes[] = {
            {"fe80::1%1", 0, 1}, {"fe80::1%99", 0, 99}, {"fe80::1%01", 0, 1}, {"fe80::1%4294967295", 0, 4294967295u},
            {"::ffff:1.2.3.4%2", 0, 2}, {"2001:db8::7%1", 0, 1},
            {"fe80::1%", EAI_NONAME, 0}, {"fe80::1%-1", EAI_NONAME, 0}, {"fe80::1%4294967296", EAI_NONAME, 0},
            {"fe80::1%1x", EAI_NONAME, 0}, {"10.0.0.1%1", EAI_NONAME, 0},
        };
        for (unsigned i = 0; i < sizeof(scopes) / sizeof(scopes[0]); i++) {
            HINTS(AF_UNSPEC, SOCK_STREAM, 0, AI_NUMERICHOST);
            int rc = getaddrinfo(scopes[i].text, "80", &hints, &res);
            assert(rc == scopes[i].rc);
            if (rc == 0) {
                uint32_t got = (uint32_t)SA(res)[24] | (uint32_t)SA(res)[25] << 8 | (uint32_t)SA(res)[26] << 16 | (uint32_t)SA(res)[27] << 24;
                assert(res->ai_family == AF_INET6 && got == scopes[i].scope);
                freeaddrinfo(res);
            }
        }
    }
    /* NULL node under AF_INET6: ::1, or :: with AI_PASSIVE. AF_UNSPEC gives both families: ::1 then 127.0.0.1, and with
     * AI_PASSIVE 0.0.0.0 then :: (glibc's order with the loopback interface up). */
    {
        static const uint8_t zero16[16] = {0};
        HINTS(AF_INET6, SOCK_STREAM, 0, 0);
        assert(getaddrinfo((const char *)0, "80", &hints, &res) == 0 && res->ai_family == AF_INET6 && SA(res)[23] == 1 && SA(res)[22] == 0 && SA(res)[8] == 0);
        assert(res->ai_next == (struct addrinfo *)0);
        freeaddrinfo(res);
        HINTS(AF_INET6, SOCK_STREAM, 0, AI_PASSIVE);
        assert(getaddrinfo((const char *)0, "80", &hints, &res) == 0 && memcmp(SA(res) + 8, zero16, 16) == 0 && PORT(res) == 80);
        freeaddrinfo(res);
        HINTS(AF_UNSPEC, SOCK_STREAM, 0, 0);
        assert(getaddrinfo((const char *)0, "80", &hints, &res) == 0);
        assert(res->ai_family == AF_INET6 && SA(res)[23] == 1 && res->ai_next && res->ai_next->ai_family == AF_INET && SA(res->ai_next)[4] == 127);
        assert(res->ai_next->ai_next == (struct addrinfo *)0);
        freeaddrinfo(res);
        HINTS(AF_UNSPEC, SOCK_STREAM, 0, AI_PASSIVE);
        assert(getaddrinfo((const char *)0, "80", &hints, &res) == 0);
        assert(res->ai_family == AF_INET && SA(res)[4] == 0 && res->ai_next && res->ai_next->ai_family == AF_INET6);
        assert(memcmp(SA(res->ai_next) + 8, zero16, 16) == 0 && res->ai_next->ai_next == (struct addrinfo *)0);
        freeaddrinfo(res);
    }

    /* Services: numeric (decimal, leading/trailing forms the strtol accepts), a small name table, NULL is port 0. */
    HINTS(AF_INET, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", (const char *)0, &hints, &res) == 0 && PORT(res) == 0);
    freeaddrinfo(res);
    static const struct { const char *svc; unsigned port; } svcs[] = {
        {"0", 0}, {"80", 80}, {"65535", 65535}, {"080", 80}, {"+80", 80}, {" 80", 80}, {"", 0},
        {"http", 80}, {"https", 443}, {"ssh", 22}, {"domain", 53}, {"ftp", 21}, {"echo", 7}, {"smtp", 25},
        {"telnet", 23}, {"ntp", 123}, {"pop3", 110}, {"imap", 143},
    };
    for (unsigned i = 0; i < sizeof(svcs) / sizeof(svcs[0]); i++) {
        assert(getaddrinfo("1.2.3.4", svcs[i].svc, &hints, &res) == 0);
        assert(PORT(res) == svcs[i].port);
        freeaddrinfo(res);
    }
    /* Port numbers that overflow 16 bits wrap like glibc (65536 -> 0, 99999999999 -> 59391). */
    assert(getaddrinfo("1.2.3.4", "65536", &hints, &res) == 0 && PORT(res) == 0);
    freeaddrinfo(res);
    assert(getaddrinfo("1.2.3.4", "99999999999", &hints, &res) == 0 && PORT(res) == 59391);
    freeaddrinfo(res);
    /* Names that are neither numbers nor in the table, or have trailing junk, are EAI_SERVICE. */
    assert(getaddrinfo("1.2.3.4", "nosuchsvc", &hints, &res) == EAI_SERVICE);
    assert(getaddrinfo("1.2.3.4", "80x", &hints, &res) == EAI_SERVICE);
    assert(getaddrinfo("1.2.3.4", "-1", &hints, &res) == EAI_SERVICE);
    assert(getaddrinfo("1.2.3.4", "0x50", &hints, &res) == EAI_SERVICE);
    assert(getaddrinfo("1.2.3.4", "HTTP", &hints, &res) == EAI_SERVICE); /* case-sensitive */
    /* UDP services: domain is 53, http is still 80 (glibc's /etc/services lists both protocols). */
    HINTS(AF_INET, SOCK_DGRAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "domain", &hints, &res) == 0 && PORT(res) == 53);
    freeaddrinfo(res);
    /* AI_NUMERICSERV: a service name is EAI_NONAME, a number is fine and the flag is echoed. */
    HINTS(AF_INET, SOCK_STREAM, 0, AI_NUMERICSERV);
    assert(getaddrinfo("1.2.3.4", "http", &hints, &res) == EAI_NONAME);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0 && res->ai_flags == AI_NUMERICSERV);
    freeaddrinfo(res);

    /* Both node and service NULL is EAI_NONAME; an empty node is EAI_NODATA-like (-5) in glibc, which this
     * library reports as EAI_NONAME because it has no distinct NODATA code. */
    HINTS(AF_INET, SOCK_STREAM, 0, 0);
    assert(getaddrinfo((const char *)0, (const char *)0, &hints, &res) == EAI_NONAME);

    /* NULL node: loopback by default, the wildcard address with AI_PASSIVE. */
    assert(getaddrinfo((const char *)0, "80", &hints, &res) == 0 && SA(res)[4] == 127 && SA(res)[7] == 1);
    freeaddrinfo(res);
    HINTS(AF_INET, SOCK_STREAM, 0, AI_PASSIVE);
    assert(getaddrinfo((const char *)0, "80", &hints, &res) == 0 && SA(res)[4] == 0 && SA(res)[5] == 0 && SA(res)[6] == 0 && SA(res)[7] == 0);
    assert(res->ai_flags == AI_PASSIVE);
    freeaddrinfo(res);
    /* AI_PASSIVE with a node ignores the passive meaning for the address but keeps the flag. */
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0 && SA(res)[4] == 1 && res->ai_flags == AI_PASSIVE);
    freeaddrinfo(res);

    /* AI_CANONNAME: a node is required (glibc EAI_BADFLAGS with a NULL node); the canonical name is the node. */
    HINTS(AF_INET, SOCK_STREAM, 0, AI_CANONNAME);
    assert(getaddrinfo((const char *)0, "80", &hints, &res) == EAI_BADFLAGS);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0);
    assert(res->ai_flags == AI_CANONNAME && res->ai_canonname != (char *)0 && strcmp(res->ai_canonname, "1.2.3.4") == 0);
    freeaddrinfo(res);

    /* With several entries only the first one carries the canonical name (glibc, measured with localhost). */
    HINTS(AF_INET, 0, 0, AI_CANONNAME);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0);
    assert(res->ai_canonname != (char *)0 && strcmp(res->ai_canonname, "1.2.3.4") == 0);
    assert(res->ai_next != (struct addrinfo *)0 && res->ai_next->ai_canonname == (char *)0);
    assert(res->ai_next->ai_next != (struct addrinfo *)0 && res->ai_next->ai_next->ai_canonname == (char *)0);
    freeaddrinfo(res);

    /* Flags: an unknown bit is EAI_BADFLAGS before anything else is looked at. */
    HINTS(AF_INET, SOCK_STREAM, 0, 0x4000);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_BADFLAGS);

    /* AI_NUMERICHOST: a name is EAI_NONAME without any lookup; a literal is accepted. */
    HINTS(AF_INET, SOCK_STREAM, 0, AI_NUMERICHOST);
    stub_reset();
    moqi_test_last_nr = 0;
    assert(getaddrinfo("localhost", "80", &hints, &res) == EAI_NONAME && moqi_test_last_nr == 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0 && res->ai_flags == AI_NUMERICHOST);
    freeaddrinfo(res);

    /* A name goes through the resolver; its failures map to EAI codes (ENOENT/EINVAL/too long -> NONAME, any other
     * failure such as a timeout -> AGAIN). */
    HINTS(AF_INET, SOCK_STREAM, 0, 0);
    moqi_test_reply = 0;
    moqi_test_fill[0] = 10; moqi_test_fill[1] = 0; moqi_test_fill[2] = 2; moqi_test_fill[3] = 2;
    assert(getaddrinfo("gateway", "80", &hints, &res) == 0 && moqi_test_last_nr == 495 && SA(res)[4] == 10 && SA(res)[7] == 2);
    freeaddrinfo(res);
    moqi_test_reply = -2;
    assert(getaddrinfo("nope.invalid", "80", &hints, &res) == EAI_NONAME);
    moqi_test_reply = -22;
    assert(getaddrinfo("bad name!", "80", &hints, &res) == EAI_NONAME);
    moqi_test_reply = -36;
    assert(getaddrinfo("x", "80", &hints, &res) == EAI_NONAME);
    moqi_test_reply = -110;
    assert(getaddrinfo("slow.example", "80", &hints, &res) == EAI_AGAIN);
    moqi_test_reply = -5;
    assert(getaddrinfo("broken.example", "80", &hints, &res) == EAI_AGAIN);
    moqi_test_reply = 0;

    /* freeaddrinfo(NULL) is a no-op; gai_strerror gives text for every code and for an unknown one. */
    freeaddrinfo((struct addrinfo *)0);
    assert(strcmp(gai_strerror(EAI_NONAME), "Name or service not known") == 0);
    assert(strcmp(gai_strerror(EAI_SERVICE), "Servname not supported for ai_socktype") == 0);
    assert(strcmp(gai_strerror(EAI_BADFLAGS), "Bad value for ai_flags") == 0);
    assert(strcmp(gai_strerror(EAI_AGAIN), "Temporary failure in name resolution") == 0);
    assert(strcmp(gai_strerror(EAI_FAMILY), "ai_family not supported") == 0);
    assert(strcmp(gai_strerror(EAI_SOCKTYPE), "ai_socktype not supported") == 0);
    assert(strcmp(gai_strerror(0), "Success") == 0);
    assert(gai_strerror(-12345) != (const char *)0);
    /* Round trip with the formatter. */
    for (int a = 0; a < 256; a += 51) {
        uint8_t in[4] = {(uint8_t)a, (uint8_t)(255 - a), (uint8_t)(a ^ 0x5A), (uint8_t)(a / 2)};
        uint8_t back[4];
        assert(ipv4_to_text(in, text, sizeof(text)) > 0);
        assert(ipv4_from_text(text, back) == 1 && memcmp(in, back, 4) == 0);
    }
    /* ---- getnameinfo: the values below were measured against glibc 2.x on the host ---------------------------- */
    {
        uint8_t sa[16];
        char host[64], serv[32];
        const uint8_t gw[4] = {10, 0, 2, 2};
        const uint8_t lo[4] = {127, 0, 0, 1};
        const uint8_t zero[4] = {0, 0, 0, 0};
        const uint8_t bcast[4] = {255, 255, 255, 255};

        assert(NI_NUMERICHOST == 1 && NI_NUMERICSERV == 2 && NI_NOFQDN == 4 && NI_NAMEREQD == 8 && NI_DGRAM == 16);
        assert(NI_MAXHOST == 1025 && NI_MAXSERV == 32 && EAI_OVERFLOW == -12);

        /* Numeric host and service; a service without a name is its decimal port. */
        ipv4_sockaddr(gw, 65000, sa);
        memset(host, 'H', sizeof(host)); memset(serv, 'S', sizeof(serv));
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), 0) == 0);
        assert(strcmp(host, "10.0.2.2") == 0 && strcmp(serv, "65000") == 0);

        /* Known service names are used unless NI_NUMERICSERV is set. */
        ipv4_sockaddr(gw, 80, sa);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), 0) == 0);
        assert(strcmp(serv, "http") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICSERV) == 0);
        assert(strcmp(serv, "80") == 0);
        {
            static const struct { uint16_t port; const char *name; } svc[] = {
                {7, "echo"}, {21, "ftp"}, {22, "ssh"}, {23, "telnet"}, {25, "smtp"}, {53, "domain"}, {80, "http"},
                {110, "pop3"}, {123, "ntp"}, {143, "imap"}, {443, "https"}, {0, "0"}, {65535, "65535"}, {9199, "9199"},
            };
            for (unsigned i = 0; i < sizeof(svc) / sizeof(svc[0]); i++) {
                ipv4_sockaddr(gw, svc[i].port, sa);
                assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), 0) == 0);
                assert(strcmp(serv, svc[i].name) == 0);
                /* NI_DGRAM changes nothing for these names. */
                assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_DGRAM) == 0);
                assert(strcmp(serv, svc[i].name) == 0);
            }
        }

        /* Without /etc/hosts loopback has no name either (glibc 2.44, measured): every address is numeric here. */
        ipv4_sockaddr(lo, 80, sa);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), 0) == 0);
        assert(strcmp(host, "127.0.0.1") == 0 && strcmp(serv, "http") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST) == 0);
        assert(strcmp(host, "127.0.0.1") == 0 && strcmp(serv, "http") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST | NI_NUMERICSERV) == 0);
        assert(strcmp(host, "127.0.0.1") == 0 && strcmp(serv, "80") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICSERV) == 0);
        assert(strcmp(host, "127.0.0.1") == 0 && strcmp(serv, "80") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NAMEREQD) == EAI_NONAME);
        {
            uint8_t other[4] = {127, 0, 0, 2};
            ipv4_sockaddr(other, 80, sa);
            assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), 0) == 0);
            assert(strcmp(host, "127.0.0.2") == 0);
        }
        ipv4_sockaddr(zero, 0, sa);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), 0) == 0);
        assert(strcmp(host, "0.0.0.0") == 0 && strcmp(serv, "0") == 0);
        ipv4_sockaddr(bcast, 0, sa);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST) == 0);
        assert(strcmp(host, "255.255.255.255") == 0);

        /* NI_NAMEREQD: no name is EAI_NONAME, but only when a host buffer was asked for. */
        ipv4_sockaddr(gw, 80, sa);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NAMEREQD) == EAI_NONAME);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NAMEREQD | NI_NUMERICHOST) == EAI_NONAME);
        assert(getnameinfo(sa, 16, host, 0, serv, sizeof(serv), NI_NAMEREQD) == 0);
        assert(getnameinfo(sa, 16, (char *)0, 0, serv, sizeof(serv), NI_NAMEREQD) == 0 && strcmp(serv, "http") == 0);
        ipv4_sockaddr(lo, 80, sa);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NAMEREQD | NI_NUMERICHOST) == EAI_NONAME);

        /* A NULL or zero-length buffer means "do not return that part". */
        ipv4_sockaddr(gw, 80, sa);
        memset(host, 'H', sizeof(host)); memset(serv, 'S', sizeof(serv));
        assert(getnameinfo(sa, 16, (char *)0, 64, serv, sizeof(serv), NI_NUMERICHOST) == 0);
        assert(host[0] == 'H' && strcmp(serv, "http") == 0);
        assert(getnameinfo(sa, 16, host, 0, serv, sizeof(serv), NI_NUMERICHOST) == 0 && host[0] == 'H');
        memset(serv, 'S', sizeof(serv));
        assert(getnameinfo(sa, 16, host, sizeof(host), (char *)0, 32, NI_NUMERICHOST) == 0);
        assert(strcmp(host, "10.0.2.2") == 0 && serv[0] == 'S');
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 0, NI_NUMERICHOST) == 0 && serv[0] == 'S');
        assert(getnameinfo(sa, 16, (char *)0, 0, (char *)0, 0, 0) == 0);
        assert(getnameinfo(sa, 16, (char *)0, 0, (char *)0, 0, 0xFFFF) == EAI_BADFLAGS);

        /* Buffer sizes: the text plus its NUL must fit, otherwise EAI_OVERFLOW. */
        assert(getnameinfo(sa, 16, host, 8, serv, sizeof(serv), NI_NUMERICHOST) == EAI_OVERFLOW);
        assert(getnameinfo(sa, 16, host, 9, serv, sizeof(serv), NI_NUMERICHOST) == 0 && strcmp(host, "10.0.2.2") == 0);
        assert(getnameinfo(sa, 16, host, 5, serv, sizeof(serv), NI_NUMERICHOST) == EAI_OVERFLOW);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 4, 0) == EAI_OVERFLOW);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 5, 0) == 0 && strcmp(serv, "http") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 2, NI_NUMERICSERV) == EAI_OVERFLOW);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 3, NI_NUMERICSERV) == 0 && strcmp(serv, "80") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 1, 0) == EAI_OVERFLOW);
        ipv4_sockaddr(lo, 80, sa);
        /* Without an /etc/hosts line 127.0.0.1 has no name: the numeric form, and EAI_NONAME under NI_NAMEREQD (glibc 2.44,
         * measured with "hosts: files" and an empty or missing file). "127.0.0.1" is 9 characters. */
        assert(getnameinfo(sa, 16, host, 9, serv, sizeof(serv), 0) == EAI_OVERFLOW);
        assert(getnameinfo(sa, 16, host, 10, serv, sizeof(serv), 0) == 0 && strcmp(host, "127.0.0.1") == 0);
        assert(getnameinfo(sa, 16, host, 10, serv, sizeof(serv), NI_NAMEREQD) == EAI_NONAME);
        assert(getnameinfo(sa, 16, host, 10, serv, sizeof(serv), NI_NUMERICHOST) == 0 && strcmp(host, "127.0.0.1") == 0);

        /* The host is already written when the service buffer turns out to be too small (glibc order). */
        ipv4_sockaddr(lo, 80, sa);
        memset(host, 'H', sizeof(host));
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 4, 0) == EAI_OVERFLOW);
        assert(strcmp(host, "127.0.0.1") == 0);
        /* ...and a host that does not fit stops before the service is touched. */
        memset(serv, 'S', sizeof(serv));
        assert(getnameinfo(sa, 16, host, 4, serv, sizeof(serv), 0) == EAI_OVERFLOW && serv[0] == 'S');
        ipv4_sockaddr(gw, 80, sa);

        /* Flags: NOFQDN and the IDN bits are accepted and change nothing; bits glibc rejects are EAI_BADFLAGS. */
        ipv4_sockaddr(gw, 80, sa);
        {
            static const int ok[] = {NI_NOFQDN, 0x20, 0x40, 0x80, NI_DGRAM};
            for (unsigned i = 0; i < sizeof(ok) / sizeof(ok[0]); i++) {
                assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), ok[i]) == 0);
                assert(strcmp(host, "10.0.2.2") == 0 && strcmp(serv, "http") == 0);
            }
            static const int bad[] = {0x100, 0x200, 0x400, 0x8000, -1};
            for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
                assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), bad[i]) == EAI_BADFLAGS);
            /* The flag check comes before the address check. */
            uint8_t v6[16] = {10, 0};
            assert(getnameinfo(v6, 16, host, sizeof(host), serv, sizeof(serv), 0x8000) == EAI_BADFLAGS);
            assert(getnameinfo(sa, 8, host, sizeof(host), serv, sizeof(serv), 0x8000) == EAI_BADFLAGS);
        }

        /* Address validation: NULL, short, or other-family sockaddrs are EAI_FAMILY; a longer one is fine. */
        assert(getnameinfo((const uint8_t *)0, 16, host, sizeof(host), serv, sizeof(serv), 0) == EAI_FAMILY);
        assert(getnameinfo(sa, 0, host, sizeof(host), serv, sizeof(serv), 0) == EAI_FAMILY);
        assert(getnameinfo(sa, 8, host, sizeof(host), serv, sizeof(serv), 0) == EAI_FAMILY);
        assert(getnameinfo(sa, 15, host, sizeof(host), serv, sizeof(serv), 0) == EAI_FAMILY);
        assert(getnameinfo(sa, 100, host, sizeof(host), serv, sizeof(serv), 0) == 0 && strcmp(host, "10.0.2.2") == 0);
        {
            /* sockaddr_in6 (glibc, measured): a 28-byte address formats like inet_ntop, a non-zero scope id appends "%N" to the
             * numeric form, the service comes from the port as for IPv4; shorter than 28 bytes is EAI_FAMILY. Without
             * /etc/hosts (the host test has no file system) an unnamed address is numeric and NI_NAMEREQD is EAI_NONAME, ::1
             * as well. */
            uint8_t v6[28];
            memset(v6, 0, sizeof(v6));
            v6[0] = 10;
            v6[2] = 0x01; v6[3] = 0xBB; /* port 443 */
            static const uint8_t a1[16] = {32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9};
            memcpy(v6 + 8, a1, 16);
            assert(getnameinfo(v6, 28, host, sizeof(host), serv, sizeof(serv), 0) == 0 && strcmp(host, "2001:db8::9") == 0 && strcmp(serv, "https") == 0);
            assert(getnameinfo(v6, 28, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST) == 0 && strcmp(host, "2001:db8::9") == 0);
            assert(getnameinfo(v6, 28, host, sizeof(host), serv, sizeof(serv), NI_NAMEREQD) == EAI_NONAME);
            assert(getnameinfo(v6, 27, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST) == EAI_FAMILY);
            assert(getnameinfo(v6, 24, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST) == EAI_FAMILY);
            /* "2001:db8::9" is 11 characters: a 12-byte buffer fits, 11 is EAI_OVERFLOW. */
            assert(getnameinfo(v6, 28, host, 12, serv, sizeof(serv), NI_NUMERICHOST) == 0);
            assert(getnameinfo(v6, 28, host, 11, serv, sizeof(serv), NI_NUMERICHOST) == EAI_OVERFLOW);
            /* Scope ids: "%N" on the numeric form of any address, for 99 as well as 3. */
            static const uint8_t ll[16] = {254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
            memcpy(v6 + 8, ll, 16);
            v6[24] = 3;
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, NI_NUMERICHOST) == 0 && strcmp(host, "fe80::1%3") == 0);
            v6[24] = 99;
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, NI_NUMERICHOST) == 0 && strcmp(host, "fe80::1%99") == 0);
            memcpy(v6 + 8, a1, 16);
            v6[24] = 5;
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, NI_NUMERICHOST) == 0 && strcmp(host, "2001:db8::9%5") == 0);
            v6[24] = 0;
            /* ::1, :: and a mapped address are numeric without a file entry, ::1 included (glibc 2.44, measured). */
            memset(v6 + 8, 0, 16);
            v6[23] = 1;
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, 0) == 0 && strcmp(host, "::1") == 0);
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, NI_NAMEREQD) == EAI_NONAME);
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, NI_NUMERICHOST) == 0 && strcmp(host, "::1") == 0);
            v6[23] = 0;
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, 0) == 0 && strcmp(host, "::") == 0);
            v6[18] = 0xFF; v6[19] = 0xFF; v6[20] = 10; v6[21] = 5; v6[22] = 0; v6[23] = 6;
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, NI_NUMERICHOST) == 0 && strcmp(host, "::ffff:10.5.0.6") == 0);
            /* A 16-byte buffer whose family field is not 2 or 10 is still EAI_FAMILY. */
            memcpy(v6, sa, 16);
            v6[1] = 1; /* family 0x0102 */
            assert(getnameinfo(v6, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST) == EAI_FAMILY);
        }

        /* gai_strerror knows the two codes getnameinfo adds. */
        assert(strcmp(gai_strerror(EAI_OVERFLOW), "Result too large for supplied buffer") == 0);
        assert(strcmp(gai_strerror(-11), "System error") == 0);
        assert(strcmp(gai_strerror(-13), "Unknown error") == 0);
    }
    /* Every list that getaddrinfo built was released: nothing leaked, nothing freed twice. */
    assert(live_allocs == 0);
    return 0;
}
