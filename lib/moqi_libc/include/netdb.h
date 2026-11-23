/* netdb.h — hostname resolution for moqi_libc.
 *
 * gethostbyname_ipv4() is a thin wrapper over the kernel's dns_resolve system call (495): static host table
 * (localhost, gateway), dotted decimal, the resolver cache, then a DNS query. IPv4 A records only. Failures are
 * the kernel's -errno, returned unchanged: -ENOENT (empty name or did not resolve), -ENAMETOOLONG, -EINVAL
 * (malformed hostname), -EFAULT. The output is written only on success.
 */
#ifndef MOQI_NETDB_H
#define MOQI_NETDB_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "moqi_syscalls.h"

/* Resolve `name` to a 4-byte IPv4 address in network order. 0 on success, -errno on failure. A NULL `name` or
 * `out` is -EINVAL and never reaches the kernel. */
long gethostbyname_ipv4(const char *name, uint8_t out[4]);

/* Format `addr` as "a.b.c.d" into `buf` (NUL-terminated). Returns the text length (without the NUL), or -ERANGE
 * (-34) when `buf` cannot hold the text plus its NUL, in which case `buf` is not written. */
long ipv4_to_text(const uint8_t addr[4], char *buf, size_t buf_len);

/* Format a 16-byte IPv6 address like inet_ntop(AF_INET6): lower-case hex groups without leading zeros, the first longest run of
 * two or more zero groups as "::", and a trailing dotted quad for ::ffff:a.b.c.d and for ::a.b.c.d whose seventh group is not zero. Returns the
 * text length, or -ERANGE (-34) when `buf` cannot hold the text plus its NUL, in which case `buf` is not written. */
long ipv6_to_text(const uint8_t addr[16], char *buf, size_t buf_len);

/* Parse "a.b.c.d" into 4 bytes (network order), with inet_pton(AF_INET) semantics: exactly four decimal fields of
 * 0..255, no leading zeros, no whitespace, no trailing text. Returns 1 on success, 0 when `text` is not an IPv4
 * address (NULL arguments included). `out` is written only on success. */
int ipv4_from_text(const char *text, uint8_t out[4]);

/* Parse an IPv6 address into 16 bytes (network order) with inet_pton(AF_INET6) semantics: eight groups of up to four hex digits,
 * one "::" for a run of zero groups, an optional trailing dotted IPv4 quad in the last 32 bits; no scope, no whitespace.
 * Returns 1 and writes `out`, or 0 and leaves `out` untouched (also for NULL arguments). */
int ipv6_from_text(const char *text, uint8_t out[16]);

/* Look `name` up in the text of an /etc/hosts file (`len` bytes): the first line with a dotted IPv4 address that lists the name
 * (ASCII case-insensitive, whole field) wins; '#' starts a comment. Returns 1 and writes the address, or 0. gethostbyname,
 * getaddrinfo and resolve_ipv4_sockaddr consult /etc/hosts this way before the kernel resolver, as glibc's "files" source does. */
int hosts_find(const char *text, size_t len, const char *name, uint8_t out[4]);

/* hosts_find that also returns the matching line's names: *names points at the first name (the canonical one, then the aliases,
 * separated by spaces or tabs) and the return value is the length of that run up to the comment or line end; 0 means no match. */
size_t hosts_find_names(const char *text, size_t len, const char *name, uint8_t out[4], const char **names);

/* Every address /etc/hosts gives `name`, for getaddrinfo: IPv6 lines first, then IPv4 lines, each in file order (glibc's order
 * for these, measured), filtered by `family` (AF_INET, AF_INET6 or AF_UNSPEC); at most `cap` entries. *names (may be NULL) gets the
 * first matching line's names as in hosts_find_names and *names_len their length. Returns the number of addresses written. */
struct hosts_addr {
    int     family;    /* AF_INET or AF_INET6 */
    uint8_t addr[16];  /* the first 4 bytes for AF_INET */
};
size_t hosts_collect(const char *text, size_t len, const char *name, int family, struct hosts_addr *out, size_t cap,
                     const char **names, size_t *names_len);

/* The reverse lookup getnameinfo uses: the canonical name (first name field) of the first line in the /etc/hosts text whose
 * dotted IPv4 address is `addr` and that lists a name. Returns the name's length and points *name into `text`, or 0. */
size_t hosts_reverse(const char *text, size_t len, const uint8_t addr[4], const char **name);

/* hosts_reverse for a 16-byte IPv6 address: the first IPv6 line with the same address (in any textual form). */
size_t hosts_reverse6(const char *text, size_t len, const uint8_t addr[16], const char **name);

/* Reverse lookup for gethostbyaddr: like hosts_reverse/hosts_reverse6, but returns the matching line's whole names
 * field (canonical name and aliases, separated by blanks) rather than only its first name. */
size_t hosts_reverse_names(const char *text, size_t len, int family, const uint8_t *addr, const char **names);

struct hostent;

/* Lay a hostent out in the caller's buffer, as the *_r functions do: the alias and address pointer arrays (pointer-aligned),
 * the address bytes (4 or 16 per address for `af`), then the `names_len` bytes of `names` split at blanks into h_name and
 * h_aliases. Returns 0, or ERANGE (34) when `buf_len` bytes are not enough, in which case neither `he` nor bytes of `buf`
 * at or past `buf_len` are written. */
int hostent_pack(struct hostent *he, char *buf, size_t buf_len, const char *names, size_t names_len, int af,
                 const char *const *addrs, size_t naddrs);

/* Build a Linux `struct sockaddr_in` (16 bytes) for bind/connect/sendto: family AF_INET (2) as a little-endian
 * u16, `port` in network byte order, the 4 address bytes, 8 bytes of zero padding. */
void ipv4_sockaddr(const uint8_t addr[4], uint16_t port, uint8_t out[16]);

/* Resolve `host` (a dotted-decimal literal, or a name for dns_resolve) and build the sockaddr_in for `port` in
 * `out`. A valid dotted literal never reaches the kernel. 0 on success; -errno from dns_resolve on a lookup
 * failure; -EINVAL (-22) for a NULL argument. `out` is written only on success. */
long resolve_ipv4_sockaddr(const char *host, uint16_t port, uint8_t out[16]);

/* Resolve `host`, open a TCP socket and connect it to host:port. Returns the connected socket descriptor (>= 0),
 * or -errno: the resolver's error for a bad or unknown name, -EINVAL for a NULL host, or the socket()/connect()
 * error. A connect that is still in progress is polled for a short while (the stack is driven by netpoll); a
 * socket that fails to connect is closed, never leaked. */
long tcp_connect_host(const char *host, uint16_t port);

/* ---- glibc-compatible gethostbyname()/gethostbyname2() ------------------------------------------------------ */

#define AF_INET 2
#define AF_INET6 10

/* h_errno values (glibc numbering). */
#define NETDB_INTERNAL -1
#define HOST_NOT_FOUND 1
#define TRY_AGAIN      2
#define NO_RECOVERY    3
#define NO_DATA        4

struct hostent {
    char  *h_name;       /* the canonical name from /etc/hosts, else the name asked for */
    char **h_aliases;    /* NULL-terminated; the /etc/hosts line's other names (up to 16), else empty */
    int    h_addrtype;   /* AF_INET, or AF_INET6 from gethostbyname2 */
    int    h_length;     /* 4 or 16 */
    char **h_addr_list;  /* NULL-terminated; every /etc/hosts address of the family, else one */
};
#define h_addr h_addr_list[0]

extern int h_errno;

/* Look `name` up: a dotted-decimal literal, /etc/hosts, then the kernel resolver. The result is in static
 * storage that the next call overwrites (as in glibc), so it is not thread-safe. NULL on failure with h_errno set:
 * HOST_NOT_FOUND for a name that does not exist or is malformed or a NULL name, TRY_AGAIN when the server did
 * not answer or the lookup failed for another reason. h_errno is reset to 0 on success. */
struct hostent *gethostbyname(const char *name);

/* gethostbyname for a family: AF_INET (what gethostbyname does) or AF_INET6. Every /etc/hosts line of that family for the name
 * is listed in file order (up to 16 addresses), with h_length 4 or 16; a literal answers only its own family; AF_INET6 has no
 * DNS fallback (the kernel resolver has no AAAA), so a name not in /etc/hosts is HOST_NOT_FOUND. Another family is NO_DATA. */
struct hostent *gethostbyname2(const char *name, int af);

/* Reverse an IPv4/IPv6 address through /etc/hosts. The result shares gethostbyname's static storage. A mapped IPv6
 * address is named from the IPv4 lines but returned unchanged. AF_UNSPEC selects AF_INET for len 4 and AF_INET6 for
 * len 16. An unknown address under an explicit family is HOST_NOT_FOUND (there is no reverse DNS); AF_UNSPEC instead
 * reports NETDB_INTERNAL/EAFNOSUPPORT on a miss. An unsupported family or short length is NETDB_INTERNAL with errno
 * EAFNOSUPPORT, and a long length is TRY_AGAIN. NULL is rejected with HOST_NOT_FOUND. */
struct hostent *gethostbyaddr(const void *addr, unsigned int len, int family);

/* Reentrant forms (glibc signatures). The answer is laid out in `buf` and `*ret` (see hostent_pack); `*result` is `ret` on a
 * hit and NULL otherwise, and `*h_errnop` takes the h_errno value; the global h_errno and the static gethostbyname storage are
 * not touched. Return value: 0 for a hit and for a definite miss (*h_errnop HOST_NOT_FOUND, or TRY_AGAIN for a long
 * gethostbyaddr length); ERANGE when `buflen` cannot hold the answer (*h_errnop NETDB_INTERNAL, errno ERANGE; retry with a
 * larger buffer); EAFNOSUPPORT for an unsupported family (*h_errnop NO_DATA for the name forms, NETDB_INTERNAL for
 * gethostbyaddr_r, which also reports short lengths and AF_UNSPEC misses this way); EAGAIN when the resolver did not answer
 * (*h_errnop TRY_AGAIN). errno is set to any non-zero return value. Unlike glibc, a miss never needs a minimum buffer size. */
int gethostbyname_r(const char *name, struct hostent *ret, char *buf, size_t buflen, struct hostent **result, int *h_errnop);
int gethostbyname2_r(const char *name, int af, struct hostent *ret, char *buf, size_t buflen, struct hostent **result,
                     int *h_errnop);
int gethostbyaddr_r(const void *addr, unsigned int len, int family, struct hostent *ret, char *buf, size_t buflen,
                    struct hostent **result, int *h_errnop);

/* ---- interface names (glibc puts these in <net/if.h>) --------------------------------------------------------- */

#define IF_NAMESIZE 16

/* The index of the interface called `name` (SIOCGIFINDEX on a scratch UDP socket), or 0 with errno ENODEV when there is none.
 * Names are case-sensitive; one of IF_NAMESIZE characters or more, and a NULL name, are ENODEV without asking the kernel.
 * When no socket can be opened, 0 with that error. */
unsigned int if_nametoindex(const char *name);

/* Write the name of interface `index` (SIOCGIFNAME) into `buf`, which holds at least IF_NAMESIZE bytes, and return `buf`; NULL
 * with errno ENXIO when no interface has that index (index 0 included), or with the socket error. */
char *if_indextoname(unsigned int index, char *buf);

/* ---- getaddrinfo() ------------------------------------------------------------------------------------------- */

#define AF_UNSPEC 0

#define SOCK_STREAM 1
#define SOCK_DGRAM  2
#define SOCK_RAW    3

#define IPPROTO_TCP 6
#define IPPROTO_UDP 17

#define AI_PASSIVE     0x0001
#define AI_CANONNAME   0x0002
#define AI_NUMERICHOST 0x0004
#define AI_V4MAPPED    0x0008
#define AI_ALL         0x0010
#define AI_ADDRCONFIG  0x0020
#define AI_NUMERICSERV 0x0400

#define EAI_BADFLAGS -1
#define EAI_NONAME   -2
#define EAI_AGAIN    -3
#define EAI_FAIL     -4
#define EAI_FAMILY   -6
#define EAI_SOCKTYPE -7
#define EAI_SERVICE  -8
#define EAI_ADDRFAMILY -9
#define EAI_MEMORY   -10
#define EAI_OVERFLOW -12

struct addrinfo {
    int              ai_flags;
    int              ai_family;
    int              ai_socktype;
    int              ai_protocol;
    unsigned int     ai_addrlen;
    uint8_t         *ai_addr;       /* a 16-byte sockaddr_in, or a 28-byte sockaddr_in6 for AF_INET6 */
    char            *ai_canonname;
    struct addrinfo *ai_next;
};

/* Resolve `node` and `service` into a list of addresses for socket()/connect()/bind(). AF_UNSPEC, AF_INET and AF_INET6 are
 * served, anything else is EAI_FAMILY. IPv6 comes from literals (with an optional numeric "%scope") and /etc/hosts lines; the
 * kernel resolver answers IPv4 only, which AF_INET6 uses as ::ffff:a.b.c.d under AI_V4MAPPED. Returns 0 and a list in *res
 * (free it with freeaddrinfo), or an EAI_* code. glibc-compatible in the cases that were measured: see test_netdb_abi.c. */
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);

/* AI_ADDRCONFIG helpers, exported for the host tests. A family is configured when it has a non-loopback address (glibc,
 * measured): an IPv4 address outside 127/8 in the SIOCGIFCONF records (`conf`, `len` bytes of 40-byte ifreq), or an IPv6
 * address other than ::1 in the text of /proc/net/if_inet6 (a link-local address counts). */
int ifconf_has_nonloopback4(const uint8_t *conf, size_t len);
int if_inet6_has_nonloopback(const char *text, size_t len);

/* What AI_ADDRCONFIG does to a lookup for `family` given which families are configured: nothing, keep only one family (the
 * other one's addresses are dropped and its literals are EAI_ADDRFAMILY), or EAI_NONAME for the whole lookup. */
enum { ADDRCONFIG_KEEP_ALL, ADDRCONFIG_ONLY_INET, ADDRCONFIG_ONLY_INET6, ADDRCONFIG_NONAME };
int addrconfig_rule(int family, int have4, int have6);

/* Release a list returned by getaddrinfo. NULL is a no-op. */
void freeaddrinfo(struct addrinfo *res);

/* Text for an EAI_* code (never NULL). */
const char *gai_strerror(int code);

/* ---- getnameinfo() ------------------------------------------------------------------------------------------- */

#define NI_NUMERICHOST 1
#define NI_NUMERICSERV 2
#define NI_NOFQDN      4
#define NI_NAMEREQD    8
#define NI_DGRAM       16

#define NI_MAXHOST 1025
#define NI_MAXSERV 32

/* Turn a 16-byte sockaddr_in or a 28-byte sockaddr_in6 into text. `host` and `serv` are optional: NULL or a zero length
 * means "do not return that part". The host is the first name of the /etc/hosts line with the address (::ffff:a.b.c.d is
 * looked up as a.b.c.d), else "localhost" for 127.0.0.1 and ::1, else the numeric form (there is no reverse DNS): dotted
 * decimal, or inet_ntop text with "%N" for a non-zero sin6_scope_id. NI_NUMERICHOST forces the numeric form and NI_NAMEREQD
 * turns "no name" into EAI_NONAME. The service is a known name (see getaddrinfo) unless NI_NUMERICSERV, else the decimal
 * port. NI_NOFQDN, NI_DGRAM and the IDN bits (0x20, 0x40, 0x80) are accepted and change nothing; any other bit is
 * EAI_BADFLAGS. A NULL address, a short one (< 16 bytes for AF_INET, < 28 for AF_INET6) or another family is EAI_FAMILY; a
 * buffer too small for the text plus its NUL is EAI_OVERFLOW. The host is written before the service is looked at.
 * Returns 0 or an EAI_* code. */
int getnameinfo(const uint8_t *sa, unsigned int salen, char *host, unsigned int hostlen, char *serv,
                unsigned int servlen, int flags);

#endif /* MOQI_NETDB_H */
