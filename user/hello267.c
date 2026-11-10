/// hello267: a closing SO_REUSEPORT TCP listener hands its not-yet-accepted connections to the sibling listener.

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
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_SENDTO    121
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define SYS_RECVFROM  122
#define SO_RCVTIMEO 20
#define MSG_DONTWAIT 0x40
#define SYS_SETUID    174
#define SYS_IOCTL     165
#define SIOCGIFADDR   0x8915
#define EADDRNOTAVAIL_ 99
#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define SO_REUSEPORT 15
#define EACCES_ 13
#define EINVAL_ 22
#define EADDRINUSE_ 98

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello267:   ok   " : "hello267:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); }
}
static void mk_addr(uint8_t *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 2; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}
static void mk_addr6(uint8_t *a, int port) {
    for (int i = 0; i < 28; i++) a[i] = 0;
    a[0] = AF_INET6;
    a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port;
    a[8 + 15] = 1;
}
static int64_t sock4(void) { return syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0); }
static int64_t bind4(int64_t s, int port) {
    uint8_t sa[16];
    mk_addr(sa, port);
    return syscall3(SYS_BIND, (uint64_t)s, (uint64_t)sa, 16);
}
static void reuseport(int64_t s) {
    int one = 1;
    syscall5(SYS_SETSOCKOPT, (uint64_t)s, SOL_SOCKET, SO_REUSEPORT, (uint64_t)&one, 4);
}
static void reuse(int64_t s) {
    int one = 1;
    syscall5(SYS_SETSOCKOPT, (uint64_t)s, SOL_SOCKET, SO_REUSEADDR, (uint64_t)&one, 4);
}

void _start(void) {
    print("hello267: SO_REUSEPORT listener close migrates its backlog\n");
    /* when a SO_REUSEPORT listener closes, its not-yet-accepted connections move to the sibling listener instead of being reset */
    {
        int64_t l1 = sock4(), l2 = sock4();
        reuseport(l1); reuseport(l2);
        check(bind4(l1, 18410) == 0 && bind4(l2, 18410) == 0, "two listeners share the port");
        check(syscall2(SYS_LISTEN, (uint64_t)l1, 16) == 0 && syscall2(SYS_LISTEN, (uint64_t)l2, 16) == 0, "both listen");
        uint8_t ia[16];
        mk_addr(ia, 18410);
        int64_t cl[4];
        for (int k = 0; k < 4; k++) {
            cl[k] = sock4();
            syscall3(SYS_CONNECT, (uint64_t)cl[k], (uint64_t)ia, 16);
        }
        pump(150);
        syscall1(SYS_CLOSE, (uint64_t)l1);
        pump(50);
        int accepted = 0;
        for (int round = 0; round < 40 && accepted < 4; round++) {
            syscall1(SYS_NETPOLL, 0);
            int64_t ac = syscall4(SYS_ACCEPT4, (uint64_t)l2, 0, 0, 0x800);
            if (ac >= 0) {
                accepted++;
                syscall1(SYS_CLOSE, (uint64_t)ac);
            } else sleep_ms(5);
        }
        check(accepted == 4, "all 4 connections, including those queued on the closed listener, are accepted by the survivor");
        for (int k = 0; k < 4; k++) syscall1(SYS_CLOSE, (uint64_t)cl[k]);
        syscall1(SYS_CLOSE, (uint64_t)l2);
    }

    /* With three listeners, the closed one's queued connections are spread over BOTH survivors (by the peer's hash, like a new SYN), not all
     * pushed onto the first sibling with room. Only m1 listens while the 12 clients connect, so they all queue on it; m2 and m3 start
     * listening afterwards and m1 closes. */
    {
        int64_t m1 = sock4(), m2 = sock4(), m3 = sock4();
        reuseport(m1); reuseport(m2); reuseport(m3);
        check(bind4(m1, 18411) == 0 && bind4(m2, 18411) == 0 && bind4(m3, 18411) == 0, "three sockets share a port");
        check(syscall2(SYS_LISTEN, (uint64_t)m1, 32) == 0, "the first one listens alone");
        uint8_t ma[16];
        mk_addr(ma, 18411);
        int64_t mc[12];
        for (int k = 0; k < 12; k++) { mc[k] = sock4(); syscall3(SYS_CONNECT, (uint64_t)mc[k], (uint64_t)ma, 16); }
        pump(200);
        check(syscall2(SYS_LISTEN, (uint64_t)m2, 32) == 0 && syscall2(SYS_LISTEN, (uint64_t)m3, 32) == 0, "then the other two listen");
        syscall1(SYS_CLOSE, (uint64_t)m1);
        pump(50);
        int g2 = 0, g3 = 0;
        for (int round = 0; round < 60 && g2 + g3 < 12; round++) {
            syscall1(SYS_NETPOLL, 0);
            int64_t a2 = syscall4(SYS_ACCEPT4, (uint64_t)m2, 0, 0, 0x800);
            if (a2 >= 0) { g2++; syscall1(SYS_CLOSE, (uint64_t)a2); }
            int64_t a3 = syscall4(SYS_ACCEPT4, (uint64_t)m3, 0, 0, 0x800);
            if (a3 >= 0) { g3++; syscall1(SYS_CLOSE, (uint64_t)a3); }
            sleep_ms(5);
        }
        { char d[48] = "hello267: migrated to m2 NN, to m3 NN\n"; d[25] = (char)('0' + g2 / 10); d[26] = (char)('0' + g2 % 10); d[35] = (char)('0' + g3 / 10); d[36] = (char)('0' + g3 % 10); print(d); }
        check(g2 + g3 == 12, "all 12 connections queued on the closed listener are accepted by a survivor");
        check(g2 > 0 && g3 > 0, "and they are spread over both survivors, not all given to one");
        for (int k = 0; k < 12; k++) syscall1(SYS_CLOSE, (uint64_t)mc[k]);
        syscall1(SYS_CLOSE, (uint64_t)m2); syscall1(SYS_CLOSE, (uint64_t)m3);
    }

    /* When the only sibling's queue is already full, Linux still hands it the closing listener's children (the migration path,
     * inet_csk_reqsk_queue_add, does not check the backlog), so none is reset. This kernel's listen queue is a fixed 32-entry ring: the
     * sibling first takes 32 connections, then the closing listener takes 8 more, then it closes. 80 TCBs plus 2 listeners: the table
     * needs more than 64 slots. The 40 client ends live in a child process (this keeps each process well under its descriptor limit). */
    {
        int64_t f1 = sock4(), f2 = sock4();
        reuseport(f1); reuseport(f2);
        check(bind4(f1, 18412) == 0 && bind4(f2, 18412) == 0, "two sockets share a port (full-queue case)");
        uint8_t fa[16];
        mk_addr(fa, 18412);
        check(syscall2(SYS_LISTEN, (uint64_t)f2, 32) == 0, "the sibling listens first");
        int64_t fk = syscall1(SYS_FORK, 0);
        if (fk == 0) {
            syscall1(SYS_CLOSE, (uint64_t)f1);   /* the child must not hold the listeners: closing them in the parent has to stop them */
            syscall1(SYS_CLOSE, (uint64_t)f2);
            int64_t fc[40];
            for (int k = 0; k < 32; k++) { fc[k] = sock4(); syscall3(SYS_CONNECT, (uint64_t)fc[k], (uint64_t)fa, 16); pump(10); }
            /* the parent now starts the second listener; it can only take the next connections if the sibling's ring is full */
            int64_t sig = syscall3(9 /* open */, (uint64_t)"/tmp/h267q", 0x241, 0644);
            if (sig >= 0) syscall1(SYS_CLOSE, (uint64_t)sig);
            pump(300);
            /* non-blocking: a SYN the hash gives to the full sibling is dropped and retried later, and must not stall the others */
            for (int k = 32; k < 40; k++) {
                fc[k] = sock4();
                int fl = (int)syscall3(142, (uint64_t)fc[k], 3, 0);
                syscall3(142, (uint64_t)fc[k], 4, (uint64_t)(fl | 0x800));
                syscall3(SYS_CONNECT, (uint64_t)fc[k], (uint64_t)fa, 16);
                pump(10);
            }
            pump(6000);   /* keep every client open until the parent has accepted */
            for (int k = 0; k < 40; k++) syscall1(SYS_CLOSE, (uint64_t)fc[k]);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        for (int i = 0; i < 400; i++) {
            int64_t t = syscall3(9, (uint64_t)"/tmp/h267q", 0, 0);
            if (t >= 0) { syscall1(SYS_CLOSE, (uint64_t)t); break; }
            pump(10);
        }
        check(syscall2(SYS_LISTEN, (uint64_t)f1, 32) == 0, "then the closing one");
        pump(600);
        syscall1(SYS_CLOSE, (uint64_t)f1);
        pump(50);
        int got = 0;
        for (int round = 0; round < 1500 && got < 40; round++) {   /* up to ~7.5 s: dropped SYNs come back after their 2 s retransmit */
            syscall1(SYS_NETPOLL, 0);
            int64_t a = syscall4(SYS_ACCEPT4, (uint64_t)f2, 0, 0, 0x800);
            if (a >= 0) { got++; syscall1(SYS_CLOSE, (uint64_t)a); } else sleep_ms(5);
        }
        { char d[48] = "hello267: full-queue case accepted NN of 40\n"; d[35] = (char)('0' + got / 10); d[36] = (char)('0' + got % 10); print(d); }
        check(got == 40, "with the sibling's queue full, every connection of the closing listener is still accepted, none reset");
        int fst = 0;
        syscall3(SYS_WAITPID, (uint64_t)fk, (uint64_t)&fst, 0);
        syscall1(SYS_CLOSE, (uint64_t)f2);
        syscall1(111, (uint64_t)"/tmp/h267q");
        pump(100);
    }

    print(failures == 0 ? "hello267: PASS\n" : "hello267: FAIL\n");
    print("hello267 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
