/* byteorder.h — host/network byte order conversion, header-only.
 *
 * Every MoQiOS target (x86_64, riscv64, aarch64) runs little-endian, so host order is the byte-swap of network
 * order. A big-endian target would make these wrong, so the header refuses to compile there instead.
 */
#ifndef MOQI_BYTEORDER_H
#define MOQI_BYTEORDER_H

#include <stdint.h>

#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "moqi_libc byteorder.h assumes a little-endian target"
#endif

static inline uint16_t htons(uint16_t v) { return (uint16_t)((v >> 8) | (v << 8)); }
static inline uint16_t ntohs(uint16_t v) { return htons(v); }
static inline uint32_t htonl(uint32_t v) {
    return (v >> 24) | ((v >> 8) & 0x0000FF00u) | ((v << 8) & 0x00FF0000u) | (v << 24);
}
static inline uint32_t ntohl(uint32_t v) { return htonl(v); }

#endif /* MOQI_BYTEORDER_H */
