#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

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

/* getaddrinfo allocates through malloc/free; the host test links only netdb.o, so it supplies a counting bump
 * allocator. (It cannot forward to the host malloc: with -fno-builtin that would call back into this function.) */
#include <stdlib.h>
static unsigned char arena[1 << 16];
static size_t arena_used;
static int live_allocs;
void *malloc(size_t n) {
    n = (n + 15) & ~(size_t)15;
    if (arena_used + n > sizeof(arena)) return (void *)0;
    void *p = arena + arena_used;
    arena_used += n;
    live_allocs++;
    return p;
}
void free(void *p) {
    if (p) live_allocs--;
}

/* Scripted socket layer for tcp_connect_host(): records every call number in order and answers per call number. */
#define STUB_LOG_MAX 64
long stub_log[STUB_LOG_MAX];
int stub_log_n;
long stub_socket_reply = 7;      /* the fd socket() returns (or a -errno) */
long stub_connect_replies[8];    /* successive connect() results; the last one repeats */
int stub_connect_n, stub_connect_calls;
long stub_last_connect_addr[2];

long moqi_test_syscall3(long nr, long a1, long a2, long a3) {
    (void)a3;
    if (stub_log_n < STUB_LOG_MAX) stub_log[stub_log_n++] = nr;
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

        /* Loopback has a name; NI_NUMERICHOST turns it off. Everything else is numeric (no reverse DNS here). */
        ipv4_sockaddr(lo, 80, sa);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), 0) == 0);
        assert(strcmp(host, "localhost") == 0 && strcmp(serv, "http") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST) == 0);
        assert(strcmp(host, "127.0.0.1") == 0 && strcmp(serv, "http") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICHOST | NI_NUMERICSERV) == 0);
        assert(strcmp(host, "127.0.0.1") == 0 && strcmp(serv, "80") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NUMERICSERV) == 0);
        assert(strcmp(host, "localhost") == 0 && strcmp(serv, "80") == 0);
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, sizeof(serv), NI_NAMEREQD) == 0);
        assert(strcmp(host, "localhost") == 0);
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
        assert(getnameinfo(sa, 16, host, 9, serv, sizeof(serv), 0) == EAI_OVERFLOW);
        assert(getnameinfo(sa, 16, host, 10, serv, sizeof(serv), 0) == 0 && strcmp(host, "localhost") == 0);
        assert(getnameinfo(sa, 16, host, 10, serv, sizeof(serv), NI_NUMERICHOST) == 0 && strcmp(host, "127.0.0.1") == 0);

        /* The host is already written when the service buffer turns out to be too small (glibc order). */
        ipv4_sockaddr(lo, 80, sa);
        memset(host, 'H', sizeof(host));
        assert(getnameinfo(sa, 16, host, sizeof(host), serv, 4, 0) == EAI_OVERFLOW);
        assert(strcmp(host, "localhost") == 0);
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
             * /etc/hosts (the host test has no file system) an unnamed address is numeric and NI_NAMEREQD is EAI_NONAME; ::1 is
             * "localhost" as 127.0.0.1 is. */
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
            /* ::1 names localhost; :: and a mapped address are numeric without a file entry. */
            memset(v6 + 8, 0, 16);
            v6[23] = 1;
            assert(getnameinfo(v6, 28, host, sizeof(host), (char *)0, 0, 0) == 0 && strcmp(host, "localhost") == 0);
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
