/// hello149: reproducer for an intermittent kernel/user disagreement about a forked
/// child's stack (seen on SMP=8 only so far). NOT run by init or the smoke test; it is
/// only in the ramdisk so it can be started by hand. Untested from the shell.
///
/// A forked child builds a sockaddr_in on its own stack and passes it to sendto().
/// In the SMP=8 smoke harness (inserted before hello148) about 2 of 3 runs hit 3 bad
/// iterations within 60: sendto() fails because the kernel's copyFromUser sees an
/// all-zero sockaddr. What was observed on those failures:
///   - the child itself reads back the correct values just before the syscall;
///   - at the syscall the PTE is present and writable (0x...67, no COW bit), the
///     frame refcount is 1, and CR3 equals the task's page table;
///   - the frame that PTE names, read through the kernel's direct map, holds the
///     process's initial stack (ELF aux-vector words near the sockaddr), with the
///     child's stores missing;
///   - an invlpg of the page followed by a second copyFromUser still reads zeros,
///     and building the kernel with PCID disabled changes nothing.
/// The cause is NOT known. One unverified hypothesis is that the child's stores
/// reach a different frame than the one the page table names now.

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
#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_CLOSE 11
#define SYS_FORK 57
#define SYS_WAITPID 6
#define SYS_NANOSLEEP 35
#define SYS_NETPOLL 104
#define SYS_SOCKET 117
#define SYS_BIND 118
#define SYS_SENDTO 121
#define SYS_RECVFROM 122
#define AF_INET 2
#define SOCK_DGRAM 2
struct ts { int64_t s, n; };
static void print(const char *s) { uint64_t n = 0; while (s[n]) n++; syscall3(SYS_WRITE, 1, (uint64_t)s, n); }
static void dec(int64_t v) { char b[24]; int i = 23; b[i] = 0; if (v < 0) { print("-"); v = -v; } if (v == 0) b[--i] = '0'; while (v > 0) { b[--i] = '0' + v % 10; v /= 10; } print(b + i); }
static void sleep_ms(int ms) { struct ts t = { 0, (int64_t)ms * 1000000 }; syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0); }
static void mk_addr(uint8_t *a, uint16_t port) { for (int i = 0; i < 16; i++) a[i] = 0; a[0] = AF_INET; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)(port & 0xff); a[4] = 127; a[7] = 1; }
static int64_t udp_socket(uint16_t port) { int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0); uint8_t a[16]; mk_addr(a, port); syscall3(SYS_BIND, (uint64_t)u, (uint64_t)a, 16); return u; }
void _start(void) {
    print("hello149: sockaddr built on a forked child's stack must reach the kernel intact\n");
    int bad = 0;
    for (int it = 0; it < 60 && bad < 3; it++) {
        int64_t u = udp_socket(24105);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            int64_t v = udp_socket(24106);
            sleep_ms(120);
            uint8_t a[16];
            mk_addr(a, 24105);
            static char msgbuf[8] = {0};
            msgbuf[0] = 'w'; msgbuf[1] = 'a'; msgbuf[2] = 'k'; msgbuf[3] = 'e';
            int64_t sr = syscall6(SYS_SENDTO, (uint64_t)v, (uint64_t)msgbuf, 4, 0, (uint64_t)a, 16);
            syscall1(SYS_EXIT, sr == 4 ? 0 : 1);
            for (;;) {}
        }
        int st = 0;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        if (st != 0) { bad++; print("hello149: BAD iteration "); dec(it); print(" child sendto failed, status="); dec(st); print("\n"); }
        syscall1(SYS_CLOSE, (uint64_t)u);
    }
    print(bad ? "hello149: FAIL\n" : "hello149: PASS\n");
    syscall1(SYS_EXIT, bad != 0);
    for (;;) {}
}
