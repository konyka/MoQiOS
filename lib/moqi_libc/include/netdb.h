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

#endif /* MOQI_NETDB_H */
