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

/* Parse "a.b.c.d" into 4 bytes (network order), with inet_pton(AF_INET) semantics: exactly four decimal fields of
 * 0..255, no leading zeros, no whitespace, no trailing text. Returns 1 on success, 0 when `text` is not an IPv4
 * address (NULL arguments included). `out` is written only on success. */
int ipv4_from_text(const char *text, uint8_t out[4]);

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

/* ---- glibc-compatible gethostbyname() (IPv4 only) ----------------------------------------------------------- */

#define AF_INET 2

/* h_errno values (glibc numbering). */
#define HOST_NOT_FOUND 1
#define TRY_AGAIN      2
#define NO_RECOVERY    3
#define NO_DATA        4

struct hostent {
    char  *h_name;       /* the name asked for */
    char **h_aliases;    /* NULL-terminated; always empty here */
    int    h_addrtype;   /* AF_INET */
    int    h_length;     /* 4 */
    char **h_addr_list;  /* NULL-terminated; exactly one address */
};
#define h_addr h_addr_list[0]

extern int h_errno;

/* Look `name` up: a dotted-decimal literal, or a name through the kernel resolver. The result is in static
 * storage that the next call overwrites (as in glibc), so it is not thread-safe. NULL on failure with h_errno set:
 * HOST_NOT_FOUND for a name that does not exist or is malformed or a NULL name, TRY_AGAIN when the server did
 * not answer or the lookup failed for another reason. h_errno is reset to 0 on success. */
struct hostent *gethostbyname(const char *name);

/* ---- getaddrinfo() (IPv4 only) ------------------------------------------------------------------------------ */

#define AF_UNSPEC 0

#define SOCK_STREAM 1
#define SOCK_DGRAM  2
#define SOCK_RAW    3

#define IPPROTO_TCP 6
#define IPPROTO_UDP 17

#define AI_PASSIVE     0x0001
#define AI_CANONNAME   0x0002
#define AI_NUMERICHOST 0x0004
#define AI_NUMERICSERV 0x0400

#define EAI_BADFLAGS -1
#define EAI_NONAME   -2
#define EAI_AGAIN    -3
#define EAI_FAIL     -4
#define EAI_FAMILY   -6
#define EAI_SOCKTYPE -7
#define EAI_SERVICE  -8
#define EAI_MEMORY   -10
#define EAI_OVERFLOW -12

struct addrinfo {
    int              ai_flags;
    int              ai_family;
    int              ai_socktype;
    int              ai_protocol;
    unsigned int     ai_addrlen;
    uint8_t         *ai_addr;       /* a 16-byte sockaddr_in */
    char            *ai_canonname;
    struct addrinfo *ai_next;
};

/* Resolve `node` and `service` into a list of addresses for socket()/connect()/bind(). IPv4 only: AF_UNSPEC and
 * AF_INET are served, anything else is EAI_FAMILY. Returns 0 and a list in *res (free it with freeaddrinfo), or
 * an EAI_* code. glibc-compatible in the cases that were measured: see test_netdb_abi.c. */
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);

/* Release a list returned by getaddrinfo. NULL is a no-op. */
void freeaddrinfo(struct addrinfo *res);

/* Text for an EAI_* code (never NULL). */
const char *gai_strerror(int code);

/* ---- getnameinfo() (IPv4 only) ------------------------------------------------------------------------------ */

#define NI_NUMERICHOST 1
#define NI_NUMERICSERV 2
#define NI_NOFQDN      4
#define NI_NAMEREQD    8
#define NI_DGRAM       16

#define NI_MAXHOST 1025
#define NI_MAXSERV 32

/* Turn a 16-byte sockaddr_in into text. `host` and `serv` are optional: NULL or a zero length means "do not
 * return that part". The host is "localhost" for 127.0.0.1 and dotted decimal otherwise (there is no reverse DNS);
 * NI_NUMERICHOST forces the dotted form and NI_NAMEREQD turns "no name" into EAI_NONAME. The service is a known
 * name (see getaddrinfo) unless NI_NUMERICSERV, else the decimal port. NI_NOFQDN, NI_DGRAM and the IDN bits
 * (0x20, 0x40, 0x80) are accepted and change nothing; any other bit is EAI_BADFLAGS. A NULL, short (< 16 bytes) or
 * non-AF_INET address is EAI_FAMILY; a buffer too small for the text plus its NUL is EAI_OVERFLOW. The host is
 * written before the service is looked at. Returns 0 or an EAI_* code. */
int getnameinfo(const uint8_t *sa, unsigned int salen, char *host, unsigned int hostlen, char *serv,
                unsigned int servlen, int flags);

#endif /* MOQI_NETDB_H */
