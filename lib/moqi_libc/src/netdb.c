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

/* ---- getaddrinfo --------------------------------------------------------------------------------------------- */

#include "../include/stdlib.h"

/* Service names this library knows, with their port (TCP and UDP share them, as in glibc's /etc/services for these). */
static const struct { const char *name; uint16_t port; } service_table[] = {
    {"echo", 7}, {"ftp", 21}, {"ssh", 22}, {"telnet", 23}, {"smtp", 25}, {"domain", 53}, {"http", 80},
    {"pop3", 110}, {"ntp", 123}, {"imap", 143}, {"https", 443},
};

/* Parse a decimal service the way strtol would (optional leading blanks and sign), wrapping to 16 bits like glibc.
 * Returns 1 and the port when the whole string is a number, 0 otherwise. */
static int parse_numeric_service(const char *s, uint16_t *port) {
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\v' || *s == '\f' || *s == '\r') s++;
    int neg = 0;
    if (*s == '+' || *s == '-') { neg = *s == '-'; s++; }
    if (*s < '0' || *s > '9') return 0;
    unsigned long long v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (unsigned long long)(*s - '0'); s++; }
    if (*s != 0) return 0;
    if (neg) return 0;
    *port = (uint16_t)(v & 0xFFFF);
    return 1;
}

static const char *const gai_messages_head[] = {
    "Success",
    "Bad value for ai_flags",
    "Name or service not known",
    "Temporary failure in name resolution",
    "Non-recoverable failure in name resolution",
    "No address associated with hostname",
    "ai_family not supported",
    "ai_socktype not supported",
    "Servname not supported for ai_socktype",
    "Address family for hostname not supported",
    "Memory allocation failure",
    "System error",
    "Result too large for supplied buffer",
};

const char *gai_strerror(int code) {
    int idx = -code;
    if (idx >= 0 && idx < (int)(sizeof(gai_messages_head) / sizeof(gai_messages_head[0]))) return gai_messages_head[idx];
    return "Unknown error";
}

void freeaddrinfo(struct addrinfo *res) {
    while (res) {
        struct addrinfo *next = res->ai_next;
        if (res->ai_canonname) free(res->ai_canonname);
        if (res->ai_addr) free(res->ai_addr);
        free(res);
        res = next;
    }
}

static struct addrinfo *make_entry(const uint8_t addr[4], uint16_t port, int socktype, int protocol, int flags,
                                   const char *canon) {
    struct addrinfo *e = (struct addrinfo *)malloc(sizeof(struct addrinfo));
    if (!e) return (struct addrinfo *)0;
    memset(e, 0, sizeof(*e));
    e->ai_addr = (uint8_t *)malloc(16);
    if (!e->ai_addr) { free(e); return (struct addrinfo *)0; }
    ipv4_sockaddr(addr, port, e->ai_addr);
    e->ai_flags = flags;
    e->ai_family = AF_INET;
    e->ai_socktype = socktype;
    e->ai_protocol = protocol;
    e->ai_addrlen = 16;
    if (canon) {
        size_t n = strlen(canon);
        e->ai_canonname = (char *)malloc(n + 1);
        if (!e->ai_canonname) { free(e->ai_addr); free(e); return (struct addrinfo *)0; }
        memcpy(e->ai_canonname, canon, n + 1);
    }
    return e;
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    int flags = 0, family = AF_UNSPEC, socktype = 0, protocol = 0;
    if (hints) {
        flags = hints->ai_flags;
        family = hints->ai_family;
        socktype = hints->ai_socktype;
        protocol = hints->ai_protocol;
    }
    /* The caller's flags are validated; AI_V4MAPPED (8), AI_ALL (16) and AI_ADDRCONFIG (32) are accepted and ignored. */
    const int known_flags = AI_PASSIVE | AI_CANONNAME | AI_NUMERICHOST | AI_NUMERICSERV | 0x08 | 0x10 | 0x20;
    if (flags & ~known_flags) return EAI_BADFLAGS;
    /* With no hints at all glibc echoes 0x40 in the entries (its internal default); mirror that. */
    int echoed_flags = hints ? flags : 0x40;
    if ((flags & AI_CANONNAME) && !node) return EAI_BADFLAGS;
    if (!node && !service) return EAI_NONAME;
    if (family != AF_UNSPEC && family != AF_INET) return EAI_FAMILY;

    /* Which socket types to emit: (socktype, protocol) pairs, in glibc order. */
    int types[3], protos[3], ntypes = 0;
    if (socktype == SOCK_STREAM || socktype == 0) {
        if (protocol == 0 || protocol == IPPROTO_TCP) { types[ntypes] = SOCK_STREAM; protos[ntypes++] = IPPROTO_TCP; }
    }
    if (socktype == SOCK_DGRAM || socktype == 0) {
        if (protocol == 0 || protocol == IPPROTO_UDP) { types[ntypes] = SOCK_DGRAM; protos[ntypes++] = IPPROTO_UDP; }
    }
    if ((socktype == SOCK_RAW || socktype == 0) && protocol == 0) { types[ntypes] = SOCK_RAW; protos[ntypes++] = 0; }
    if (ntypes == 0) {
        if (socktype != 0 && socktype != SOCK_STREAM && socktype != SOCK_DGRAM && socktype != SOCK_RAW) return EAI_SOCKTYPE;
        if (socktype == 0) return EAI_SERVICE; /* a protocol this library does not serve */
        return EAI_SOCKTYPE;                   /* socktype and protocol disagree */
    }

    uint16_t port = 0;
    if (service && service[0]) {
        if (!parse_numeric_service(service, &port)) {
            if (flags & AI_NUMERICSERV) return EAI_NONAME;
            int found = 0;
            for (unsigned i = 0; i < sizeof(service_table) / sizeof(service_table[0]); i++) {
                if (strcmp(service, service_table[i].name) == 0) { port = service_table[i].port; found = 1; break; }
            }
            if (!found) return EAI_SERVICE;
        }
    }
    if (ntypes == 1 && types[0] == SOCK_RAW && service && service[0] && socktype == SOCK_RAW) {
        /* A named service has no meaning for a raw socket. */
        uint16_t tmp;
        if (!parse_numeric_service(service, &tmp)) return EAI_SERVICE;
    }

    uint8_t addr[4];
    const char *canon = (const char *)0;
    if (!node) {
        if (flags & AI_PASSIVE) { addr[0] = addr[1] = addr[2] = addr[3] = 0; }
        else { addr[0] = 127; addr[1] = 0; addr[2] = 0; addr[3] = 1; }
    } else if (ipv4_from_text(node, addr)) {
        if (flags & AI_CANONNAME) canon = node;
    } else {
        if (flags & AI_NUMERICHOST) return EAI_NONAME;
        long r = gethostbyname_ipv4(node, addr);
        if (r < 0) {
            return (r == -2 || r == -22 || r == -36) ? EAI_NONAME : EAI_AGAIN;
        }
        if (flags & AI_CANONNAME) canon = node;
    }

    struct addrinfo *head = (struct addrinfo *)0, **tail = &head;
    for (int i = 0; i < ntypes; i++) {
        /* Only the first entry carries the canonical name, as in glibc. */
        struct addrinfo *e = make_entry(addr, port, types[i], protos[i], echoed_flags, i == 0 ? canon : (const char *)0);
        if (!e) { freeaddrinfo(head); return EAI_MEMORY; }
        *tail = e;
        tail = &e->ai_next;
    }
    *res = head;
    return 0;
}

/* ---- getnameinfo --------------------------------------------------------------------------------------------- */

#define NI_KNOWN_FLAGS 0xFF

static int copy_text(char *dst, unsigned int dst_len, const char *text) {
    size_t n = strlen(text);
    if (n + 1 > dst_len) return EAI_OVERFLOW;
    memcpy(dst, text, n + 1);
    return 0;
}

int getnameinfo(const uint8_t *sa, unsigned int salen, char *host, unsigned int hostlen, char *serv,
                unsigned int servlen, int flags) {
    if ((unsigned int)flags & ~(unsigned int)NI_KNOWN_FLAGS) return EAI_BADFLAGS;
    if (!sa || salen < 16 || sa[0] != 2 || sa[1] != 0) return EAI_FAMILY;
    uint16_t port = (uint16_t)(((unsigned)sa[2] << 8) | sa[3]);
    const uint8_t *addr = sa + 4;

    if (host && hostlen > 0) {
        const char *text = (const char *)0;
        char dotted[16];
        if (!(flags & NI_NUMERICHOST) && addr[0] == 127 && addr[1] == 0 && addr[2] == 0 && addr[3] == 1) text = "localhost";
        if (!text) {
            if (flags & NI_NAMEREQD) return EAI_NONAME;
            ipv4_to_text(addr, dotted, sizeof(dotted));
            text = dotted;
        }
        int rc = copy_text(host, hostlen, text);
        if (rc) return rc;
    }
    if (serv && servlen > 0) {
        const char *text = (const char *)0;
        char digits[8];
        if (!(flags & NI_NUMERICSERV)) {
            for (unsigned i = 0; i < sizeof(service_table) / sizeof(service_table[0]); i++)
                if (service_table[i].port == port) { text = service_table[i].name; break; }
        }
        if (!text) {
            unsigned pos = sizeof(digits) - 1;
            digits[pos] = 0;
            unsigned v = port;
            do { digits[--pos] = (char)('0' + v % 10); v /= 10; } while (v);
            text = digits + pos;
        }
        int rc = copy_text(serv, servlen, text);
        if (rc) return rc;
    }
    return 0;
}
