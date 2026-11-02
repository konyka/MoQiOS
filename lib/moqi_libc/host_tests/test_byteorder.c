#include <assert.h>
#include <stdint.h>

#include "../include/byteorder.h"

/* Expected values are from glibc's htons/htonl on a little-endian host, which is also the byte order of every
 * MoQiOS target (x86_64, riscv64, aarch64 all run little-endian). */
int main(void) {
    assert(htons(0x1234) == 0x3412);
    assert(htons(0) == 0);
    assert(htons(0xFFFF) == 0xFFFF);
    assert(htons(0x00FF) == 0xFF00);
    assert(htonl(0x12345678u) == 0x78563412u);
    assert(htonl(0) == 0);
    assert(htonl(0xFFFFFFFFu) == 0xFFFFFFFFu);
    assert(htonl(0x000000FFu) == 0xFF000000u);
    assert(ntohs(0x3412) == 0x1234);
    assert(ntohl(0x78563412u) == 0x12345678u);
    for (uint32_t v = 0; v < 0x10000; v += 257) {
        assert(ntohs(htons((uint16_t)v)) == (uint16_t)v);
        assert(ntohl(htonl(v * 65537u)) == v * 65537u);
    }
    /* The result types are fixed width: a u16 stays u16, a u32 stays u32. */
    assert(sizeof(htons(1)) <= sizeof(int));
    assert(sizeof(htonl(1)) == 4);
    /* The port bytes land in network order in memory, which is what a sockaddr_in needs. */
    uint16_t port = htons(8080);
    assert(((uint8_t *)&port)[0] == 0x1F && ((uint8_t *)&port)[1] == 0x90);
    return 0;
}
