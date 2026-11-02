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

#endif /* MOQI_NETDB_H */
