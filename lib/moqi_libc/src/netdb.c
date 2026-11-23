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

long ipv6_to_text(const uint8_t addr[16], char *buf, size_t buf_len) {
    static const char hex[] = "0123456789abcdef";
    unsigned g[8];
    for (int i = 0; i < 8; i++) g[i] = (unsigned)addr[2 * i] << 8 | addr[2 * i + 1];
    /* The first longest run of at least two zero groups becomes "::". */
    int best = -1, best_len = 0;
    for (int i = 0; i < 8;) {
        if (g[i] != 0) { i++; continue; }
        int j = i;
        while (j < 8 && g[j] == 0) j++;
        if (j - i > best_len && j - i >= 2) { best = i; best_len = j - i; }
        i = j;
    }
    /* The last 32 bits stay a dotted quad for ::ffff:a.b.c.d, and for ::a.b.c.d when the seventh group is not zero (so ::2 and
     * ::ffff stay hex; glibc, measured). */
    int quad = 0;
    if (g[0] == 0 && g[1] == 0 && g[2] == 0 && g[3] == 0 && g[4] == 0) {
        if (g[5] == 0xFFFF) quad = 1;
        else if (g[5] == 0 && g[6] != 0) quad = 1;
    }
    int groups = quad ? 6 : 8;
    if (best >= 0 && best + best_len > groups) best_len = groups - best;
    if (best_len < 2) best = -1;
    char tmp[46];
    size_t n = 0;
    for (int i = 0; i < groups;) {
        if (i == best) {
            /* "::" stands for the run; it also supplies the separator on both sides. */
            tmp[n++] = ':';
            tmp[n++] = ':';
            i += best_len;
            continue;
        }
        if (n > 0 && tmp[n - 1] != ':') tmp[n++] = ':';
        unsigned v = g[i];
        int started = 0;
        for (int shift = 12; shift >= 0; shift -= 4) {
            unsigned d = (v >> shift) & 0xF;
            if (d || started || shift == 0) { tmp[n++] = hex[d]; started = 1; }
        }
        i++;
    }
    if (quad) {
        if (n > 0 && tmp[n - 1] != ':') tmp[n++] = ':';
        char q[16];
        long k = ipv4_to_text(addr + 12, q, sizeof q);
        for (long t = 0; t < k; t++) tmp[n++] = q[t];
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

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int ipv6_from_text(const char *text, uint8_t out[16]) {
    if (!text || !out) return 0;
    uint8_t v[16];
    int n = 0;      /* bytes written */
    int gap = -1;   /* byte position of "::" */
    const char *p = text;
    if (p[0] == ':') {
        if (p[1] != ':') return 0;
        gap = 0;
        p += 2;
        if (*p == 0) goto done;
    }
    for (;;) {
        /* One group: hex digits, or a dotted quad that ends the address. */
        const char *start = p;
        unsigned val = 0;
        int digits = 0;
        while (hex_digit(*p) >= 0) {
            if (++digits > 4) return 0;
            val = (val << 4) | (unsigned)hex_digit(*p);
            p++;
        }
        if (*p == '.') {
            if (n > 12) return 0;
            uint8_t q[4];
            if (!ipv4_from_text(start, q)) return 0;
            for (int k = 0; k < 4; k++) v[n++] = q[k];
            break;
        }
        if (digits == 0 || n > 14) return 0;
        v[n++] = (uint8_t)(val >> 8);
        v[n++] = (uint8_t)val;
        if (*p == 0) break;
        if (*p != ':') return 0;
        p++;
        if (*p == ':') {
            if (gap >= 0) return 0;
            gap = n;
            p++;
            if (*p == 0) break;
        } else if (*p == 0) {
            return 0;
        }
    }
done:
    if (gap < 0) {
        if (n != 16) return 0;
    } else {
        if (n > 14) return 0;
        int tail = n - gap;
        for (int k = 0; k < tail; k++) v[15 - k] = v[n - 1 - k];
        for (int k = gap; k < 16 - tail; k++) v[k] = 0;
    }
    for (int k = 0; k < 16; k++) out[k] = v[k];
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

static int hosts_space(char c) { return c == ' ' || c == '\t' || c == '\r'; }
static char hosts_lower(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }

/* Whether the field text[a..b) is `name`, ignoring ASCII case. */
static int hosts_field_is(const char *text, size_t a, size_t b, const char *name) {
    size_t i = 0;
    for (; a + i < b; i++) {
        if (name[i] == 0 || hosts_lower(text[a + i]) != hosts_lower(name[i])) return 0;
    }
    return name[i] == 0;
}

size_t hosts_find_names(const char *text, size_t len, const char *name, uint8_t out[4], const char **names) {
    if (!text || !name || !out || !names || name[0] == 0) return 0;
    size_t pos = 0;
    while (pos < len) {
        size_t end = pos;
        while (end < len && text[end] != '\n') end++;
        size_t stop = pos;
        while (stop < end && text[stop] != '#') stop++;
        size_t i = pos;
        while (i < stop && hosts_space(text[i])) i++;
        size_t a = i;
        while (i < stop && !hosts_space(text[i])) i++;
        char addr_text[16];
        uint8_t addr[4];
        if (i > a && i - a < sizeof(addr_text)) {
            for (size_t k = 0; k < i - a; k++) addr_text[k] = text[a + k];
            addr_text[i - a] = 0;
            if (ipv4_from_text(addr_text, addr)) {
                while (i < stop && hosts_space(text[i])) i++;
                size_t first = i, last = i;
                int hit = 0;
                while (i < stop) {
                    while (i < stop && hosts_space(text[i])) i++;
                    size_t f = i;
                    while (i < stop && !hosts_space(text[i])) i++;
                    if (i > f) {
                        last = i;
                        if (hosts_field_is(text, f, i, name)) hit = 1;
                    }
                }
                if (hit) {
                    for (int k = 0; k < 4; k++) out[k] = addr[k];
                    *names = text + first;
                    return last - first;
                }
            }
        }
        pos = end + 1;
    }
    return 0;
}

int hosts_find(const char *text, size_t len, const char *name, uint8_t out[4]) {
    const char *names = (const char *)0;
    return hosts_find_names(text, len, name, out, &names) > 0;
}

size_t hosts_collect(const char *text, size_t len, const char *name, int family, struct hosts_addr *out, size_t cap,
                     const char **names, size_t *names_len) {
    if (!text || !name || !out || name[0] == 0) return 0;
    size_t count = 0;
    int have_names = 0;
    /* Pass 0 takes the IPv6 lines, pass 1 the IPv4 lines; the names come from the first matching line in file order. */
    for (int pass = 0; pass < 2; pass++) {
        int want = pass == 0 ? AF_INET6 : AF_INET;
        if (family != AF_UNSPEC && family != want) continue;
        size_t pos = 0;
        while (pos < len) {
            size_t end = pos;
            while (end < len && text[end] != '\n') end++;
            size_t stop = pos;
            while (stop < end && text[stop] != '#') stop++;
            size_t i = pos;
            while (i < stop && hosts_space(text[i])) i++;
            size_t a = i;
            while (i < stop && !hosts_space(text[i])) i++;
            char addr_text[48];
            struct hosts_addr h;
            int ok = 0;
            if (i > a && i - a < sizeof(addr_text)) {
                for (size_t k = 0; k < i - a; k++) addr_text[k] = text[a + k];
                addr_text[i - a] = 0;
                memset(&h, 0, sizeof h);
                if (want == AF_INET && ipv4_from_text(addr_text, h.addr)) ok = 1;
                if (want == AF_INET6 && ipv6_from_text(addr_text, h.addr)) ok = 1;
                h.family = want;
            }
            if (ok) {
                while (i < stop && hosts_space(text[i])) i++;
                size_t first = i, last = i;
                int hit = 0;
                while (i < stop) {
                    while (i < stop && hosts_space(text[i])) i++;
                    size_t f = i;
                    while (i < stop && !hosts_space(text[i])) i++;
                    if (i > f) {
                        last = i;
                        if (hosts_field_is(text, f, i, name)) hit = 1;
                    }
                }
                if (hit) {
                    if (count < cap) out[count++] = h;
                    if (names && names_len && (!have_names || a < (size_t)(*names - text))) {
                        *names = text + first;
                        *names_len = last - first;
                        have_names = 1;
                    }
                }
            }
            pos = end + 1;
        }
    }
    return count;
}

/* The whole names field of the first line whose address, parsed for `family`, is the `alen` bytes of `want`. */
static size_t hosts_reverse_line(const char *text, size_t len, int family, const uint8_t *want, size_t alen, const char **names) {
    if (!text || !want || !names) return 0;
    size_t pos = 0;
    while (pos < len) {
        size_t end = pos;
        while (end < len && text[end] != '\n') end++;
        size_t stop = pos;
        while (stop < end && text[stop] != '#') stop++;
        size_t i = pos;
        while (i < stop && hosts_space(text[i])) i++;
        size_t a = i;
        while (i < stop && !hosts_space(text[i])) i++;
        char addr_text[48];
        uint8_t addr[16];
        if (i > a && i - a < sizeof(addr_text)) {
            for (size_t k = 0; k < i - a; k++) addr_text[k] = text[a + k];
            addr_text[i - a] = 0;
            int ok = family == AF_INET6 ? ipv6_from_text(addr_text, addr) : ipv4_from_text(addr_text, addr);
            if (ok && memcmp(addr, want, alen) == 0) {
                while (i < stop && hosts_space(text[i])) i++;
                size_t first = i, last = i;
                while (i < stop) {
                    while (i < stop && hosts_space(text[i])) i++;
                    size_t f = i;
                    while (i < stop && !hosts_space(text[i])) i++;
                    if (i > f) last = i;
                }
                if (last > first) {
                    *names = text + first;
                    return last - first;
                }
            }
        }
        pos = end + 1;
    }
    return 0;
}

static size_t hosts_reverse_any(const char *text, size_t len, int family, const uint8_t *want, size_t alen, const char **name) {
    const char *names = (const char *)0;
    size_t n = hosts_reverse_line(text, len, family, want, alen, &names);
    if (!n) return 0;
    size_t first = 0;
    while (first < n && !hosts_space(names[first])) first++;
    *name = names;
    return first;
}

size_t hosts_reverse_names(const char *text, size_t len, int family, const uint8_t *addr, const char **names) {
    if (family == AF_INET) return hosts_reverse_line(text, len, family, addr, 4, names);
    if (family == AF_INET6) return hosts_reverse_line(text, len, family, addr, 16, names);
    return 0;
}

size_t hosts_reverse(const char *text, size_t len, const uint8_t want[4], const char **name) {
    return hosts_reverse_any(text, len, AF_INET, want, 4, name);
}

size_t hosts_reverse6(const char *text, size_t len, const uint8_t want[16], const char **name) {
    return hosts_reverse_any(text, len, AF_INET6, want, 16, name);
}

/* The host test links netdb.o without the file system: there /etc/hosts is never read. */
#define ETC_HOSTS_MAX 8192
#ifdef MOQI_HOST_TEST_SYSCALL
static size_t etc_hosts_read_into(char *buf, size_t cap) { (void)buf; (void)cap; return 0; }
#else
/* Read up to `cap` bytes of /etc/hosts into `buf`; 0 when there is no file. The reentrant lookups pass a buffer of their own. */
static size_t etc_hosts_read_into(char *buf, size_t cap) {
    long fd = syscall3(SYS_open, (long)"/etc/hosts", 0 /* O_RDONLY */, 0);
    if (fd < 0) return 0;
    long n = 0;
    while (n < (long)cap) {
        long r = syscall3(SYS_read, fd, (long)(buf + n), (long)cap - n);
        if (r <= 0) break;
        n += r;
    }
    syscall1(SYS_close, fd);
    return (size_t)n;
}
#endif
static char etc_hosts_buf[ETC_HOSTS_MAX];
static size_t etc_hosts_read(void) { return etc_hosts_read_into(etc_hosts_buf, sizeof etc_hosts_buf); }

/* /etc/hosts first, then the kernel resolver (glibc's "files dns" order). When the file answers and `names` is given, the
 * matching line's names (canonical name first, then aliases, separated by blanks) are copied there NUL-terminated, cut to `cap`;
 * otherwise names[0] is 0. */
static long lookup_ipv4(const char *name, uint8_t out[4], char *names, size_t cap) {
    if (names && cap) names[0] = 0;
    size_t n = etc_hosts_read();
    const char *found = (const char *)0;
    size_t k = n ? hosts_find_names(etc_hosts_buf, n, name, out, &found) : 0;
    if (k > 0) {
        if (names && cap) {
            if (k >= cap) k = cap - 1;
            memcpy(names, found, k);
            names[k] = 0;
        }
        return 0;
    }
    return gethostbyname_ipv4(name, out);
}

long resolve_ipv4_sockaddr(const char *host, uint16_t port, uint8_t out[16]) {
    if (!host || !out) return -22; /* EINVAL */
    uint8_t addr[4];
    if (!ipv4_from_text(host, addr)) {
        long r = lookup_ipv4(host, addr, (char *)0, 0);
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

#include "../include/errno.h"

int h_errno;

#define HOSTENT_NAME_MAX 256
#define HOSTENT_ADDRS_MAX 16
#define HOSTENT_ALIASES_MAX 16

int hostent_pack(struct hostent *he, char *buf, size_t buf_len, const char *names, size_t names_len, int af,
                 const char *const *addrs, size_t naddrs) {
    size_t alen = af == AF_INET6 ? 16 : 4;
    size_t naliases = 0;
    for (size_t i = 0; i < names_len;) {
        while (i < names_len && (names[i] == ' ' || names[i] == '\t')) i++;
        if (i >= names_len) break;
        naliases++;
        while (i < names_len && names[i] != ' ' && names[i] != '\t') i++;
    }
    if (naliases) naliases--; /* the first name is h_name */
    size_t lead = (size_t)(-(uintptr_t)buf & (sizeof(char *) - 1));
    size_t ptrs = (naliases + 1 + naddrs + 1) * sizeof(char *);
    size_t need = lead + ptrs + naddrs * alen + names_len + 1;
    if (!buf || need > buf_len) return ERANGE;
    char **aliases = (char **)(void *)(buf + lead);
    char **list = aliases + naliases + 1;
    char *data = (char *)(list + naddrs + 1);
    for (size_t k = 0; k < naddrs; k++) {
        memcpy(data, addrs[k], alen);
        list[k] = data;
        data += alen;
    }
    list[naddrs] = (char *)0;
    memcpy(data, names, names_len);
    data[names_len] = 0;
    /* Split in place: the first field is the name, the others are aliases. */
    char *p = data;
    while (*p == ' ' || *p == '\t') p++;
    char *name = p;
    size_t a = 0;
    while (*p && *p != ' ' && *p != '\t') p++;
    while (*p) {
        *p++ = 0;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        aliases[a++] = p;
        while (*p && *p != ' ' && *p != '\t') p++;
    }
    aliases[a] = (char *)0;
    he->h_name = name;
    he->h_aliases = aliases;
    he->h_addrtype = af;
    he->h_length = (int)alen;
    he->h_addr_list = list;
    return 0;
}

/* The answer of a lookup before it is laid out: the names field (canonical name, then aliases) and the addresses. `herr` is
 * the h_errno value and `rc` the reentrant return value (0, EAFNOSUPPORT or EAGAIN); `names` is NULL on a failure. */
struct host_answer {
    const char *names;
    size_t names_len;
    char name_store[HOSTENT_NAME_MAX];
    uint8_t addrs[HOSTENT_ADDRS_MAX][16];
    size_t naddrs;
    int af;
    int herr;
    int rc;
};

/* `hosts`/`hosts_cap` is the scratch space for /etc/hosts text: the static functions pass etc_hosts_buf, the reentrant ones a
 * buffer of their own, so the two never share state. */
static void lookup_name(const char *name, int af, char *hosts, size_t hosts_cap, struct host_answer *ans) {
    ans->names = (const char *)0;
    ans->names_len = 0;
    ans->naddrs = 0;
    ans->af = af;
    ans->rc = 0;
    if (!name) {
        ans->herr = HOST_NOT_FOUND;
        return;
    }
    if (af != AF_INET && af != AF_INET6) {
        ans->herr = NO_DATA; /* glibc answers another family with NO_DATA (measured) */
        ans->rc = EAFNOSUPPORT;
        return;
    }
    size_t alen = af == AF_INET6 ? 16 : 4;
    uint8_t lit[16];
    int is_v4 = ipv4_from_text(name, lit), is_v6 = !is_v4 && ipv6_from_text(name, lit);
    if (is_v4 || is_v6) {
        /* A literal answers only its own family, and is its own name. */
        if ((af == AF_INET) != is_v4) {
            ans->herr = HOST_NOT_FOUND;
            return;
        }
        memcpy(ans->addrs[0], lit, alen);
        ans->naddrs = 1;
    } else {
        /* Every /etc/hosts line of this family in file order; the names come from the first one. */
        size_t n = etc_hosts_read_into(hosts, hosts_cap);
        struct hosts_addr found[HOSTENT_ADDRS_MAX];
        const char *names = (const char *)0;
        size_t names_len = 0;
        size_t k = n ? hosts_collect(hosts, n, name, af, found, HOSTENT_ADDRS_MAX, &names, &names_len) : 0;
        if (k) {
            for (size_t i = 0; i < k; i++) memcpy(ans->addrs[i], found[i].addr, alen);
            ans->naddrs = k;
            if (names_len >= HOSTENT_NAME_MAX) names_len = HOSTENT_NAME_MAX - 1;
            memcpy(ans->name_store, names, names_len);
            ans->names = ans->name_store;
            ans->names_len = names_len;
        } else if (af == AF_INET6) {
            ans->herr = HOST_NOT_FOUND; /* the kernel resolver has no AAAA records */
            return;
        } else {
            long r = gethostbyname_ipv4(name, ans->addrs[0]);
            if (r < 0) {
                /* A name that does not exist, is malformed, or is too long is a definitive "no such host"; a timeout or any
                 * other failure is worth retrying. */
                if (r == -2 /* ENOENT */ || r == -22 /* EINVAL */ || r == -36 /* ENAMETOOLONG */) {
                    ans->herr = HOST_NOT_FOUND;
                } else {
                    ans->herr = TRY_AGAIN;
                    ans->rc = EAGAIN;
                }
                return;
            }
            ans->naddrs = 1;
        }
    }
    if (!ans->names) {
        size_t n = 0;
        while (name[n] && n + 1 < HOSTENT_NAME_MAX) n++;
        memcpy(ans->name_store, name, n);
        ans->names = ans->name_store;
        ans->names_len = n;
    }
    ans->herr = 0;
}

static void lookup_addr(const void *addr, unsigned int len, int family, char *hosts, size_t hosts_cap, struct host_answer *ans) {
    ans->names = (const char *)0;
    ans->names_len = 0;
    ans->naddrs = 0;
    ans->rc = 0;
    int requested_family = family;
    if (family == AF_UNSPEC) {
        if (len == 4) family = AF_INET;
        else if (len == 16) family = AF_INET6;
    }
    ans->af = family;
    if (family != AF_INET && family != AF_INET6) {
        ans->herr = NETDB_INTERNAL;
        ans->rc = EAFNOSUPPORT;
        return;
    }
    size_t alen = family == AF_INET6 ? 16 : 4;
    if (len < alen) {
        ans->herr = NETDB_INTERNAL;
        ans->rc = EAFNOSUPPORT;
        return;
    }
    if (len > alen) {
        ans->herr = TRY_AGAIN;
        return;
    }
    if (!addr) {
        /* glibc dereferences this; fail cleanly instead. */
        ans->herr = HOST_NOT_FOUND;
        return;
    }
    const uint8_t *query = (const uint8_t *)addr;
    int query_family = family;
    static const uint8_t mapped_prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF};
    if (family == AF_INET6 && memcmp(query, mapped_prefix, 12) == 0) {
        /* ::ffff:a.b.c.d is named from the IPv4 lines but answered with the address asked for (glibc, measured). */
        query_family = AF_INET;
        query += 12;
    }
    size_t n = etc_hosts_read_into(hosts, hosts_cap);
    const char *names = (const char *)0;
    size_t names_len = n ? hosts_reverse_names(hosts, n, query_family, query, &names) : 0;
    if (!names_len) {
        if (requested_family == AF_UNSPEC) {
            ans->herr = NETDB_INTERNAL;
            ans->rc = EAFNOSUPPORT;
        } else {
            ans->herr = HOST_NOT_FOUND;
        }
        return;
    }
    if (names_len >= HOSTENT_NAME_MAX) names_len = HOSTENT_NAME_MAX - 1;
    memcpy(ans->name_store, names, names_len);
    ans->names = ans->name_store;
    ans->names_len = names_len;
    memcpy(ans->addrs[0], addr, alen);
    ans->naddrs = 1;
    ans->herr = 0;
}

/* The static functions: one result in static storage, overwritten by the next call (as in glibc); not thread-safe. Its buffer
 * is large enough for any answer (16 addresses of 16 bytes, a 255-byte names field). */
static struct hostent hostent_result;
static union {
    char *align;
    char bytes[(HOSTENT_NAME_MAX / 2 + 2 + HOSTENT_ADDRS_MAX + 1) * sizeof(char *) + HOSTENT_ADDRS_MAX * 16 + HOSTENT_NAME_MAX + 8];
} hostent_store;

/* The static result keeps the first HOSTENT_ALIASES_MAX aliases: the length of `names` up to the field after them. */
static size_t names_capped(const char *names, size_t len) {
    size_t fields = 0;
    for (size_t i = 0; i < len;) {
        while (i < len && (names[i] == ' ' || names[i] == '\t')) i++;
        if (i >= len) break;
        if (fields == HOSTENT_ALIASES_MAX + 1) return i;
        fields++;
        while (i < len && names[i] != ' ' && names[i] != '\t') i++;
    }
    return len;
}

static struct hostent *static_result(struct host_answer *ans) {
    if (!ans->names) {
        h_errno = ans->herr;
        if (ans->rc == EAFNOSUPPORT && ans->herr == NETDB_INTERNAL) errno = EAFNOSUPPORT;
        return (struct hostent *)0;
    }
    const char *list[HOSTENT_ADDRS_MAX];
    for (size_t k = 0; k < ans->naddrs; k++) list[k] = (const char *)ans->addrs[k];
    size_t len = names_capped(ans->names, ans->names_len);
    if (hostent_pack(&hostent_result, hostent_store.bytes, sizeof hostent_store.bytes, ans->names, len, ans->af, list,
                     ans->naddrs) != 0) {
        h_errno = NETDB_INTERNAL; /* cannot happen: the store holds the largest answer */
        return (struct hostent *)0;
    }
    h_errno = 0;
    return &hostent_result;
}

struct hostent *gethostbyname2(const char *name, int af) {
    struct host_answer ans;
    lookup_name(name, af, etc_hosts_buf, sizeof etc_hosts_buf, &ans);
    return static_result(&ans);
}

struct hostent *gethostbyname(const char *name) { return gethostbyname2(name, AF_INET); }

struct hostent *gethostbyaddr(const void *addr, unsigned int len, int family) {
    struct host_answer ans;
    lookup_addr(addr, len, family, etc_hosts_buf, sizeof etc_hosts_buf, &ans);
    return static_result(&ans);
}

/* Turn an answer into the reentrant return value: lay it out in the caller's buffer, or report ERANGE when it does not fit. */
static int reentrant_result(struct host_answer *ans, struct hostent *ret, char *buf, size_t buflen, struct hostent **result,
                            int *h_errnop) {
    if (result) *result = (struct hostent *)0;
    int rc = ans->rc;
    int herr = ans->herr;
    if (ans->names) {
        const char *list[HOSTENT_ADDRS_MAX];
        for (size_t k = 0; k < ans->naddrs; k++) list[k] = (const char *)ans->addrs[k];
        if (ret && hostent_pack(ret, buf, buflen, ans->names, ans->names_len, ans->af, list, ans->naddrs) == 0) {
            if (result) *result = ret;
            herr = 0;
        } else {
            rc = ERANGE;
            herr = NETDB_INTERNAL;
        }
    }
    if (h_errnop) *h_errnop = herr;
    if (rc) errno = rc;
    return rc;
}

/* The reentrant functions read /etc/hosts into ETC_HOSTS_MAX bytes of their own stack (the 64 KiB pthread stacks have room),
 * so concurrent calls share no state. */
int gethostbyname2_r(const char *name, int af, struct hostent *ret, char *buf, size_t buflen, struct hostent **result,
                     int *h_errnop) {
    char hosts[ETC_HOSTS_MAX];
    struct host_answer ans;
    lookup_name(name, af, hosts, sizeof hosts, &ans);
    return reentrant_result(&ans, ret, buf, buflen, result, h_errnop);
}

int gethostbyname_r(const char *name, struct hostent *ret, char *buf, size_t buflen, struct hostent **result, int *h_errnop) {
    return gethostbyname2_r(name, AF_INET, ret, buf, buflen, result, h_errnop);
}

int gethostbyaddr_r(const void *addr, unsigned int len, int family, struct hostent *ret, char *buf, size_t buflen,
                    struct hostent **result, int *h_errnop) {
    char hosts[ETC_HOSTS_MAX];
    struct host_answer ans;
    lookup_addr(addr, len, family, hosts, sizeof hosts, &ans);
    return reentrant_result(&ans, ret, buf, buflen, result, h_errnop);
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

static struct addrinfo *make_entry(const struct hosts_addr *a, uint32_t scope, uint16_t port, int socktype, int protocol,
                                   int flags, const char *canon) {
    struct addrinfo *e = (struct addrinfo *)malloc(sizeof(struct addrinfo));
    if (!e) return (struct addrinfo *)0;
    memset(e, 0, sizeof(*e));
    unsigned int len = a->family == AF_INET6 ? 28 : 16;
    e->ai_addr = (uint8_t *)malloc(len);
    if (!e->ai_addr) { free(e); return (struct addrinfo *)0; }
    if (a->family == AF_INET6) {
        /* Linux struct sockaddr_in6: family (u16, host order), port (network order), flowinfo, address, scope id (host order). */
        memset(e->ai_addr, 0, len);
        e->ai_addr[0] = AF_INET6;
        uint16_t be = htons(port);
        e->ai_addr[2] = (uint8_t)(be & 0xFF);
        e->ai_addr[3] = (uint8_t)(be >> 8);
        memcpy(e->ai_addr + 8, a->addr, 16);
        for (int k = 0; k < 4; k++) e->ai_addr[24 + k] = (uint8_t)(scope >> (8 * k));
    } else {
        ipv4_sockaddr(a->addr, port, e->ai_addr);
    }
    e->ai_flags = flags;
    e->ai_family = a->family;
    e->ai_socktype = socktype;
    e->ai_protocol = protocol;
    e->ai_addrlen = len;
    if (canon) {
        size_t n = strlen(canon);
        e->ai_canonname = (char *)malloc(n + 1);
        if (!e->ai_canonname) { free(e->ai_addr); free(e); return (struct addrinfo *)0; }
        memcpy(e->ai_canonname, canon, n + 1);
    }
    return e;
}

static void set_v4(struct hosts_addr *a, uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3) {
    memset(a, 0, sizeof(*a));
    a->family = AF_INET;
    a->addr[0] = b0; a->addr[1] = b1; a->addr[2] = b2; a->addr[3] = b3;
}

/* ::ffff:a.b.c.d for an IPv4 address (AI_V4MAPPED). */
static void map_v4(struct hosts_addr *a) {
    uint8_t v4[4];
    memcpy(v4, a->addr, 4);
    memset(a->addr, 0, 16);
    a->addr[10] = 0xFF;
    a->addr[11] = 0xFF;
    memcpy(a->addr + 12, v4, 4);
    a->family = AF_INET6;
}

/* "addr%scope" with a numeric scope (inet_pton plus glibc's strtoul check). 1 = parsed, 0 = not this form. */
static int scoped_ipv6(const char *node, uint8_t out[16], uint32_t *scope) {
    const char *pct = strchr(node, '%');
    if (!pct) return 0;
    size_t n = (size_t)(pct - node);
    char text[48];
    if (n == 0 || n >= sizeof(text)) return 0;
    memcpy(text, node, n);
    text[n] = 0;
    const char *d = pct + 1;
    if (*d == 0) return 0;
    uint64_t v = 0;
    for (; *d; d++) {
        if (*d < '0' || *d > '9') return 0;
        v = v * 10 + (uint64_t)(*d - '0');
        if (v > 0xFFFFFFFFu) return 0;
    }
    if (!ipv6_from_text(text, out)) return 0;
    *scope = (uint32_t)v;
    return 1;
}

#define GAI_MAX_ADDRS 16

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    int flags = 0, family = AF_UNSPEC, socktype = 0, protocol = 0;
    if (hints) {
        flags = hints->ai_flags;
        family = hints->ai_family;
        socktype = hints->ai_socktype;
        protocol = hints->ai_protocol;
    }
    /* The caller's flags are validated; AI_ADDRCONFIG is accepted and ignored. */
    const int known_flags = AI_PASSIVE | AI_CANONNAME | AI_NUMERICHOST | AI_NUMERICSERV | AI_V4MAPPED | AI_ALL | AI_ADDRCONFIG;
    if (flags & ~known_flags) return EAI_BADFLAGS;
    /* With no hints at all glibc echoes 0x40 in the entries (its internal default); mirror that. */
    int echoed_flags = hints ? flags : 0x40;
    if ((flags & AI_CANONNAME) && !node) return EAI_BADFLAGS;
    if (!node && !service) return EAI_NONAME;
    if (family != AF_UNSPEC && family != AF_INET && family != AF_INET6) return EAI_FAMILY;

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

    struct hosts_addr addrs[GAI_MAX_ADDRS];
    size_t naddrs = 0;
    uint32_t scope = 0;
    const char *canon = (const char *)0;
    char canon_buf[256];
    uint8_t v4[4];
    if (!node) {
        /* Loopback, or the wildcard with AI_PASSIVE; AF_UNSPEC gives both families in glibc's order (loopback interface up). */
        int passive = (flags & AI_PASSIVE) != 0;
        struct hosts_addr six;
        memset(&six, 0, sizeof six);
        six.family = AF_INET6;
        if (!passive) six.addr[15] = 1;
        struct hosts_addr four;
        if (passive) set_v4(&four, 0, 0, 0, 0);
        else set_v4(&four, 127, 0, 0, 1);
        if (family == AF_INET6) addrs[naddrs++] = six;
        else if (family == AF_INET) addrs[naddrs++] = four;
        else if (passive) { addrs[naddrs++] = four; addrs[naddrs++] = six; }
        else { addrs[naddrs++] = six; addrs[naddrs++] = four; }
    } else if (ipv4_from_text(node, v4)) {
        set_v4(&addrs[0], v4[0], v4[1], v4[2], v4[3]);
        if (family == AF_INET6) {
            if (!(flags & AI_V4MAPPED)) return EAI_ADDRFAMILY;
            map_v4(&addrs[0]);
        }
        naddrs = 1;
        if (flags & AI_CANONNAME) canon = node;
    } else if (ipv6_from_text(node, addrs[0].addr) || scoped_ipv6(node, addrs[0].addr, &scope)) {
        if (family == AF_INET) return EAI_ADDRFAMILY;
        addrs[0].family = AF_INET6;
        naddrs = 1;
        if (flags & AI_CANONNAME) canon = node;
    } else {
        if (flags & AI_NUMERICHOST) return EAI_NONAME;
        if (strchr(node, '%')) return EAI_NONAME; /* a scope this library cannot parse (interface names need if_nametoindex) */
        /* /etc/hosts first. Under AF_INET6, IPv4 lines are used only with AI_V4MAPPED: when there is no IPv6 line, or always
         * with AI_ALL, and then as ::ffff:a.b.c.d after the IPv6 ones (glibc, measured). */
        size_t n = etc_hosts_read();
        const char *names = (const char *)0;
        size_t names_len = 0;
        if (n) {
            if (family == AF_INET6) {
                naddrs = hosts_collect(etc_hosts_buf, n, node, AF_INET6, addrs, GAI_MAX_ADDRS, &names, &names_len);
                if ((flags & AI_V4MAPPED) && (naddrs == 0 || (flags & AI_ALL))) {
                    const char *names4 = (const char *)0;
                    size_t len4 = 0;
                    size_t m = hosts_collect(etc_hosts_buf, n, node, AF_INET, addrs + naddrs, GAI_MAX_ADDRS - naddrs, &names4, &len4);
                    for (size_t k = 0; k < m; k++) map_v4(&addrs[naddrs + k]);
                    if (m && (!names || names4 < names)) { names = names4; names_len = len4; }
                    naddrs += m;
                }
            } else {
                naddrs = hosts_collect(etc_hosts_buf, n, node, family, addrs, GAI_MAX_ADDRS, &names, &names_len);
            }
        }
        if (naddrs == 0) {
            /* The kernel resolver answers A records only. */
            if (family == AF_INET6 && !(flags & AI_V4MAPPED)) return EAI_NONAME;
            long r = gethostbyname_ipv4(node, v4);
            if (r < 0) return (r == -2 || r == -22 || r == -36) ? EAI_NONAME : EAI_AGAIN;
            set_v4(&addrs[0], v4[0], v4[1], v4[2], v4[3]);
            if (family == AF_INET6) map_v4(&addrs[0]);
            naddrs = 1;
            names = (const char *)0;
        }
        if (flags & AI_CANONNAME) {
            /* A name from /etc/hosts is canonicalised to the line's first name, as glibc does. */
            canon = node;
            if (names) {
                size_t k = 0;
                while (k < names_len && k + 1 < sizeof(canon_buf) && names[k] != ' ' && names[k] != '\t') {
                    canon_buf[k] = names[k];
                    k++;
                }
                canon_buf[k] = 0;
                if (k) canon = canon_buf;
            }
        }
    }

    struct addrinfo *head = (struct addrinfo *)0, **tail = &head;
    for (size_t a = 0; a < naddrs; a++) {
        for (int i = 0; i < ntypes; i++) {
            /* Only the first entry carries the canonical name, as in glibc. */
            int first = a == 0 && i == 0;
            struct addrinfo *e = make_entry(&addrs[a], scope, port, types[i], protos[i], echoed_flags, first ? canon : (const char *)0);
            if (!e) { freeaddrinfo(head); return EAI_MEMORY; }
            *tail = e;
            tail = &e->ai_next;
        }
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
    if (!sa || salen < 2) return EAI_FAMILY;
    int v6 = sa[0] == AF_INET6 && sa[1] == 0;
    if (v6 ? salen < 28 : (salen < 16 || sa[0] != AF_INET || sa[1] != 0)) return EAI_FAMILY;
    uint16_t port = (uint16_t)(((unsigned)sa[2] << 8) | sa[3]);
    const uint8_t *addr = v6 ? sa + 8 : sa + 4;

    if (host && hostlen > 0) {
        const char *text = (const char *)0;
        char numeric[64];
        char found[NI_MAXHOST];
        if (!(flags & NI_NUMERICHOST)) {
            size_t n = etc_hosts_read();
            const char *name = (const char *)0;
            size_t k = 0;
            static const uint8_t mapped_prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF};
            static const uint8_t loop6[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
            if (!v6) {
                k = n ? hosts_reverse(etc_hosts_buf, n, addr, &name) : 0;
            } else if (memcmp(addr, mapped_prefix, 12) == 0) {
                /* ::ffff:a.b.c.d is named from the IPv4 lines (glibc, measured). */
                k = n ? hosts_reverse(etc_hosts_buf, n, addr + 12, &name) : 0;
            } else {
                k = n ? hosts_reverse6(etc_hosts_buf, n, addr, &name) : 0;
            }
            if (k > 0 && k < sizeof(found)) {
                memcpy(found, name, k);
                found[k] = 0;
                text = found;
            } else if (!v6 && addr[0] == 127 && addr[1] == 0 && addr[2] == 0 && addr[3] == 1) {
                text = "localhost";
            } else if (v6 && memcmp(addr, loop6, 16) == 0) {
                text = "localhost";
            }
        }
        if (!text) {
            if (flags & NI_NAMEREQD) return EAI_NONAME;
            long len = v6 ? ipv6_to_text(addr, numeric, sizeof(numeric)) : ipv4_to_text(addr, numeric, sizeof(numeric));
            uint32_t scope = v6 ? ((uint32_t)sa[24] | (uint32_t)sa[25] << 8 | (uint32_t)sa[26] << 16 | (uint32_t)sa[27] << 24) : 0;
            if (scope) {
                /* A non-zero sin6_scope_id is appended as "%N" (numeric; interface names need if_indextoname). */
                char d[11];
                int nd = 0;
                do { d[nd++] = (char)('0' + scope % 10); scope /= 10; } while (scope);
                numeric[len++] = '%';
                while (nd) numeric[len++] = d[--nd];
                numeric[len] = 0;
            }
            text = numeric;
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
