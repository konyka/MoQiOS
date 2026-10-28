/// hello116: exec target for hello115 scenario F (credentials across execve).
///
/// Reports what it inherited through its exit status, one bit per fact:
///   bit0  saved uid == effective uid (execve copies euid into suid)
///   bit1  permitted capability set is empty
///   bit2  effective set == permitted set
///   bit3  effective uid is 0
///   bit4  setuid(0) succeeded
/// Started on its own (not through hello115) it only prints that summary.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_SETUID    174
#define SYS_GETRESUID 179
#define SYS_CAPGET    306

void _start(void) {
    uint32_t r = 0xDEAD, e = 0xDEAD, s = 0xDEAD;
    syscall3(SYS_GETRESUID, (uint64_t)&r, (uint64_t)&e, (uint64_t)&s);
    uint32_t hdr[2] = { 0x20080522u, 0 };
    uint32_t data[6] = { 0 };
    syscall2(SYS_CAPGET, (uint64_t)hdr, (uint64_t)data);
    int bits = 0;
    if (s == e) bits |= 1;
    if (data[1] == 0) bits |= 2;
    if (data[0] == data[1]) bits |= 4;
    if (e == 0) bits |= 8;
    if (syscall1(SYS_SETUID, 0) == 0) bits |= 16;
    const char *msg = "hello116: credential report done\n";
    uint64_t n = 0;
    while (msg[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)msg, n);
    syscall1(SYS_EXIT, (uint64_t)bits);
    for (;;) {}
}
