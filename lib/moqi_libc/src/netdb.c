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

/* The socket syscalls only exist on the target; the host unit test links a recording stub instead. */
#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall3(long nr, long a1, long a2, long a3);
#define NETDB_SYSCALL3(nr, a1, a2, a3) moqi_test_syscall3((nr), (a1), (a2), (a3))
#define NETDB_SYSCALL1(nr, a1) moqi_test_syscall3((nr), (a1), 0, 0)
#else
#define NETDB_SYSCALL3(nr, a1, a2, a3) syscall3((nr), (a1), (a2), (a3))
#define NETDB_SYSCALL1(nr, a1) syscall1((nr), (a1))
#endif

long tcp_connect_host(const char *host, uint16_t port) {
    uint8_t sa[16];
    long r = resolve_ipv4_sockaddr(host, port, sa);
    if (r < 0) return r;
    long fd = NETDB_SYSCALL3(SYS_socket, 2 /* AF_INET */, 1 /* SOCK_STREAM */, 0);
    if (fd < 0) return fd;
    long c = NETDB_SYSCALL3(SYS_connect, fd, (long)sa, 16);
    /* The stack is driven by netpoll: a connect that has not completed yet (EINPROGRESS or any early error) is
     * retried a bounded number of times, and EISCONN means the earlier attempt finished. */
    for (int i = 0; i < 20 && c < 0 && c != -106 /* EISCONN */; i++) {
        NETDB_SYSCALL1(SYS_netpoll, 0);
        c = NETDB_SYSCALL3(SYS_connect, fd, (long)sa, 16);
    }
    if (c < 0 && c != -106) {
        NETDB_SYSCALL1(SYS_close, fd);
        return c;
    }
    return fd;
}

/* ---- gethostbyname ------------------------------------------------------------------------------------------ */

int h_errno;

#define HOSTENT_NAME_MAX 256

static struct hostent hostent_result;
static char hostent_name[HOSTENT_NAME_MAX];
static char hostent_addr[4];
static char *hostent_aliases[1];
static char *hostent_addr_list[2];

struct hostent *gethostbyname(const char *name) {
    if (!name) {
        h_errno = HOST_NOT_FOUND;
        return (struct hostent *)0;
    }
    uint8_t addr[4];
    if (!ipv4_from_text(name, addr)) {
        long r = gethostbyname_ipv4(name, addr);
        if (r < 0) {
            /* A name that does not exist, is malformed, or is too long is a definitive "no such host"; a timeout
             * or any other failure is worth retrying. */
            h_errno = (r == -2 /* ENOENT */ || r == -22 /* EINVAL */ || r == -36 /* ENAMETOOLONG */)
                          ? HOST_NOT_FOUND
                          : TRY_AGAIN;
            return (struct hostent *)0;
        }
    }
    size_t n = 0;
    while (name[n] && n + 1 < HOSTENT_NAME_MAX) {
        hostent_name[n] = name[n];
        n++;
    }
    hostent_name[n] = 0;
    for (int i = 0; i < 4; i++) hostent_addr[i] = (char)addr[i];
    hostent_aliases[0] = (char *)0;
    hostent_addr_list[0] = hostent_addr;
    hostent_addr_list[1] = (char *)0;
    hostent_result.h_name = hostent_name;
    hostent_result.h_aliases = hostent_aliases;
    hostent_result.h_addrtype = AF_INET;
    hostent_result.h_length = 4;
    hostent_result.h_addr_list = hostent_addr_list;
    h_errno = 0;
    return &hostent_result;
}
