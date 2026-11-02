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
    /* Round trip with the formatter. */
    for (int a = 0; a < 256; a += 51) {
        uint8_t in[4] = {(uint8_t)a, (uint8_t)(255 - a), (uint8_t)(a ^ 0x5A), (uint8_t)(a / 2)};
        uint8_t back[4];
        assert(ipv4_to_text(in, text, sizeof(text)) > 0);
        assert(ipv4_from_text(text, back) == 1 && memcmp(in, back, 4) == 0);
    }
    return 0;
}
