/// hello195: dns_resolve (system call 495) - hostname to IPv4 address through the kernel resolver.
/// Only names the kernel answers on its own are used (the static table and dotted decimal), so the test does
/// not depend on a reachable DNS server.

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
static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}


#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_DNS_RESOLVE 495
#define ENOENT_ 2
#define EFAULT_ 14
#define EINVAL_ 22
#define ENAMETOOLONG_ 36

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello195:   ok   " : "hello195:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void print_num(int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}
/* dns_resolve(name, out4): 0 and the address in out4, or -errno. */
static int64_t resolve(const char *name, uint8_t *out) {
    return syscall2(SYS_DNS_RESOLVE, (uint64_t)name, (uint64_t)out);
}
static void expect(int64_t v, int64_t errno_, const char *what) {
    if (v != -errno_) { print("hello195:   got "); print_num(v); }
    check(v == -errno_, what);
}
static int same(const uint8_t *a, uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3) {
    return a[0] == b0 && a[1] == b1 && a[2] == b2 && a[3] == b3;
}

void _start(void) {
    print("hello195: dns_resolve\n");
    uint8_t ip[4];
    static char longname[300];

    for (int i = 0; i < 4; i++) ip[i] = 0xAA;
    check(resolve("localhost", ip) == 0 && same(ip, 127, 0, 0, 1), "localhost resolves to 127.0.0.1");
    for (int i = 0; i < 4; i++) ip[i] = 0xAA;
    check(resolve("LocalHost", ip) == 0 && same(ip, 127, 0, 0, 1), "names are case-insensitive");
    for (int i = 0; i < 4; i++) ip[i] = 0xAA;
    check(resolve("gateway", ip) == 0 && same(ip, 10, 0, 2, 2), "gateway resolves to the slirp host 10.0.2.2");
    for (int i = 0; i < 4; i++) ip[i] = 0xAA;
    check(resolve("192.168.7.9", ip) == 0 && same(ip, 192, 168, 7, 9), "a dotted-decimal address is returned as is");

    for (int i = 0; i < 4; i++) ip[i] = 0xAA;
    expect(resolve("", ip), ENOENT_, "an empty name is ENOENT");
    check(same(ip, 0xAA, 0xAA, 0xAA, 0xAA), "a failed lookup leaves the output untouched");
    for (int i = 0; i < 299; i++) longname[i] = 'a';
    longname[299] = 0;
    expect(resolve(longname, ip), ENAMETOOLONG_, "a name longer than 253 bytes is ENAMETOOLONG");
    expect(resolve("localhost", (uint8_t *)8), EFAULT_, "an unwritable output pointer is EFAULT");
    expect(resolve("localhost", (uint8_t *)0), EFAULT_, "a NULL output pointer is EFAULT");
    expect(resolve((const char *)8, ip), EFAULT_, "an unreadable name pointer is EFAULT");
    expect(resolve((const char *)0, ip), EFAULT_, "a NULL name pointer is EFAULT");
    expect(resolve("bad name!", ip), EINVAL_, "a name with characters that cannot be in a hostname is EINVAL");
    expect(resolve("-leading.example", ip), EINVAL_, "a label may not start with a hyphen");
    expect(resolve("a..b", ip), EINVAL_, "an empty label is EINVAL");

    print(failures == 0 ? "hello195: PASS\n" : "hello195: FAIL\n");
    print("hello195 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
