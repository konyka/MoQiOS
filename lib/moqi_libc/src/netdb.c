/* netdb.c — hostname resolution wrappers (see include/netdb.h). */
#include "../include/netdb.h"
#include "../include/byteorder.h"
#include "../include/errno.h"

/* The host unit test links this file against a recording stub instead of the real `syscall` instruction. */
#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall2(long nr, long a1, long a2);
#define NETDB_SYSCALL2(nr, a1, a2) moqi_test_syscall2((nr), (a1), (a2))
#else
#define NETDB_SYSCALL2(nr, a1, a2) syscall2((nr), (a1), (a2))
#endif

/* The socket syscalls only exist on the target; the host unit test links a recording stub instead. */
#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall3(long nr, long a1, long a2, long a3);
extern long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6);
#define NETDB_SYSCALL3(nr, a1, a2, a3) moqi_test_syscall3((nr), (a1), (a2), (a3))
#define NETDB_SYSCALL6(nr, a1, a2, a3, a4, a5, a6) moqi_test_syscall6((nr), (a1), (a2), (a3), (a4), (a5), (a6))
#define NETDB_SYSCALL1(nr, a1) moqi_test_syscall3((nr), (a1), 0, 0)
#else
#define NETDB_SYSCALL3(nr, a1, a2, a3) syscall3((nr), (a1), (a2), (a3))
#define NETDB_SYSCALL6(nr, a1, a2, a3, a4, a5, a6) syscall6((nr), (a1), (a2), (a3), (a4), (a5), (a6))
#define NETDB_SYSCALL1(nr, a1) syscall1((nr), (a1))
#endif

static int resolv_blank(char c) { return c == ' ' || c == '\t'; }

size_t resolv_conf_servers(const char *text, size_t len, uint8_t out[][4], size_t cap) {
    static const char kw[] = "nameserver";
    const size_t kl = sizeof kw - 1;
    size_t count = 0, pos = 0;
    while (text && pos < len && count < cap) {
        size_t end = pos;
        while (end < len && text[end] != '\n') end++;
        /* The keyword must start the line, in lower case, and be followed by a blank. */
        if (end - pos > kl && memcmp(text + pos, kw, kl) == 0 && resolv_blank(text[pos + kl])) {
            size_t i = pos + kl;
            while (i < end && resolv_blank(text[i])) i++;
            size_t a = i;
            while (i < end && !resolv_blank(text[i])) i++;
            char addr[16];
            uint8_t ip[4];
            if (i > a && i - a < sizeof addr) {
                memcpy(addr, text + a, i - a);
                addr[i - a] = 0;
                int unicast = 1;
                if (ipv4_from_text(addr, ip)) {
                    if ((ip[0] | ip[1] | ip[2] | ip[3]) == 0) unicast = 0;
                    if ((ip[0] & ip[1] & ip[2] & ip[3]) == 255) unicast = 0;
                    if (ip[0] >= 224 && ip[0] <= 239) unicast = 0;
                    if (unicast) memcpy(out[count++], ip, 4);
                }
            }
        }
        pos = end + 1;
    }
    return count;
}

#define RESOLV_MAXNS 3

unsigned int if_nametoindex(const char *name);

/* The interface index of a nameserver's "%scope": all digits as a number (at most 4294967295), else an interface name; 0 when it
 * is neither (glibc 2.44 res_init, measured). */
static uint32_t resolv_scope(const char *s) {
    if (!*s) return 0;
    uint64_t v = 0;
    const char *p = s;
    while (*p >= '0' && *p <= '9') {
        v = v * 10 + (uint64_t)(*p - '0');
        if (v > 0xFFFFFFFFu) return 0;
        p++;
    }
    if (!*p) return (uint32_t)v;
    int saved = errno;
    unsigned idx = if_nametoindex(s);
    errno = saved;
    return idx;
}

size_t resolv_conf_servers_any(const char *text, size_t len, struct resolv_server *out, size_t cap) {
    static const char kw[] = "nameserver";
    const size_t kl = sizeof kw - 1;
    size_t count = 0, pos = 0;
    while (text && pos < len && count < cap) {
        size_t end = pos;
        while (end < len && text[end] != '\n') end++;
        if (end - pos > kl && memcmp(text + pos, kw, kl) == 0 && resolv_blank(text[pos + kl])) {
            size_t i = pos + kl;
            while (i < end && resolv_blank(text[i])) i++;
            size_t a = i;
            while (i < end && !resolv_blank(text[i])) i++;
            char addr[64];
            if (i > a && i - a < sizeof addr) {
                memcpy(addr, text + a, i - a);
                addr[i - a] = 0;
                uint8_t ip[16];
                struct resolv_server *o = &out[count];
                memset(o, 0, sizeof *o);
                if (ipv4_from_text(addr, ip)) {
                    int unicast = (ip[0] | ip[1] | ip[2] | ip[3]) != 0 && (ip[0] & ip[1] & ip[2] & ip[3]) != 255 && !(ip[0] >= 224 && ip[0] <= 239);
                    if (unicast) {
                        o->v6 = 0;
                        memcpy(o->addr, ip, 4);
                        count++;
                    }
                } else {
                    /* glibc keeps every IPv6 nameserver line but :: and multicast (the kernel refuses them). */
                    char *pct = strchr(addr, '%');
                    if (pct) *pct = 0;
                    int nonzero = 0;
                    if (ipv6_from_text(addr, ip)) {
                        for (int k = 0; k < 16; k++) nonzero |= ip[k];
                    }
                    if (nonzero && ip[0] != 0xff) {
                        o->v6 = 1;
                        memcpy(o->addr, ip, 16);
                        if (ip[0] == 0xfe && (ip[1] & 0xc0) == 0x80) {
                            o->scope = pct ? resolv_scope(pct + 1) : 0;
                            o->unusable = o->scope == 0;
                        }
                        count++;
                    }
                }
            }
        }
        pos = end + 1;
    }
    return count;
}

/* Ask `out` of server `sv` through `nr` (507, 508 or 509), with its address in the form the kernel takes: 4 bytes, or 16 with
 * SERVER6_FLAG in the timeout argument. */
#define RESOLV_SERVER6_FLAG 0x80000000L
#define RESOLV_SCOPE6_FLAG 0x40000000L
static long resolv_ask(long nr, long a1, long a2, const struct resolv_server *sv, long wait_ms, long a5, long a6) {
    if (sv->unusable) return -101; /* ENETUNREACH: a link-local server with no interface fails at once, as in glibc */
    long flags = sv->v6 ? RESOLV_SERVER6_FLAG | (sv->scope ? RESOLV_SCOPE6_FLAG : 0) : 0;
    return NETDB_SYSCALL6(nr, a1, a2, (long)sv->addr, wait_ms | flags, a5, a6);
}
#define RESOLV_NAME_MAX 253
#define RESOLV_LABEL_MAX 63

/* The words of the last "search" or "domain" line (a keyword at the start of the line, then a blank or the end of the line); 0
 * words when the last one has none. `opt`: the last ndots:, timeout: and attempts: of the options lines (defaults 1, 5, 2). */
struct resolv_opts { unsigned ndots; int timeout; int attempts; int rotate; int single_request; };

/* "name:N" in an options line: glibc's atoi of what follows the colon (a sign, digits, anything after them ignored). */
static int resolv_opt_value(const char *text, size_t a, size_t i, size_t kl, long *v) {
    size_t d = a + kl;
    int neg = d < i && (text[d] == '-' || text[d] == '+') ? text[d++] == '-' : 0;
    long x = 0;
    while (d < i && text[d] >= '0' && text[d] <= '9' && x < 100000) x = x * 10 + (text[d++] - '0');
    *v = neg ? -x : x;
    return 1;
}

static size_t resolv_conf_search(const char *text, size_t len, const char **word, size_t *word_len, size_t cap, struct resolv_opts *opt) {
    static const char kw_search[] = "search", kw_domain[] = "domain", kw_options[] = "options";
    size_t count = 0, pos = 0;
    opt->ndots = 1;
    opt->timeout = 5;
    opt->attempts = 2;
    opt->rotate = 0;
    opt->single_request = 0;
    while (text && pos < len) {
        size_t end = pos;
        while (end < len && text[end] != '\n') end++;
        size_t kl = 0;
        int list = 0;
        if (end - pos >= 6 && (memcmp(text + pos, kw_search, 6) == 0 || memcmp(text + pos, kw_domain, 6) == 0)) {
            kl = 6;
            list = 1;
        } else if (end - pos >= 7 && memcmp(text + pos, kw_options, 7) == 0) {
            kl = 7;
        }
        if (kl && (pos + kl == end || resolv_blank(text[pos + kl]))) {
            int is_domain = list && text[pos] == 'd';
            if (list) count = 0;
            size_t i = pos + kl;
            while (i < end) {
                while (i < end && resolv_blank(text[i])) i++;
                size_t a = i;
                while (i < end && !resolv_blank(text[i])) i++;
                if (i == a) break;
                if (list) {
                    /* "domain" names one domain; a domain of "." is none. */
                    if (is_domain && count == 1) break;
                    if (is_domain && i - a == 1 && text[a] == '.') break;
                    if (count < cap) {
                        word[count] = text + a;
                        word_len[count] = i - a;
                        count++;
                    }
                } else if (i - a >= 6 && memcmp(text + a, "ndots:", 6) == 0) {
                    /* glibc (measured): above 15 is 15, and the value lands in a 4-bit field ("2x" is 2, "x" is 0, "-1" is 15). */
                    long v;
                    resolv_opt_value(text, a, i, 6, &v);
                    opt->ndots = v > 15 ? 15u : (unsigned)v & 15u;
                } else if (i - a == 6 && memcmp(text + a, "rotate", 6) == 0) {
                    opt->rotate = 1;
                } else if (i - a >= 14 && memcmp(text + a, "single-request", 14) == 0) {
                    /* glibc matches the option by its first 14 characters (measured: "single-request-reopen", "single-requestx" count,
                     * "single-req" does not): the pair of an AF_UNSPEC lookup is asked one after the other. */
                    opt->single_request = 1;
                } else if (i - a >= 8 && memcmp(text + a, "timeout:", 8) == 0) {
                    /* Seconds, at most 30 (RES_MAXRETRANS); 0 or less waits the 1 s minimum. */
                    long v;
                    resolv_opt_value(text, a, i, 8, &v);
                    opt->timeout = v > 30 ? 30 : (int)v;
                } else if (i - a >= 9 && memcmp(text + a, "attempts:", 9) == 0) {
                    /* Rounds over the servers, at most 5 (RES_MAXRETRY); 0 or less asks nobody. */
                    long v;
                    resolv_opt_value(text, a, i, 9, &v);
                    opt->attempts = v > 5 ? 5 : (int)v;
                }
            }
        }
        pos = end + 1;
    }
    return count;
}

/* Whether `name` (`len` bytes) can be sent as a DNS name: at most 253 characters, no label longer than 63 (glibc skips such a
 * search candidate without asking). */
static int resolv_name_fits(const char *name, size_t len) {
    if (len == 0 || len > RESOLV_NAME_MAX) return 0;
    size_t label = 0;
    for (size_t i = 0; i < len; i++) {
        if (name[i] == '.') label = 0;
        else if (++label > RESOLV_LABEL_MAX) return 0;
    }
    return 1;
}

/* Append `name` (with ".dom" when `dom`) to `out`. 0 when the result cannot be a DNS name (over 253 characters or a label over
 * 63): glibc's res_search stops the search list at such a domain (res_querydomain fails, measured). A domain of "" adds nothing. */
static int resolv_add(char out[][256], size_t *n, size_t cap, const char *name, size_t name_len, const char *dom, size_t dom_len) {
    if (*n >= cap) return 1;
    if (dom_len && dom[dom_len - 1] == '.') dom_len--;
    if (dom && dom_len == 0) return 1;
    size_t total = name_len + (dom ? 1 + dom_len : 0);
    char *o = out[*n];
    if (total >= 256) return 0;
    memcpy(o, name, name_len);
    if (dom) {
        o[name_len] = '.';
        memcpy(o + name_len + 1, dom, dom_len);
    }
    o[total] = 0;
    if (!resolv_name_fits(o, total)) return 0;
    (*n)++;
    return 1;
}

size_t resolv_conf_candidates(const char *text, size_t len, const char *name, char out[][256], size_t cap) {
    if (!name || !name[0] || !out || cap == 0) return 0;
    size_t name_len = strlen(name);
    size_t n = 0;
    /* A trailing dot: the name is fully qualified and asked for alone. */
    if (name[name_len - 1] == '.') {
        if (name_len > 1) resolv_add(out, &n, cap, name, name_len - 1, (const char *)0, 0);
        return n;
    }
    const char *word[64];
    size_t word_len[64];
    struct resolv_opts opt;
    size_t nw = resolv_conf_search(text, len, word, word_len, 64, &opt);
    unsigned ndots = opt.ndots;
    unsigned dots = 0;
    for (size_t i = 0; i < name_len; i++) dots += name[i] == '.';
    if (dots >= ndots) resolv_add(out, &n, cap, name, name_len, (const char *)0, 0);
    for (size_t i = 0; i < nw; i++)
        if (!resolv_add(out, &n, cap, name, name_len, word[i], word_len[i])) break;
    if (dots < ndots) resolv_add(out, &n, cap, name, name_len, (const char *)0, 0);
    return n;
}

#ifdef MOQI_HOST_TEST_SYSCALL
/* The host test supplies the file's text (NULL: no file). */
extern const char *moqi_test_resolv_conf;
extern unsigned moqi_test_rotate_seed;
static size_t resolv_conf_read(char *buf, size_t cap) {
    if (!moqi_test_resolv_conf) return 0;
    size_t n = strlen(moqi_test_resolv_conf);
    if (n > cap) n = cap;
    memcpy(buf, moqi_test_resolv_conf, n);
    return n;
}
#else
static size_t resolv_conf_read(char *buf, size_t cap) {
    long fd = syscall3(SYS_open, (long)"/etc/resolv.conf", 0 /* O_RDONLY */, 0);
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

/* How long glibc's res_send waits for server `i` of `nns` in one round (measured): `timeout` seconds for the first, then
 * (timeout << i) / nns, at least 1 s. In milliseconds. */
static long resolv_wait_ms(int timeout, size_t i, size_t nns) {
    long t = timeout;
    if (i > 0 && nns > 0) t = ((long)timeout << i) / (long)nns;
    if (t <= 0) t = 1;
    return t * 1000;
}

/* One name through the nameservers of /etc/resolv.conf with glibc's res_send rules (measured): `attempts` rounds over the servers
 * in file order, each waiting resolv_wait_ms; NXDOMAIN, NODATA and an address end it at once; SERVFAIL, NOTIMP, REFUSED and no
 * reply move on to the next server. -ETIMEDOUT when nobody replied, else the last reply's -EAGAIN (SERVFAIL) or -ECONNREFUSED. With no
 * usable nameserver line, the kernel's own server (DHCP's) through dns_resolve. */
/* "options rotate" (glibc res_send, measured): each query starts at the next server, the first one of the process at a random
 * one; the servers after it follow in file order, and the wait for the i-th asked is as without rotate. Without the option every
 * query starts at the first server. The counter is shared by the threads of a process (glibc keeps it in the resolver state). */
static unsigned resolv_rotate_next;
static int resolv_rotate_seeded;
static size_t resolv_first_server(const struct resolv_opts *opt, size_t nns) {
    if (!opt->rotate || nns < 2) return 0;
    if (!__atomic_load_n(&resolv_rotate_seeded, __ATOMIC_ACQUIRE)) {
        unsigned seed = 0;
#ifdef MOQI_HOST_TEST_SYSCALL
        seed = moqi_test_rotate_seed;
#else
        if (syscall3(SYS_getrandom, (long)&seed, (long)sizeof seed, 0) != (long)sizeof seed) seed = 0;
#endif
        /* Two threads seeding at once both store a random start: either one is fine. */
        int expected = 0;
        if (__atomic_compare_exchange_n(&resolv_rotate_seeded, &expected, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
            __atomic_store_n(&resolv_rotate_next, seed, __ATOMIC_RELEASE);
    }
    return __atomic_fetch_add(&resolv_rotate_next, 1u, __ATOMIC_ACQ_REL) % nns;
}

/* One result for the A and AAAA halves of an AF_UNSPEC pair (0 or -errno each), as glibc 2.44 combines them (measured with every
 * pair of reply codes; the kernel's dns_policy.pairResult is the same rule): either answering is an answer; else an A failure
 * other than NXDOMAIN, NODATA, SERVFAIL or REFUSED wins, then NXDOMAIN from either, then such an AAAA failure, then NODATA, then
 * the A result. */
long resolv_pair_result(long a, long b) {
    if (a == 0 || b == 0) return 0;
    int soft_a = a == -2 || a == -61 || a == -11 || a == -111, soft_b = b == -2 || b == -61 || b == -11 || b == -111;
    if (!soft_a) return a;
    if (a == -2 || b == -2) return -2;
    if (!soft_b) return b;
    if (a == -61 || b == -61) return -61;
    return a;
}

/* dns_query2 (510) for both halves; their results land in pair->r4/r6 and the combined one is returned. */
static long resolv_ask_pair(const char *name, const struct resolv_server *sv, long wait_ms, struct resolv_pair *pair) {
    if (sv->unusable) return pair->r4 = pair->r6 = -101;
    long flags = sv->v6 ? RESOLV_SERVER6_FLAG | (sv->scope ? RESOLV_SCOPE6_FLAG : 0) : 0;
    long r = NETDB_SYSCALL6(SYS_dns_query2, (long)name, (long)sv->addr, wait_ms | flags, (long)pair->a4.buf, (long)pair->a6.buf,
                            (long)sizeof pair->a4.buf);
    if (r < 0) return pair->r4 = pair->r6 = r; /* the call as a whole failed */
    pair->r4 = -(r & 0xff);
    pair->r6 = -((r >> 8) & 0xff);
    pair->a4.len = pair->r4 == 0 ? sizeof pair->a4.buf : 0;
    pair->a6.len = pair->r6 == 0 ? sizeof pair->a6.buf : 0;
    return resolv_pair_result(pair->r4, pair->r6);
}

static long resolve_one(const char *name, uint8_t *out, struct resolv_server *ns, size_t nns, const struct resolv_opts *opt,
                        struct resolv_answer *ans, int af, struct resolv_pair *pair) {
    if (ans) ans->len = 0;
    if (pair) {
        pair->a4.len = pair->a6.len = 0;
        pair->r4 = pair->r6 = -110;
    }
    /* The kernel's own server (no nameserver line) answers A queries only. */
    if (nns == 0) {
        if (pair) {
            pair->r6 = -2;
            pair->r4 = NETDB_SYSCALL2(SYS_dns_resolve, (long)name, (long)out);
            if (pair->r4 == 0) {
                /* The one address under the asked name, in the kernel's answer form. */
                size_t k = strlen(name);
                if (k > 252) k = 252;
                pair->a4.buf[0] = 1; pair->a4.buf[1] = 0; pair->a4.buf[2] = 4;
                memcpy(pair->a4.buf + 3, out, 4);
                memcpy(pair->a4.buf + 7, name, k);
                pair->a4.buf[7 + k] = 0;
                pair->a4.len = 8 + k;
            }
            return resolv_pair_result(pair->r4, pair->r6);
        }
        return af == AF_INET6 ? -2 : NETDB_SYSCALL2(SYS_dns_resolve, (long)name, (long)out);
    }
    long nr = af == AF_INET6 ? SYS_dns_query6 : SYS_dns_query;
    long last_reply = -110; /* ETIMEDOUT: no server replied (or attempts:0 asked nobody) */
    size_t first = resolv_first_server(opt, nns);
    for (int a = 0; a < opt->attempts; a++) {
        for (size_t i = 0; i < nns; i++) {
            long r;
            if (pair && opt->single_request) {
                /* "options single-request": the A query, its reply, then the AAAA query (glibc 2.44, measured); an A query that
                 * gets no reply ends the pair without the AAAA one. */
                const struct resolv_server *sv = &ns[(first + i) % nns];
                long w = resolv_wait_ms(opt->timeout, i, nns);
                uint8_t o16[16];
                pair->r4 = resolv_ask(SYS_dns_query, (long)name, (long)out, sv, w, (long)pair->a4.buf, (long)sizeof pair->a4.buf);
                pair->a4.len = pair->r4 == 0 ? sizeof pair->a4.buf : 0;
                if (pair->r4 == -110 || pair->r4 == -101) {
                    pair->r6 = pair->r4;
                } else {
                    pair->r6 = resolv_ask(SYS_dns_query6, (long)name, (long)o16, sv, w, (long)pair->a6.buf, (long)sizeof pair->a6.buf);
                    pair->a6.len = pair->r6 == 0 ? sizeof pair->a6.buf : 0;
                }
                r = resolv_pair_result(pair->r4, pair->r6);
            } else {
                r = pair ? resolv_ask_pair(name, &ns[(first + i) % nns], resolv_wait_ms(opt->timeout, i, nns), pair)
                         : resolv_ask(nr, (long)name, (long)out, &ns[(first + i) % nns], resolv_wait_ms(opt->timeout, i, nns),
                                      ans ? (long)ans->buf : 0, ans ? (long)sizeof ans->buf : 0);
            }
            if (r == 0 && ans) ans->len = sizeof ans->buf;
            if (r == -11 || r == -111) last_reply = r; /* SERVFAIL; NOTIMP or REFUSED: the last reply is what res_search sees */
            if (r == -11 || r == -111 || r == -110 || r == -101) continue; /* -101: the server cannot be reached, no wait */
            return r; /* an answer, NXDOMAIN, NODATA, another RCODE, or a bad argument */
        }
    }
    return last_reply;
}

#define RESOLV_MAX_CANDIDATES 8

long gethostbyname_ipv4_name(const char *name, uint8_t out[4], char *found, size_t found_cap) {
    return resolv_lookup(name, out, found, found_cap, (struct resolv_answer *)0);
}

long resolv_lookup(const char *name, uint8_t out[4], char *found, size_t found_cap, struct resolv_answer *ans) {
    return resolv_lookup_af(name, AF_INET, out, found, found_cap, ans);
}

static long resolv_search(const char *name, int af, uint8_t *out, char *found, size_t found_cap, struct resolv_answer *ans,
                          struct resolv_pair *pair);

long resolv_lookup_af(const char *name, int af, uint8_t *out, char *found, size_t found_cap, struct resolv_answer *ans) {
    if (!name || !out) return -22; /* EINVAL */
    if (af != AF_INET && af != AF_INET6) return -97; /* EAFNOSUPPORT */
    return resolv_search(name, af, out, found, found_cap, ans, (struct resolv_pair *)0);
}

long resolv_lookup_pair(const char *name, struct resolv_pair *pair) {
    if (!name || !pair) return -22;
    uint8_t out[4];
    pair->canon[0] = 0;
    return resolv_search(name, AF_UNSPEC, out, pair->canon, sizeof pair->canon, (struct resolv_answer *)0, pair);
}

/* The file text and the candidate names are per call (on the stack): two threads resolving at once share nothing. With `pair`
 * each candidate is asked for both A and AAAA at once and the pair's combined result drives the list. */
static long resolv_search(const char *name, int af, uint8_t *out, char *found, size_t found_cap, struct resolv_answer *ans,
                          struct resolv_pair *pair) {
    char resolv_conf_buf[2048];
    char resolv_cand[RESOLV_MAX_CANDIDATES][256];
    struct resolv_answer local;
    if (!ans && found && found_cap) ans = &local; /* the canonical name comes from the answer */
    size_t len = resolv_conf_read(resolv_conf_buf, sizeof resolv_conf_buf);
    struct resolv_server ns[RESOLV_MAXNS];
    size_t nns = resolv_conf_servers_any(resolv_conf_buf, len, ns, RESOLV_MAXNS);
    struct resolv_opts opt;
    const char *unused_word[1];
    size_t unused_len[1];
    resolv_conf_search(resolv_conf_buf, len, unused_word, unused_len, 1, &opt);
    /* A dotted IPv4 literal is an address, not a name: no search domain is tried (glibc answers it without a query, measured). A
     * name with no candidate (malformed, over-long) goes to the kernel as given for its own errno. */
    uint8_t lit[4];
    size_t nc = name[0] && !ipv4_from_text(name, lit) ? resolv_conf_candidates(resolv_conf_buf, len, name, resolv_cand, RESOLV_MAX_CANDIDATES) : 0;
    /* glibc res_search (measured, and its code): the name as given first when it has ndots dots, else last. A search domain that
     * answers NXDOMAIN, NODATA or SERVFAIL lets the list go on; any other failure (REFUSED, another RCODE, no reply, a name too
     * long to send) ends the domain list, though the name as given is still asked if it has not been. With nothing found the
     * result is the as-given query's when it came first, else NODATA if a domain had it, else SERVFAIL if one had that, else the
     * last query's. */
    if (nc == 0) return resolve_one(name, out, ns, nns, &opt, ans, af, pair);
    long saved = 0, last = -2;
    int asis_first = 0, got_nodata = 0, got_servfail = 0, done = 0;
    for (size_t i = 0; i < nc; i++) {
        int is_name = strcmp(resolv_cand[i], name) == 0 || (strlen(name) == strlen(resolv_cand[i]) + 1 && name[strlen(name) - 1] == '.');
        if (!is_name && done) continue;
        long r = resolve_one(is_name ? name : resolv_cand[i], out, ns, nns, &opt, ans, af, pair);
        if (r == 0) {
            if (found && found_cap) {
                /* The canonical name of the answer (the end of its CNAME chain), else the name that was asked; for a pair, the
                 * AAAA answer's when it has one (glibc lists the IPv6 addresses first). */
                const char *canon = resolv_cand[i];
                const struct resolv_answer *ca = pair ? (pair->a6.len ? &pair->a6 : &pair->a4) : ans;
                if (ca && ca->len) canon = (const char *)ca->buf + 3 + ca->buf[2] * ca->buf[0];
                size_t k = strlen(canon);
                if (k >= found_cap) k = found_cap - 1;
                memcpy(found, canon, k);
                found[k] = 0;
            }
            return 0;
        }
        if (r == -14) return r; /* a bad pointer is final */
        last = r;
        if (is_name) {
            if (i == 0 && nc > 1) {
                asis_first = 1;
                saved = r;
            }
            continue;
        }
        if (r == -61) got_nodata = 1;
        else if (r == -11) got_servfail = 1;
        else if (r != -2) done = 1;
    }
    if (asis_first) return saved;
    if (got_nodata) return -61;
    if (got_servfail) return -11;
    return last;
}

/* h_errno for a gethostbyname_ipv4 failure. */
static int netdb_herr_of(long r) {
    if (r == -2 /* ENOENT */ || r == -22 /* EINVAL */ || r == -36 /* ENAMETOOLONG */) return HOST_NOT_FOUND;
    if (r == -61 /* ENODATA */) return NO_DATA;
    if (r == -71 /* EPROTO */) return NO_RECOVERY;
    return TRY_AGAIN;
}

long gethostbyname_ipv4(const char *name, uint8_t out[4]) {
    return gethostbyname_ipv4_name(name, out, (char *)0, 0);
}

long resolv_ptr(const void *addr, int family, char *name, size_t cap) {
    if (!addr || !name || cap == 0) return -22;
    if (family != AF_INET && family != AF_INET6) return -97;
    char conf[2048];
    size_t len = resolv_conf_read(conf, sizeof conf);
    struct resolv_server ns[RESOLV_MAXNS];
    size_t nns = resolv_conf_servers_any(conf, len, ns, RESOLV_MAXNS);
    /* Only the resolv.conf nameservers are asked (no search list applies to an address); without one there is no reverse DNS. */
    if (nns == 0) return -2;
    struct resolv_opts opt;
    const char *unused_word[1];
    size_t unused_len[1];
    resolv_conf_search(conf, len, unused_word, unused_len, 1, &opt);
    char buf[256];
    long last = -110;
    size_t first = resolv_first_server(&opt, nns);
    for (int a = 0; a < opt.attempts; a++) {
        for (size_t i = 0; i < nns; i++) {
            long r = resolv_ask(SYS_dns_ptr, (long)addr, family, &ns[(first + i) % nns], resolv_wait_ms(opt.timeout, i, nns), (long)buf, (long)sizeof buf);
            if (r == -11 || r == -111) last = r;
            if (r == -11 || r == -111 || r == -110 || r == -101) continue;
            if (r == 0) {
                size_t k = strnlen(buf, sizeof buf);
                if (k >= cap) k = cap - 1;
                memcpy(name, buf, k);
                name[k] = 0;
            }
            return r;
        }
    }
    return last;
}

size_t resolv_answer_unpack(const struct resolv_answer *ans, uint8_t addrs[][16], size_t cap, char *names, size_t names_cap) {
    if (names && names_cap) names[0] = 0;
    if (!ans || !ans->len) return 0;
    size_t na = ans->buf[0], nal = ans->buf[1], al = ans->buf[2];
    if (na == 0 || (al != 4 && al != 16) || 3 + al * na >= ans->len) return 0;
    for (size_t i = 0; i < na && i < cap; i++) memcpy(addrs[i], ans->buf + 3 + al * i, al);
    if (names && names_cap) {
        /* "canonical alias alias ...": the canonical name, then the aliases in the order the chain met them. */
        const char *p = (const char *)ans->buf + 3 + al * na;
        const char *end = (const char *)ans->buf + ans->len;
        size_t o = 0;
        for (size_t k = 0; k <= nal && p < end; k++) {
            size_t l = strnlen(p, (size_t)(end - p));
            if (o + l + 2 > names_cap) break;
            if (o) names[o++] = ' ';
            memcpy(names + o, p, l);
            o += l;
            p += l + 1;
        }
        names[o] = 0;
    }
    return na < cap ? na : cap;
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

/* ---- /etc/nsswitch.conf ------------------------------------------------------------------------------------------ */

static int nss_space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\v' || c == '\f'; }

static int nss_word_is(const char *w, size_t n, const char *lit) {
    if (strlen(lit) != n) return 0;
    for (size_t i = 0; i < n; i++)
        if (hosts_lower(w[i]) != hosts_lower(lit[i])) return 0;
    return 1;
}

/* glibc's nss_parse_service_list on text[a, b): the sources into `out`, or 0 when the line is refused. */
static size_t nss_parse_list(const char *t, size_t i, size_t b, struct nss_source *out, size_t cap) {
    size_t n = 0;
    for (;;) {
        while (i < b && nss_space(t[i])) i++;
        if (i >= b) break;
        size_t name = i;
        while (i < b && !nss_space(t[i]) && t[i] != '[') i++;
        if (i == name) break; /* a '[' where a service name should be ends the list */
        struct nss_source s;
        s.service = NSS_SERVICE_OTHER;
        if (i - name == 5 && memcmp(t + name, "files", 5) == 0) s.service = NSS_SERVICE_FILES;
        if (i - name == 3 && memcmp(t + name, "dns", 3) == 0) s.service = NSS_SERVICE_DNS;
        s.stop = 1u << NSS_STATUS_SUCCESS;
        while (i < b && nss_space(t[i])) i++;
        if (i < b && t[i] == '[') {
            do i++; while (i < b && nss_space(t[i]));
            do {
                int not = i < b && t[i] == '!';
                if (not) i++;
                size_t w = i;
                while (i < b && !nss_space(t[i]) && t[i] != '=' && t[i] != ']') i++;
                int status;
                if (nss_word_is(t + w, i - w, "SUCCESS")) status = NSS_STATUS_SUCCESS;
                else if (nss_word_is(t + w, i - w, "NOTFOUND")) status = NSS_STATUS_NOTFOUND;
                else if (nss_word_is(t + w, i - w, "UNAVAIL")) status = NSS_STATUS_UNAVAIL;
                else if (nss_word_is(t + w, i - w, "TRYAGAIN")) status = NSS_STATUS_TRYAGAIN;
                else return 0;
                while (i < b && nss_space(t[i])) i++;
                if (i >= b || t[i] != '=') return 0;
                do i++; while (i < b && nss_space(t[i]));
                w = i;
                while (i < b && !nss_space(t[i]) && t[i] != '=' && t[i] != ']') i++;
                int ret;
                if (nss_word_is(t + w, i - w, "return")) ret = 1;
                else if (nss_word_is(t + w, i - w, "continue") || nss_word_is(t + w, i - w, "merge")) ret = 0;
                else return 0;
                unsigned bit = 1u << status;
                if (not) {
                    unsigned keep = s.stop & bit;
                    s.stop = (unsigned char)((ret ? 0x0Fu : 0u) & ~bit);
                    s.stop |= (unsigned char)keep;
                } else {
                    s.stop = (unsigned char)(ret ? (s.stop | bit) : (s.stop & ~bit));
                }
                while (i < b && nss_space(t[i])) i++;
            } while (i < b && t[i] != ']');
            if (i >= b) return 0; /* no ']' */
            i++;
        }
        if (n < cap) out[n++] = s;
    }
    return n;
}

/* The offset just past "hosts:" when text[pos, end) is a hosts line, else 0. */
static size_t nss_hosts_line(const char *text, size_t pos, size_t end) {
    size_t i = pos;
    while (i < end && nss_space(text[i])) i++;
    size_t w = i;
    while (i < end && !nss_space(text[i]) && text[i] != ':') i++;
    size_t wl = i - w;
    while (i < end && nss_space(text[i])) i++;
    if (i < end && text[i] == ':' && wl == 5 && memcmp(text + w, "hosts", 5) == 0) return i + 1;
    return 0;
}

size_t nsswitch_hosts(const char *text, size_t len, struct nss_source *out, size_t cap) {
    if (!out || cap == 0) return 0;
    size_t found_a = 0, found_b = 0;
    int found = 0;
    for (size_t pos = 0; text && pos < len;) {
        size_t end = pos;
        while (end < len && text[end] != '\n') end++;
        size_t a = nss_hosts_line(text, pos, end);
        if (a) {
            found = 1;
            found_a = a;
            found_b = end;
        }
        pos = end + 1;
    }
    if (!found) {
        size_t n = 0;
        out[n].service = NSS_SERVICE_FILES;
        out[n++].stop = 1u << NSS_STATUS_SUCCESS;
        if (n < cap) {
            out[n].service = NSS_SERVICE_DNS;
            out[n++].stop = 1u << NSS_STATUS_SUCCESS;
        }
        return n;
    }
    return nss_parse_list(text, found_a, found_b, out, cap);
}

#ifdef MOQI_HOST_TEST_SYSCALL
/* The host test supplies the file's text (NULL: no file), handed out in pieces like read(2). */
extern const char *moqi_test_nsswitch_conf;
static size_t nss_test_off;
static long nss_open(void) {
    nss_test_off = 0;
    return moqi_test_nsswitch_conf ? 0 : -2;
}
static long nss_read(long fd, char *buf, size_t cap) {
    (void)fd;
    size_t n = strlen(moqi_test_nsswitch_conf + nss_test_off);
    if (n > cap) n = cap;
    memcpy(buf, moqi_test_nsswitch_conf + nss_test_off, n);
    nss_test_off += n;
    return (long)n;
}
static void nss_close(long fd) { (void)fd; }
#else
static long nss_open(void) { return syscall3(SYS_open, (long)"/etc/nsswitch.conf", 0 /* O_RDONLY */, 0); }
static long nss_read(long fd, char *buf, size_t cap) { return syscall3(SYS_read, fd, (long)buf, (long)cap); }
static void nss_close(long fd) { syscall1(SYS_close, fd); }
#endif

/* A hosts line keeps its first NSS_LINE_MAX bytes; other lines are skipped whatever their length. */
#define NSS_LINE_MAX 1024

/* The hosts sources of /etc/nsswitch.conf, read afresh on every lookup (glibc rereads a changed file too). The whole file is
 * read in pieces and the last complete hosts line kept, so its length does not matter (glibc 2.44, measured with 100000
 * bytes). */
static size_t hosts_sources(struct nss_source *out) {
    char chunk[512], line[NSS_LINE_MAX], last[NSS_LINE_MAX];
    size_t ll = 0, last_len = 0;
    int have = 0;
    long fd = nss_open();
    if (fd >= 0) {
        for (;;) {
            long r = nss_read(fd, chunk, sizeof chunk);
            size_t n = r > 0 ? (size_t)r : 0;
            for (size_t i = 0; i < n; i++) {
                if (chunk[i] != '\n') {
                    if (ll < sizeof line) line[ll] = chunk[i];
                    ll++;
                    continue;
                }
                size_t keep = ll < sizeof line ? ll : sizeof line;
                if (nss_hosts_line(line, 0, keep)) {
                    memcpy(last, line, keep);
                    last_len = keep;
                    have = 1;
                }
                ll = 0;
            }
            if (r <= 0) break;
        }
        /* A last line without its newline is not used: glibc's getline loop stops at end of file before parsing it. */
        nss_close(fd);
    }
    return nsswitch_hosts(have ? last : (const char *)0, last_len, out, NSS_HOSTS_MAX);
}

/* Whether `status` ends the lookup after source `s`. */
static int nss_stops(const struct nss_source *s, int status) { return (s->stop >> status) & 1; }

#define ETC_HOSTS_MAX 8192
#ifdef MOQI_HOST_TEST_SYSCALL
/* The host test supplies the file's text (NULL: no file). */
extern const char *moqi_test_etc_hosts;
static size_t etc_hosts_read_into(char *buf, size_t cap) {
    if (!moqi_test_etc_hosts) return 0;
    size_t n = strlen(moqi_test_etc_hosts);
    if (n > cap) n = cap;
    memcpy(buf, moqi_test_etc_hosts, n);
    return n;
}
static int etc_hosts_exists(void) { return moqi_test_etc_hosts != (const char *)0; }
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
/* Whether /etc/hosts exists: glibc's files source is UNAVAIL without it, NOTFOUND when it does not name the host (measured). */
static int etc_hosts_exists(void) {
    long fd = syscall3(SYS_open, (long)"/etc/hosts", 0 /* O_RDONLY */, 0);
    if (fd < 0) return 0;
    syscall1(SYS_close, fd);
    return 1;
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


/* ---- interface names ---------------------------------------------------------------------------------------- */

#include "../include/errno.h"

#define SIOCGIFNAME_REQ  0x8910
#define SIOCGIFINDEX_REQ 0x8933
#define IFREQ_BYTES 40

/* One netdevice ioctl on a scratch UDP socket: 0 and the answered ifreq, or the -errno of socket() or ioctl(). */
static long ifreq_ask(long cmd, uint8_t req[IFREQ_BYTES]) {
    long s = NETDB_SYSCALL3(SYS_socket, AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return s;
    long rc = NETDB_SYSCALL3(SYS_ioctl, s, cmd, (long)req);
    NETDB_SYSCALL1(SYS_close, s);
    return rc;
}

unsigned int if_nametoindex(const char *name) {
    uint8_t req[IFREQ_BYTES];
    memset(req, 0, sizeof req);
    size_t n = 0;
    while (name && name[n] && n < IF_NAMESIZE) n++;
    if (!name || n == 0 || n >= IF_NAMESIZE) {
        errno = ENODEV;
        return 0;
    }
    memcpy(req, name, n);
    long rc = ifreq_ask(SIOCGIFINDEX_REQ, req);
    if (rc < 0) {
        errno = (int)-rc;
        return 0;
    }
    return (unsigned)req[16] | (unsigned)req[17] << 8 | (unsigned)req[18] << 16 | (unsigned)req[19] << 24;
}

char *if_indextoname(unsigned int index, char *buf) {
    if (!buf) {
        errno = EINVAL;
        return (char *)0;
    }
    uint8_t req[IFREQ_BYTES];
    memset(req, 0, sizeof req);
    for (int k = 0; k < 4; k++) req[16 + k] = (uint8_t)(index >> (8 * k));
    long rc = index ? ifreq_ask(SIOCGIFNAME_REQ, req) : -ENODEV;
    if (rc < 0) {
        /* glibc reports an index with no interface as ENXIO, though the kernel answers ENODEV (measured). */
        errno = rc == -ENODEV ? ENXIO : (int)-rc;
        return (char *)0;
    }
    req[IF_NAMESIZE - 1] = 0;
    memcpy(buf, req, IF_NAMESIZE);
    return buf;
}

#include "../include/stdlib.h"

#define IFNAMEINDEX_MAX 16

void if_freenameindex(struct if_nameindex *ptr) {
    if (!ptr) return;
    for (struct if_nameindex *p = ptr; p->if_index != 0 || p->if_name; p++) free(p->if_name);
    free(ptr);
}

struct if_nameindex *if_nameindex(void) {
    uint8_t conf[IFNAMEINDEX_MAX * IFREQ_BYTES];
    uint8_t hdr[16];
    memset(hdr, 0, sizeof hdr);
    int len = (int)sizeof conf;
    uint8_t *p = conf;
    memcpy(hdr, &len, 4);
    memcpy(hdr + 8, &p, sizeof p);
    long s = NETDB_SYSCALL3(SYS_socket, AF_INET, SOCK_DGRAM, 0);
    if (s < 0) {
        errno = (int)-s;
        return (struct if_nameindex *)0;
    }
    long rc = NETDB_SYSCALL3(SYS_ioctl, s, 0x8912 /* SIOCGIFCONF */, (long)hdr);
    int got = 0;
    if (rc == 0) memcpy(&got, hdr, 4);
    size_t count = rc == 0 && got > 0 ? (size_t)got / IFREQ_BYTES : 0;
    struct if_nameindex *out = (struct if_nameindex *)malloc((count + 1) * sizeof(struct if_nameindex));
    if (!out) {
        NETDB_SYSCALL1(SYS_close, s);
        errno = ENOMEM;
        return (struct if_nameindex *)0;
    }
    size_t n = 0;
    for (size_t k = 0; k < count; k++) {
        uint8_t req[IFREQ_BYTES];
        memset(req, 0, sizeof req);
        memcpy(req, conf + k * IFREQ_BYTES, IF_NAMESIZE - 1);
        if (NETDB_SYSCALL3(SYS_ioctl, s, SIOCGIFINDEX_REQ, (long)req) != 0) continue; /* gone meanwhile */
        size_t nl = strlen((const char *)req);
        char *name = (char *)malloc(nl + 1);
        if (!name) {
            out[n].if_index = 0;
            out[n].if_name = (char *)0;
            if_freenameindex(out);
            NETDB_SYSCALL1(SYS_close, s);
            errno = ENOMEM;
            return (struct if_nameindex *)0;
        }
        memcpy(name, req, nl + 1);
        out[n].if_index = (unsigned)req[16] | (unsigned)req[17] << 8 | (unsigned)req[18] << 16 | (unsigned)req[19] << 24;
        out[n].if_name = name;
        n++;
    }
    NETDB_SYSCALL1(SYS_close, s);
    if (rc < 0) {
        free(out);
        errno = (int)-rc;
        return (struct if_nameindex *)0;
    }
    out[n].if_index = 0;
    out[n].if_name = (char *)0;
    return out;
}

/* Scopes that glibc writes and reads as an interface name: link-local unicast fe80::/10 and link-scope multicast ff02 (measured;
 * getaddrinfo also takes a name on interface-local multicast ff01, getnameinfo prints a number there). */
static int scope_is_link_local(const uint8_t a[16]) { return a[0] == 0xFE && (a[1] & 0xC0) == 0x80; }
static int scope_is_mcast(const uint8_t a[16], int scope) { return a[0] == 0xFF && (a[1] & 0x0F) == scope; }
static int scope_name_accepted(const uint8_t a[16]) { return scope_is_link_local(a) || scope_is_mcast(a, 1) || scope_is_mcast(a, 2); }
static int scope_name_printed(const uint8_t a[16]) { return scope_is_link_local(a) || scope_is_mcast(a, 2); }

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

/* A DNS answer brings up to 64 addresses and a canonical name with 16 aliases (dns_answer.zig); glibc keeps them all (measured:
 * 60 addresses, a 12-step CNAME chain). The names field holds the canonical name and every alias, blank-separated. */
#define HOSTENT_NAME_MAX (17 * 254)
#define HOSTENT_ADDRS_MAX 64
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
/* host_answer.herr when the files source decided without an /etc/hosts: h_errno and *h_errnop are left as they were and the
 * error is ENOENT (glibc 2.44, measured in a fresh process). */
#define HERR_KEEP (-100)

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

/* The "files" source for a name: every /etc/hosts line of this family in file order, the names from the first one. NOTFOUND
 * (h_errno HOST_NOT_FOUND) when the file does not name it, UNAVAIL (HERR_KEEP, ENOENT) when there is no file. */
static int name_from_files(const char *name, int af, char *hosts, size_t hosts_cap, struct host_answer *ans) {
    size_t alen = af == AF_INET6 ? 16 : 4;
    size_t n = etc_hosts_read_into(hosts, hosts_cap);
    struct hosts_addr found[HOSTENT_ADDRS_MAX];
    const char *names = (const char *)0;
    size_t names_len = 0;
    size_t k = n ? hosts_collect(hosts, n, name, af, found, HOSTENT_ADDRS_MAX, &names, &names_len) : 0;
    ans->rc = 0;
    if (!k) {
        if (n || etc_hosts_exists()) {
            ans->herr = HOST_NOT_FOUND;
            return NSS_STATUS_NOTFOUND;
        }
        ans->herr = HERR_KEEP;
        ans->rc = ENOENT;
        return NSS_STATUS_UNAVAIL;
    }
    for (size_t i = 0; i < k; i++) memcpy(ans->addrs[i], found[i].addr, alen);
    ans->naddrs = k;
    if (names_len >= HOSTENT_NAME_MAX) names_len = HOSTENT_NAME_MAX - 1;
    memcpy(ans->name_store, names, names_len);
    ans->names = ans->name_store;
    ans->names_len = names_len;
    ans->herr = 0;
    return NSS_STATUS_SUCCESS;
}

/* The "dns" source for a name. AF_INET asks A records, AF_INET6 AAAA records (gethostbyname2, glibc measured). The name that
 * answered (a search domain may have been appended, and the end of a CNAME chain) is the canonical name, the names before it in
 * the chain the aliases, and every address of the reply is listed (glibc, measured). A failure that h_errno calls TRY_AGAIN (no
 * reply, SERVFAIL, REFUSED, NOTIMP) is UNAVAIL, any other NOTFOUND (glibc 2.44 under [UNAVAIL=return] / [NOTFOUND=return],
 * measured). */
static int name_from_dns(const char *name, int af, struct host_answer *ans) {
    ans->name_store[0] = 0;
    ans->rc = 0;
    struct resolv_answer ra;
    long r = resolv_lookup_af(name, af, ans->addrs[0], ans->name_store, HOSTENT_NAME_MAX, &ra);
    if (r < 0) {
        /* glibc (measured): a name that does not exist, is malformed or too long is HOST_NOT_FOUND; one that exists without an
         * address NO_DATA; an error RCODE other than SERVFAIL/NOTIMP/REFUSED NO_RECOVERY; no reply, a server error or any other
         * failure TRY_AGAIN. */
        ans->herr = netdb_herr_of(r);
        if (ans->herr == TRY_AGAIN) {
            ans->rc = EAGAIN;
            return NSS_STATUS_UNAVAIL;
        }
        return NSS_STATUS_NOTFOUND;
    }
    char chain[HOSTENT_NAME_MAX];
    size_t k = resolv_answer_unpack(&ra, ans->addrs, HOSTENT_ADDRS_MAX, chain, sizeof chain);
    if (k) memcpy(ans->name_store, chain, strlen(chain) + 1);
    ans->naddrs = k ? k : 1;
    if (ans->name_store[0]) {
        ans->names = ans->name_store;
        ans->names_len = strlen(ans->name_store);
    }
    ans->herr = 0;
    return NSS_STATUS_SUCCESS;
}

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
        /* The sources of the nsswitch.conf "hosts" line in order; the last one asked decides (glibc 2.44, measured). */
        struct nss_source src[NSS_HOSTS_MAX];
        size_t nsrc = hosts_sources(src);
        int status = NSS_STATUS_UNAVAIL;
        ans->herr = NETDB_INTERNAL; /* no source at all, or only ones this library does not have */
        for (size_t s = 0; s < nsrc; s++) {
            ans->names = (const char *)0;
            ans->naddrs = 0;
            if (src[s].service == NSS_SERVICE_FILES) status = name_from_files(name, af, hosts, hosts_cap, ans);
            else if (src[s].service == NSS_SERVICE_DNS) status = name_from_dns(name, af, ans);
            else status = NSS_STATUS_UNAVAIL;
            if (nss_stops(&src[s], status)) break;
        }
        if (status != NSS_STATUS_SUCCESS) {
            ans->names = (const char *)0;
            ans->naddrs = 0;
            return;
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
    /* The nsswitch.conf "hosts" sources in order (glibc 2.44, measured): for an address every DNS failure, a timeout included, is
     * NOTFOUND, and a source this library does not have leaves h_errno as it was. */
    struct nss_source src[NSS_HOSTS_MAX];
    size_t nsrc = hosts_sources(src);
    const char *names = (const char *)0;
    size_t names_len = 0;
    int status = NSS_STATUS_UNAVAIL;
    ans->herr = NETDB_INTERNAL;
    for (size_t s = 0; s < nsrc; s++) {
        if (src[s].service == NSS_SERVICE_FILES) {
            size_t n = etc_hosts_read_into(hosts, hosts_cap);
            names_len = n ? hosts_reverse_names(hosts, n, query_family, query, &names) : 0;
            status = names_len ? NSS_STATUS_SUCCESS : n || etc_hosts_exists() ? NSS_STATUS_NOTFOUND : NSS_STATUS_UNAVAIL;
            ans->herr = names_len ? 0 : status == NSS_STATUS_UNAVAIL ? HERR_KEEP : HOST_NOT_FOUND;
            ans->rc = status == NSS_STATUS_UNAVAIL ? ENOENT : 0;
        } else if (src[s].service == NSS_SERVICE_DNS && requested_family != AF_UNSPEC) {
            /* A PTR query to the resolv.conf nameservers. A mapped ::ffff:a.b.c.d asks the in-addr.arpa name and is answered
             * as the IPv4 host it names: AF_INET, 4 bytes (glibc 2.44, measured; its /etc/hosts answer keeps the 16 bytes). */
            long r = resolv_ptr(query, query_family, ans->name_store, HOSTENT_NAME_MAX);
            if (r == 0) {
                ans->names = ans->name_store;
                ans->names_len = strlen(ans->name_store);
                ans->af = query_family;
                memcpy(ans->addrs[0], query, query_family == AF_INET ? 4 : 16);
                ans->naddrs = 1;
                ans->herr = 0;
                ans->rc = 0;
                return;
            }
            status = NSS_STATUS_NOTFOUND;
            ans->herr = netdb_herr_of(r); /* -2: no reverse DNS configured, or NXDOMAIN */
            ans->rc = ans->herr == TRY_AGAIN ? EAGAIN : 0;
        } else {
            status = src[s].service == NSS_SERVICE_DNS ? NSS_STATUS_NOTFOUND : NSS_STATUS_UNAVAIL;
        }
        if (nss_stops(&src[s], status)) break;
    }
    if (status != NSS_STATUS_SUCCESS) {
        if (requested_family == AF_UNSPEC) {
            ans->herr = NETDB_INTERNAL;
            ans->rc = EAFNOSUPPORT;
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
 * is large enough for any answer (HOSTENT_ADDRS_MAX addresses of 16 bytes and a full names field). */
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
        if (ans->herr != HERR_KEEP) h_errno = ans->herr;
        if (ans->rc == EAFNOSUPPORT && ans->herr == NETDB_INTERNAL) errno = EAFNOSUPPORT;
        if (ans->rc == ENOENT) errno = ENOENT;
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
    if (h_errnop && herr != HERR_KEEP) *h_errnop = herr;
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

/* "addr%scope": a numeric scope (inet_pton plus glibc's strtoul check) on any address, or an interface name (if_nametoindex) on
 * the link-local and multicast scopes glibc accepts it for. 1 = parsed, 0 = not this form. */
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
    uint8_t addr[16];
    if (!ipv6_from_text(text, addr)) return 0;
    uint64_t v = 0;
    int numeric = 1;
    for (const char *p = d; *p; p++) {
        if (*p < '0' || *p > '9') { numeric = 0; break; }
        v = v * 10 + (uint64_t)(*p - '0');
        if (v > 0xFFFFFFFFu) return 0;
    }
    if (!numeric) {
        if (!scope_name_accepted(addr)) return 0;
        int saved = errno;
        v = if_nametoindex(d);
        errno = saved;
        if (v == 0) return 0;
    }
    memcpy(out, addr, 16);
    *scope = (uint32_t)v;
    return 1;
}

#define GAI_MAX_ADDRS 64

/* ---- AI_ADDRCONFIG ------------------------------------------------------------------------------------------- */

int ifconf_has_nonloopback4(const uint8_t *conf, size_t len) {
    for (size_t off = 0; conf && off + IFREQ_BYTES <= len; off += IFREQ_BYTES) {
        const uint8_t *r = conf + off;
        /* 0.0.0.0 is an interface with no address yet (MoQiOS lists eth0 before DHCP; Linux omits it). */
        int unset = r[20] == 0 && r[21] == 0 && r[22] == 0 && r[23] == 0;
        if (r[16] == AF_INET && r[17] == 0 && r[20] != 127 && !unset) return 1;
    }
    return 0;
}

int if_inet6_has_nonloopback(const char *text, size_t len) {
    size_t pos = 0;
    while (text && pos < len) {
        size_t end = pos;
        while (end < len && text[end] != '\n') end++;
        /* Each line starts with the address as 32 hex digits. */
        if (end - pos >= 32) {
            int ok = 1, loopback = 1;
            for (size_t k = 0; k < 32; k++) {
                int d = hex_digit(text[pos + k]);
                if (d < 0) { ok = 0; break; }
                if (d != (k == 31 ? 1 : 0)) loopback = 0;
            }
            if (ok && !loopback) return 1;
        }
        pos = end + 1;
    }
    return 0;
}

int addrconfig_rule(int family, int have4, int have6) {
    if (family == AF_INET) return have4 ? ADDRCONFIG_KEEP_ALL : ADDRCONFIG_NONAME;
    if (family == AF_INET6) return have6 ? ADDRCONFIG_KEEP_ALL : ADDRCONFIG_NONAME;
    if (have4 == have6) return ADDRCONFIG_KEEP_ALL;
    return have4 ? ADDRCONFIG_ONLY_INET : ADDRCONFIG_ONLY_INET6;
}

#ifdef MOQI_HOST_TEST_SYSCALL
static size_t if_inet6_read(char *buf, size_t cap) { (void)buf; (void)cap; return 0; }
#else
static size_t if_inet6_read(char *buf, size_t cap) {
    long fd = syscall3(SYS_open, (long)"/proc/net/if_inet6", 0 /* O_RDONLY */, 0);
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

/* Which families have a non-loopback address. errno is left as it was. */
static void addrconfig_probe(int *have4, int *have6) {
    int saved = errno;
    uint8_t conf[8 * IFREQ_BYTES];
    uint8_t hdr[16];
    memset(hdr, 0, sizeof hdr);
    int len = (int)sizeof conf;
    uint8_t *p = conf;
    memcpy(hdr, &len, 4);
    memcpy(hdr + 8, &p, sizeof p);
    *have4 = 0;
    long s = NETDB_SYSCALL3(SYS_socket, AF_INET, SOCK_DGRAM, 0);
    if (s >= 0) {
        if (NETDB_SYSCALL3(SYS_ioctl, s, 0x8912 /* SIOCGIFCONF */, (long)hdr) == 0) {
            int got;
            memcpy(&got, hdr, 4);
            if (got > 0) *have4 = ifconf_has_nonloopback4(conf, (size_t)got);
        }
        NETDB_SYSCALL1(SYS_close, s);
    }
    char text[1024];
    size_t n = if_inet6_read(text, sizeof text);
    *have6 = if_inet6_has_nonloopback(text, n);
    errno = saved;
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    int flags = 0, family = AF_UNSPEC, socktype = 0, protocol = 0;
    if (hints) {
        flags = hints->ai_flags;
        family = hints->ai_family;
        socktype = hints->ai_socktype;
        protocol = hints->ai_protocol;
    }
    /* The caller's flags are validated. */
    const int known_flags = AI_PASSIVE | AI_CANONNAME | AI_NUMERICHOST | AI_NUMERICSERV | AI_V4MAPPED | AI_ALL | AI_ADDRCONFIG;
    if (flags & ~known_flags) return EAI_BADFLAGS;
    /* With no hints at all glibc echoes 0x40 in the entries (its internal default); mirror that. */
    int echoed_flags = hints ? flags : 0x40;
    if ((flags & AI_CANONNAME) && !node) return EAI_BADFLAGS;
    if (!node && !service) return EAI_NONAME;
    if (family != AF_UNSPEC && family != AF_INET && family != AF_INET6) return EAI_FAMILY;
    if (flags & AI_ADDRCONFIG) {
        /* With exactly one family configured, an AF_UNSPEC lookup becomes a lookup for that family, so the other family's
         * addresses go away and its literals are EAI_ADDRFAMILY (glibc, measured); the entries still echo the caller's hints. */
        int have4, have6;
        addrconfig_probe(&have4, &have6);
        switch (addrconfig_rule(family, have4, have6)) {
        case ADDRCONFIG_NONAME: return EAI_NONAME;
        case ADDRCONFIG_ONLY_INET: family = AF_INET; break;
        case ADDRCONFIG_ONLY_INET6: family = AF_INET6; break;
        default: break;
        }
    }

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
        if (strchr(node, '%')) return EAI_NONAME; /* a scope that is neither a number nor an interface allowed for the address */
        /* The sources of the nsswitch.conf "hosts" line in order; the last one asked decides, and a source this library does not
         * have is EAI_SYSTEM (glibc 2.44, measured). */
        struct nss_source src[NSS_HOSTS_MAX];
        size_t nsrc = hosts_sources(src);
        const char *names = (const char *)0;
        size_t names_len = 0;
        int status = NSS_STATUS_UNAVAIL, code = EAI_SYSTEM;
        /* The h_errno glibc's getaddrinfo would see: the caller's, then whatever a DNS source left. */
        int herr_now = h_errno;
        for (size_t s = 0; s < nsrc; s++) {
            naddrs = 0;
            names = (const char *)0;
            names_len = 0;
            if (src[s].service == NSS_SERVICE_FILES) {
                /* /etc/hosts. Under AF_INET6, IPv4 lines are used only with AI_V4MAPPED: when there is no IPv6 line, or always
                 * with AI_ALL, and then as ::ffff:a.b.c.d after the IPv6 ones (glibc, measured). */
                size_t n = etc_hosts_read();
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
                status = naddrs ? NSS_STATUS_SUCCESS : n || etc_hosts_exists() ? NSS_STATUS_NOTFOUND : NSS_STATUS_UNAVAIL;
                code = EAI_NONAME;
                if (status == NSS_STATUS_UNAVAIL) {
                    /* No /etc/hosts: the module leaves h_errno alone, so glibc 2.44 maps the h_errno already there
                     * (getaddrinfo.c, measured). AF_UNSPEC goes through gethostbyname4_r, which answers NO_DATA;
                     * AF_INET without AI_CANONNAME through try_simple_gethostbyname, where only NETDB_INTERNAL and
                     * TRY_AGAIN are not EAI_NODATA; the rest through gethosts, where only NO_DATA is. */
                    errno = ENOENT;
                    if (family == AF_UNSPEC) code = EAI_NODATA;
                    else if (herr_now == NETDB_INTERNAL) code = EAI_SYSTEM;
                    else if (herr_now == TRY_AGAIN) code = EAI_AGAIN;
                    else if (family == AF_INET && !(flags & AI_CANONNAME)) code = EAI_NODATA;
                    else code = herr_now == NO_DATA ? EAI_NODATA : EAI_NONAME;
                }
            } else if (src[s].service == NSS_SERVICE_DNS) {
                /* DNS (glibc 2.44, measured): AF_INET asks A records, AF_INET6 AAAA records, AF_UNSPEC both, listing the IPv6 addresses
                 * first. AF_INET6 with AI_V4MAPPED falls back to the A records, mapped, when there is no AAAA; with AI_ALL as well it
                 * lists both. One family failing while the other answers is fine; when neither answers the lookup is EAI_NONAME if either
                 * said NXDOMAIN (or the name is malformed), else EAI_NODATA if either said NODATA, else EAI_AGAIN. canon_buf ends up
                 * holding the end of the CNAME chain of the first answer. */
                int want6 = family == AF_INET6 || family == AF_UNSPEC;
                int want4 = family == AF_INET || family == AF_UNSPEC || (family == AF_INET6 && (flags & AI_V4MAPPED));
                int all = family == AF_INET6 && (flags & AI_V4MAPPED) && (flags & AI_ALL);
                canon_buf[0] = 0;
                long r6 = -2, r4 = -2;
                uint8_t a16[16];
                struct resolv_answer ra;
                if (family == AF_UNSPEC) {
                    /* Both at once (hello530): one dns_query2 per candidate and server; IPv6 addresses first. */
                    struct resolv_pair *pr = (struct resolv_pair *)malloc(sizeof *pr); /* 11 KiB: off the 64 KiB thread stacks */
                    if (!pr) return EAI_MEMORY;
                    long rp = resolv_lookup_pair(node, pr);
                    r4 = pr->r4;
                    r6 = pr->r6;
                    if (rp == 0) {
                        uint8_t got[GAI_MAX_ADDRS][16];
                        size_t k = r6 == 0 ? resolv_answer_unpack(&pr->a6, got, GAI_MAX_ADDRS, (char *)0, 0) : 0;
                        for (size_t i = 0; i < k && naddrs < GAI_MAX_ADDRS; i++) {
                            memset(&addrs[naddrs], 0, sizeof addrs[naddrs]);
                            addrs[naddrs].family = AF_INET6;
                            memcpy(addrs[naddrs].addr, got[i], 16);
                            naddrs++;
                        }
                        k = r4 == 0 ? resolv_answer_unpack(&pr->a4, got, GAI_MAX_ADDRS, (char *)0, 0) : 0;
                        for (size_t i = 0; i < k && naddrs < GAI_MAX_ADDRS; i++) {
                            set_v4(&addrs[naddrs], got[i][0], got[i][1], got[i][2], got[i][3]);
                            naddrs++;
                        }
                        memcpy(canon_buf, pr->canon, strlen(pr->canon) + 1);
                    } else {
                        r4 = r6 = rp;
                    }
                    free(pr);
                    want6 = want4 = 0;
                }
                if (want6) {
                    r6 = resolv_lookup_af(node, AF_INET6, a16, canon_buf, sizeof canon_buf, &ra);
                    if (r6 == 0) {
                        uint8_t got[GAI_MAX_ADDRS][16];
                        size_t k = resolv_answer_unpack(&ra, got, GAI_MAX_ADDRS, (char *)0, 0);
                        if (k == 0) {
                            memcpy(got[0], a16, 16);
                            k = 1;
                        }
                        for (size_t i = 0; i < k && naddrs < GAI_MAX_ADDRS; i++) {
                            memset(&addrs[naddrs], 0, sizeof addrs[naddrs]);
                            addrs[naddrs].family = AF_INET6;
                            memcpy(addrs[naddrs].addr, got[i], 16);
                            naddrs++;
                        }
                    }
                }
                /* AF_INET6 + AI_V4MAPPED asks A only when AAAA gave nothing, unless AI_ALL. */
                if (want4 && (family != AF_INET6 || naddrs == 0 || all)) {
                    char canon4[256];
                    canon4[0] = 0;
                    r4 = resolv_lookup_af(node, AF_INET, v4, canon4, sizeof canon4, &ra);
                    if (r4 == 0) {
                        uint8_t got[GAI_MAX_ADDRS][16];
                        size_t k = resolv_answer_unpack(&ra, got, GAI_MAX_ADDRS, (char *)0, 0);
                        if (k == 0) {
                            memcpy(got[0], v4, 4);
                            k = 1;
                        }
                        for (size_t i = 0; i < k && naddrs < GAI_MAX_ADDRS; i++) {
                            set_v4(&addrs[naddrs], got[i][0], got[i][1], got[i][2], got[i][3]);
                            if (family == AF_INET6) map_v4(&addrs[naddrs]);
                            naddrs++;
                        }
                        if (!canon_buf[0]) memcpy(canon_buf, canon4, strlen(canon4) + 1);
                    }
                }
                if (naddrs == 0) {
                    long rs[2] = {want6 || family == AF_UNSPEC ? r6 : 0, want4 || family == AF_UNSPEC ? r4 : 0};
                    int nx = 0, nd = 0;
                    for (int i = 0; i < 2; i++) {
                        if (rs[i] == -2 || rs[i] == -22 || rs[i] == -36 || rs[i] == -71) nx = 1;
                        if (rs[i] == -61) nd = 1;
                    }
                    /* One family asked: its own mapping (NO_RECOVERY like HOST_NOT_FOUND is EAI_NONAME). EAI_AGAIN is UNAVAIL to
                     * nsswitch.conf, the others NOTFOUND (glibc 2.44, measured). */
                    code = nx ? EAI_NONAME : nd ? EAI_NODATA : EAI_AGAIN;
                    status = code == EAI_AGAIN ? NSS_STATUS_UNAVAIL : NSS_STATUS_NOTFOUND;
                    herr_now = code == EAI_AGAIN ? TRY_AGAIN : code == EAI_NODATA ? NO_DATA : HOST_NOT_FOUND;
                } else {
                    status = NSS_STATUS_SUCCESS;
                }
                names = (const char *)0;
                if (canon_buf[0]) {
                    names = canon_buf;
                    names_len = strlen(canon_buf);
                }
            } else {
                status = NSS_STATUS_UNAVAIL;
                code = EAI_SYSTEM;
            }
            if (nss_stops(&src[s], status)) break;
        }
        if (status != NSS_STATUS_SUCCESS) return code;
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
            /* gethostbyaddr's lookup through the nsswitch.conf sources (glibc's getnameinfo calls gethostbyaddr_r): its first
             * name; NETDB_INTERNAL is EAI_SYSTEM and TRY_AGAIN EAI_AGAIN, any other failure the numeric form (glibc 2.44,
             * measured). A mapped ::ffff:a.b.c.d is named from the IPv4 lines and asks the IPv4 PTR name. */
            struct host_answer ans;
            lookup_addr(addr, v6 ? 16 : 4, v6 ? AF_INET6 : AF_INET, etc_hosts_buf, sizeof etc_hosts_buf, &ans);
            if (ans.names) {
                size_t k = 0;
                while (k < ans.names_len && ans.names[k] != ' ' && ans.names[k] != '\t') k++;
                if (k > 0 && k < sizeof(found)) {
                    memcpy(found, ans.names, k);
                    found[k] = 0;
                    text = found;
                }
            } else if (ans.herr == NETDB_INTERNAL) {
                return EAI_SYSTEM;
            } else if (ans.herr == TRY_AGAIN) {
                return EAI_AGAIN;
            }
        }
        if (!text) {
            if (flags & NI_NAMEREQD) return EAI_NONAME;
            long len = v6 ? ipv6_to_text(addr, numeric, sizeof(numeric)) : ipv4_to_text(addr, numeric, sizeof(numeric));
            uint32_t scope = v6 ? ((uint32_t)sa[24] | (uint32_t)sa[25] << 8 | (uint32_t)sa[26] << 16 | (uint32_t)sa[27] << 24) : 0;
            if (scope) {
                /* A non-zero sin6_scope_id is appended as "%name" for a link-local or link-scope multicast address whose index
                 * names an interface, otherwise as "%N" (glibc, measured). */
                char ifname[IF_NAMESIZE];
                int saved = errno;
                const char *named = scope_name_printed(addr) ? if_indextoname(scope, ifname) : (const char *)0;
                errno = saved;
                numeric[len++] = '%';
                if (named) {
                    for (size_t k = 0; named[k]; k++) numeric[len++] = named[k];
                } else {
                    char d[11];
                    int nd = 0;
                    do { d[nd++] = (char)('0' + scope % 10); scope /= 10; } while (scope);
                    while (nd) numeric[len++] = d[--nd];
                }
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
