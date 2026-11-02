/* netdb.c — hostname resolution wrappers (see include/netdb.h). */
#include "../include/netdb.h"
#include "../include/byteorder.h"

/* The host unit test links this file against a recording stub instead of the real `syscall` instruction. */
#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall2(long nr, long a1, long a2);
#define NETDB_SYSCALL2(nr, a1, a2) moqi_test_syscall2((nr), (a1), (a2))
#else
#define NETDB_SYSCALL2(nr, a1, a2) syscall2((nr), (a1), (a2))
#endif

long gethostbyname_ipv4(const char *name, uint8_t out[4]) {
    if (!name || !out) return -22; /* EINVAL */
    return NETDB_SYSCALL2(SYS_dns_resolve, (long)name, (long)out);
}

long ipv4_to_text(const uint8_t addr[4], char *buf, size_t buf_len) {
    char tmp[16];
    size_t n = 0;
    for (int i = 0; i < 4; i++) {
        unsigned v = addr[i];
        char digits[3];
        int d = 0;
        do { digits[d++] = (char)('0' + v % 10); v /= 10; } while (v);
        while (d) tmp[n++] = digits[--d];
        if (i < 3) tmp[n++] = '.';
    }
    if (n + 1 > buf_len) return -34; /* ERANGE */
    for (size_t i = 0; i < n; i++) buf[i] = tmp[i];
    buf[n] = 0;
    return (long)n;
}

int ipv4_from_text(const char *text, uint8_t out[4]) {
    if (!text || !out) return 0;
    uint8_t parsed[4];
    for (int field = 0; field < 4; field++) {
        if (text[0] < '0' || text[0] > '9') return 0;
        unsigned value = 0;
        int digits = 0;
        int leading_zero = text[0] == '0';
        while (*text >= '0' && *text <= '9') {
            value = value * 10 + (unsigned)(*text - '0');
            digits++;
            if (digits > 3 || value > 255) return 0;
            text++;
        }
        if (leading_zero && digits > 1) return 0;
        parsed[field] = (uint8_t)value;
        if (field < 3) {
            if (*text != '.') return 0;
            text++;
        }
    }
    if (*text != 0) return 0;
    for (int i = 0; i < 4; i++) out[i] = parsed[i];
    return 1;
}

void ipv4_sockaddr(const uint8_t addr[4], uint16_t port, uint8_t out[16]) {
    out[0] = 2; /* AF_INET, little-endian u16 */
    out[1] = 0;
    uint16_t be = htons(port);
    out[2] = (uint8_t)(be & 0xFF); /* first byte in memory of the big-endian value */
    out[3] = (uint8_t)(be >> 8);
    for (int i = 0; i < 4; i++) out[4 + i] = addr[i];
    for (int i = 8; i < 16; i++) out[i] = 0;
}

long resolve_ipv4_sockaddr(const char *host, uint16_t port, uint8_t out[16]) {
    if (!host || !out) return -22; /* EINVAL */
    uint8_t addr[4];
    if (!ipv4_from_text(host, addr)) {
        long r = gethostbyname_ipv4(host, addr);
        if (r < 0) return r;
    }
    ipv4_sockaddr(addr, port, out);
    return 0;
}
