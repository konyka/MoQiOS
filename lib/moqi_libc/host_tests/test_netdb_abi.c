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

    /* Family: UNSPEC and INET work, anything else is EAI_FAMILY (glibc says -9 for INET6 + a v4 name; this stack
     * has no IPv6 so it is EAI_FAMILY too). */
    HINTS(AF_UNSPEC, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == 0);
    freeaddrinfo(res);
    HINTS(1 /* AF_UNIX */, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_FAMILY);
    HINTS(10 /* AF_INET6 */, SOCK_STREAM, 0, 0);
    assert(getaddrinfo("1.2.3.4", "80", &hints, &res) == EAI_FAMILY);

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
    /* Every list that getaddrinfo built was released: nothing leaked, nothing freed twice. */
    assert(live_allocs == 0);
    return 0;
}
