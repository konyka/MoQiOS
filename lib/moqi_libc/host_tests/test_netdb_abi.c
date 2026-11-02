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
    /* Round trip with the formatter. */
    for (int a = 0; a < 256; a += 51) {
        uint8_t in[4] = {(uint8_t)a, (uint8_t)(255 - a), (uint8_t)(a ^ 0x5A), (uint8_t)(a / 2)};
        uint8_t back[4];
        assert(ipv4_to_text(in, text, sizeof(text)) > 0);
        assert(ipv4_from_text(text, back) == 1 && memcmp(in, back, 4) == 0);
    }
    return 0;
}
