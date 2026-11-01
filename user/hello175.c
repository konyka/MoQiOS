/// hello175: netdevice ioctls (SIOCGIFCONF, SIOCGIFADDR, SIOCGIFFLAGS, SIOCGIFMTU, SIOCGIFHWADDR, SIOCGIFINDEX, SIOCGIFNAME, ...).

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
#define SYS_CLOSE     11
#define SYS_SOCKET    117
#define SYS_IOCTL     165
#define AF_INET 2
#define SOCK_DGRAM 2
#define SIOCGIFNAME    0x8910
#define SIOCGIFCONF    0x8912
#define SIOCGIFFLAGS   0x8913
#define SIOCGIFADDR    0x8915
#define SIOCGIFBRDADDR 0x8919
#define SIOCGIFNETMASK 0x891b
#define SIOCGIFMTU     0x8921
#define SIOCGIFHWADDR  0x8927
#define SIOCGIFINDEX   0x8933
#define IFF_UP 0x1
#define IFF_LOOPBACK 0x8
#define IFF_RUNNING 0x40
#define ENODEV_ 19
#define EFAULT_ 14
#define ENOTTY_ 25
#define EADDRNOTAVAIL_ 99

struct ifreq { char name[16]; union { uint8_t raw[24]; struct { uint16_t fam; uint16_t port; uint8_t addr[4]; } in; int ival; short flags; struct { uint16_t fam; uint8_t mac[6]; } hw; } u; };
struct ifconf { int len; int pad; struct ifreq *buf; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello175:   ok   " : "hello175:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void setname(struct ifreq *r, const char *n) {
    for (int i = 0; i < 40; i++) ((char *)r)[i] = 0;
    for (int i = 0; n[i] && i < 15; i++) r->name[i] = n[i];
}
static int streq(const char *a, const char *b) {
    int i = 0;
    while (a[i] && a[i] == b[i]) i++;
    return a[i] == b[i];
}

void _start(void) {
    print("hello175: netdevice ioctls\n");
    int64_t s = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
    check(s >= 0, "A: a UDP socket to ask on");

    /* A: SIOCGIFCONF lists the interfaces (size query first, then the data) */
    struct ifconf ic = { 0, 0, 0 };
    check(syscall3(SYS_IOCTL, s, SIOCGIFCONF, (uint64_t)&ic) == 0, "A: SIOCGIFCONF with a NULL buffer succeeds");
    check(ic.len >= 40 && ic.len % 40 == 0, "A: and reports the needed size (a multiple of 40, at least one interface)");
    struct ifreq list[4];
    for (int i = 0; i < 160; i++) ((char *)list)[i] = 0x55;
    ic.len = sizeof(list);
    ic.buf = list;
    check(syscall3(SYS_IOCTL, s, SIOCGIFCONF, (uint64_t)&ic) == 0 && ic.len >= 40, "A: SIOCGIFCONF with a buffer succeeds");
    int n = ic.len / 40;
    check(n >= 1 && streq(list[0].name, "lo"), "A: the first interface is lo");
    check(list[0].u.in.fam == AF_INET && list[0].u.in.addr[0] == 127 && list[0].u.in.addr[3] == 1, "A: lo is 127.0.0.1");
    struct ifreq tiny[1];
    struct ifconf small = { 39, 0, tiny };
    check(syscall3(SYS_IOCTL, s, SIOCGIFCONF, (uint64_t)&small) == 0 && small.len == 0, "A: a buffer too small for one record gets 0 bytes");

    /* B: per-interface queries on lo */
    struct ifreq r;
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, s, SIOCGIFFLAGS, (uint64_t)&r) == 0 && (r.u.flags & (IFF_UP | IFF_LOOPBACK | IFF_RUNNING)) == (IFF_UP | IFF_LOOPBACK | IFF_RUNNING), "B: lo is UP, LOOPBACK and RUNNING");
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, s, SIOCGIFADDR, (uint64_t)&r) == 0 && r.u.in.fam == AF_INET && r.u.in.addr[0] == 127 && r.u.in.addr[3] == 1, "B: SIOCGIFADDR lo = 127.0.0.1");
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, s, SIOCGIFNETMASK, (uint64_t)&r) == 0 && r.u.in.addr[0] == 255 && r.u.in.addr[1] == 0, "B: SIOCGIFNETMASK lo = 255.0.0.0");
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, s, SIOCGIFMTU, (uint64_t)&r) == 0 && r.u.ival >= 1500, "B: SIOCGIFMTU lo is at least 1500");
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, s, SIOCGIFINDEX, (uint64_t)&r) == 0 && r.u.ival == 1, "B: SIOCGIFINDEX lo = 1");
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, s, SIOCGIFHWADDR, (uint64_t)&r) == 0 && r.u.hw.fam == 772, "B: SIOCGIFHWADDR lo has family ARPHRD_LOOPBACK (772)");
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, s, SIOCGIFBRDADDR, (uint64_t)&r) == -EADDRNOTAVAIL_, "B: lo has no broadcast address (EADDRNOTAVAIL)");

    /* C: name <-> index */
    setname(&r, "");
    r.u.ival = 1;
    check(syscall3(SYS_IOCTL, s, SIOCGIFNAME, (uint64_t)&r) == 0 && streq(r.name, "lo"), "C: SIOCGIFNAME for index 1 is lo");
    setname(&r, "");
    r.u.ival = 99;
    check(syscall3(SYS_IOCTL, s, SIOCGIFNAME, (uint64_t)&r) == -ENODEV_, "C: SIOCGIFNAME for an unknown index is ENODEV");

    /* D: errors */
    setname(&r, "nosuch0");
    check(syscall3(SYS_IOCTL, s, SIOCGIFADDR, (uint64_t)&r) == -ENODEV_, "D: an unknown interface name is ENODEV");
    for (int i = 0; i < 40; i++) ((char *)&r)[i] = 'x';
    check(syscall3(SYS_IOCTL, s, SIOCGIFADDR, (uint64_t)&r) == -ENODEV_, "D: a name without a terminator names nothing (ENODEV)");
    check(syscall3(SYS_IOCTL, s, SIOCGIFADDR, 0) == -EFAULT_, "D: a NULL argument is EFAULT");
    check(syscall3(SYS_IOCTL, s, SIOCGIFCONF, 0) == -EFAULT_, "D: SIOCGIFCONF with a NULL argument is EFAULT");
    setname(&r, "lo");
    check(syscall3(SYS_IOCTL, 1, SIOCGIFADDR, (uint64_t)&r) == -ENOTTY_, "D: on stdout (not a socket) it is ENOTTY");

    /* E: if eth0 exists, its answers are coherent (not asserted when there is no NIC) */
    if (n >= 2) {
        check(streq(list[1].name, "eth0"), "E: the second interface is eth0");
        setname(&r, "eth0");
        check(syscall3(SYS_IOCTL, s, SIOCGIFFLAGS, (uint64_t)&r) == 0 && (r.u.flags & IFF_UP) && !(r.u.flags & IFF_LOOPBACK), "E: eth0 is UP and not loopback");
        setname(&r, "eth0");
        check(syscall3(SYS_IOCTL, s, SIOCGIFHWADDR, (uint64_t)&r) == 0 && r.u.hw.fam == 1, "E: eth0 has family ARPHRD_ETHER (1)");
        setname(&r, "eth0");
        check(syscall3(SYS_IOCTL, s, SIOCGIFBRDADDR, (uint64_t)&r) == 0 && r.u.in.addr[3] == 255, "E: eth0 has a broadcast address ending in .255");
    }

    syscall1(SYS_CLOSE, s);
    print(failures == 0 ? "hello175: PASS\n" : "hello175: FAIL\n");
    print("hello175 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
