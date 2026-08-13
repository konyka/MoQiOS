/// hello50: SMP concurrent-workload stress (J1).
///
/// Forks 4 workers; worker i tries to pin itself to CPU i via
/// sched_setaffinity(mask = 1<<i). A CPU index >= the online count is
/// rejected with EINVAL (-22) by the kernel, in which case the worker
/// proceeds unpinned — on SMP=1 all four workers simply timeshare CPU 0.
///
/// Each worker runs a fixed budget of 300 iterations (deterministic under
/// TCG, not time-based). Every iteration exercises four subsystems:
///   tmpfs: create/trunc /tmp/s50_<i>.dat, write a 4 KiB pattern, read it
///          back and verify, then unlink (tolerated if the unlink syscall
///          does not route to tmpfs — the file is re-truncated next round).
///   pipe:  pipe() + write 1 KiB pattern + read back + verify + close both.
///   UDP:   socket/bind 127.0.0.1:25000+i, sendto self, recvfrom (pumped by
///          netpoll — sockets are non-blocking), verify payload + source.
///   mmap:  64 KiB anonymous, write pattern, verify, munmap.
///
/// Any wrong data or unexpected negative return makes the worker exit with
/// code 10+i after a one-line diagnostic. The parent waitpids all children
/// and reports the first non-zero status.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_WAITPID     6
#define SYS_MMAP        8
#define SYS_OPEN        9
#define SYS_READ        10
#define SYS_CLOSE       11
#define SYS_MUNMAP      12
#define SYS_PIPE        22
#define SYS_UNLINK      111
#define SYS_FORK        57
#define SYS_NETPOLL     104
#define SYS_SOCKET      117
#define SYS_BIND        118
#define SYS_SENDTO      121
#define SYS_RECVFROM    122
#define SYS_SETAFFINITY 273

#define O_RDONLY            0x0
#define O_RDWR_CREAT_TRUNC  0x242 /* O_RDWR | O_CREAT | O_TRUNC */
#define PROT_READ           0x1
#define PROT_WRITE          0x2
#define MAP_PRIVATE         0x02
#define MAP_ANONYMOUS       0x20
#define AF_INET             2
#define SOCK_DGRAM          2

#define NWORKERS  4
#define ITERS     300
#define FILE_LEN  4096
#define PIPE_LEN  1024
#define UDP_LEN   32
#define MAP_LEN   (64 * 1024)
#define UDP_BASE_PORT 25000

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void print_dec(int64_t v) {
    char buf[24];
    int pos = 0;
    if (v < 0) { print("-"); v = -v; }
    if (v == 0) { print("0"); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char t = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = t; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

/* Position-dependent pattern word: catches stale data carried over from a
   previous iteration (same tmpfs file re-truncated, reused pipe slot). */
static uint64_t pat(int worker, uint32_t iter, uint64_t idx) {
    return ((uint64_t)(uint32_t)(worker + 1) << 56) | ((uint64_t)iter << 32) |
           (idx * 0x9E3779B97F4A7C15ULL);
}

static void fill_pat(uint64_t *buf, uint64_t words, int worker, uint32_t iter) {
    for (uint64_t i = 0; i < words; i++) buf[i] = pat(worker, iter, i);
}

static int verify_pat(const volatile uint64_t *buf, uint64_t words, int worker, uint32_t iter) {
    for (uint64_t i = 0; i < words; i++)
        if (buf[i] != pat(worker, iter, i)) return 0;
    return 1;
}

/* sockaddr_in, 16 bytes: family(2) port(2, BE) addr(4) zero(8) — 127.0.0.1. */
static void mk_addr(uint8_t *a, uint16_t port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 0x00; a[1] = AF_INET;
    a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)(port & 0xff);
    a[4] = 127; a[5] = 0; a[6] = 0; a[7] = 1;
}

/* Bounded non-blocking recv: pump the lo queue between attempts. */
static int64_t recv_pumped(int64_t fd, uint8_t *buf, uint64_t len, uint8_t *src, uint64_t *srclen) {
    for (int attempt = 0; attempt < 1000; attempt++) {
        syscall1(SYS_NETPOLL, 0);
        int64_t n = syscall6(SYS_RECVFROM, (uint64_t)fd, (uint64_t)buf, len, 0,
                             (uint64_t)src, (uint64_t)srclen);
        if (n != 0) return n;
    }
    return 0;
}

static void worker_fail(int worker, const char *tag) {
    char digit = (char)('0' + worker);
    print("hello50: worker ");
    syscall3(SYS_WRITE, 1, (uint64_t)&digit, 1);
    print(" fail ");
    print(tag);
    print("\n");
    syscall1(SYS_EXIT, (uint64_t)(10 + worker));
    for (;;) {}
}

static uint64_t fbuf[FILE_LEN / 8], frd[FILE_LEN / 8];
static uint64_t pbuf[PIPE_LEN / 8], prd[PIPE_LEN / 8];
static uint64_t upay[UDP_LEN / 8], urcv[UDP_LEN / 8];

static void worker(int w) {
    /* Pin to CPU w; EINVAL means that CPU is not online (e.g. SMP=1) —
       proceed unpinned and timeshare instead of failing. */
    uint64_t mask = (uint64_t)1 << w;
    int64_t aff = syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&mask);
    if (aff != 0 && aff != -22) worker_fail(w, "setaffinity");

    char path[16] = "/tmp/s50_0.dat";
    path[9] = (char)('0' + w);
    const uint16_t port = (uint16_t)(UDP_BASE_PORT + w);
    int unlink_noted = 0;

    for (uint32_t iter = 0; iter < ITERS; iter++) {
        /* ── tmpfs ─────────────────────────────────────────────────── */
        fill_pat(fbuf, FILE_LEN / 8, w, iter);
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT_TRUNC, 0666);
        if (fd < 0) worker_fail(w, "tmpfs open-w");
        if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)fbuf, FILE_LEN) != FILE_LEN)
            worker_fail(w, "tmpfs write");
        if (syscall1(SYS_CLOSE, (uint64_t)fd) != 0) worker_fail(w, "tmpfs close-w");

        fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDONLY, 0);
        if (fd < 0) worker_fail(w, "tmpfs open-r");
        if (syscall3(SYS_READ, (uint64_t)fd, (uint64_t)frd, FILE_LEN) != FILE_LEN)
            worker_fail(w, "tmpfs read");
        if (syscall1(SYS_CLOSE, (uint64_t)fd) != 0) worker_fail(w, "tmpfs close-r");
        if (!verify_pat(frd, FILE_LEN / 8, w, iter)) worker_fail(w, "tmpfs verify");

        /* Best-effort cleanup: unlink is routed to tmpfs by syscall #111.
           Tolerate a failure once (diag line) so the file is simply
           re-truncated on the next iteration instead of leaking slots. */
        if (syscall1(SYS_UNLINK, (uint64_t)path) < 0 && !unlink_noted) {
            unlink_noted = 1;
            print("hello50: note: tmpfs unlink failed, reusing file\n");
        }

        /* ── pipe ──────────────────────────────────────────────────── */
        int32_t fds[2] = { -1, -1 };
        if (syscall1(SYS_PIPE, (uint64_t)fds) < 0 || fds[0] < 0 || fds[1] < 0)
            worker_fail(w, "pipe create");
        fill_pat(pbuf, PIPE_LEN / 8, w, iter);
        if (syscall3(SYS_WRITE, (uint64_t)fds[1], (uint64_t)pbuf, PIPE_LEN) != PIPE_LEN)
            worker_fail(w, "pipe write");
        if (syscall3(SYS_READ, (uint64_t)fds[0], (uint64_t)prd, PIPE_LEN) != PIPE_LEN)
            worker_fail(w, "pipe read");
        if (syscall1(SYS_CLOSE, (uint64_t)fds[1]) != 0) worker_fail(w, "pipe close-w");
        if (syscall1(SYS_CLOSE, (uint64_t)fds[0]) != 0) worker_fail(w, "pipe close-r");
        if (!verify_pat(prd, PIPE_LEN / 8, w, iter)) worker_fail(w, "pipe verify");

        /* ── loopback UDP ──────────────────────────────────────────── */
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        if (u < 0) worker_fail(w, "udp socket");
        uint8_t addr[16];
        mk_addr(addr, port);
        if (syscall3(SYS_BIND, (uint64_t)u, (uint64_t)addr, 16) < 0)
            worker_fail(w, "udp bind");
        fill_pat(upay, UDP_LEN / 8, w, iter);
        if (syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)upay, UDP_LEN, 0,
                     (uint64_t)addr, 16) != UDP_LEN)
            worker_fail(w, "udp sendto");
        for (int i = 0; i < UDP_LEN / 8; i++) urcv[i] = 0;
        uint8_t src[16];
        for (int i = 0; i < 16; i++) src[i] = 0;
        uint64_t srclen = 16;
        if (recv_pumped(u, (uint8_t *)urcv, UDP_LEN, src, &srclen) != UDP_LEN)
            worker_fail(w, "udp recvfrom");
        if (!verify_pat(urcv, UDP_LEN / 8, w, iter)) worker_fail(w, "udp verify");
        if (src[4] != 127 || src[5] != 0 || src[6] != 0 || src[7] != 1)
            worker_fail(w, "udp src addr");
        if (syscall1(SYS_CLOSE, (uint64_t)u) != 0) worker_fail(w, "udp close");

        /* ── anonymous mmap ────────────────────────────────────────── */
        int64_t base = syscall6(SYS_MMAP, 0, MAP_LEN, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (base <= 0) worker_fail(w, "mmap");
        volatile uint64_t *m = (volatile uint64_t *)base;
        for (uint64_t i = 0; i < MAP_LEN / 8; i++) m[i] = pat(w, iter, i);
        if (!verify_pat(m, MAP_LEN / 8, w, iter)) worker_fail(w, "mmap verify");
        if (syscall3(SYS_MUNMAP, (uint64_t)base, MAP_LEN, 0) != 0)
            worker_fail(w, "munmap");
    }

    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

void _start(void) {
    int64_t pids[NWORKERS];
    for (int i = 0; i < NWORKERS; i++) {
        int64_t pid = syscall1(SYS_FORK, 0);
        if (pid < 0) {
            print("hello50: FAIL (fork worker)\nhello50 done\n");
            syscall1(SYS_EXIT, 1);
            for (;;) {}
        }
        if (pid == 0) worker(i);
        pids[i] = pid;
    }

    int bad_worker = -1;
    int32_t bad_status = 0;
    for (int i = 0; i < NWORKERS; i++) {
        int32_t status = -1;
        if (syscall3(SYS_WAITPID, (uint64_t)pids[i], (uint64_t)&status, 0) != pids[i])
            status = -1;
        if (status != 0 && bad_worker < 0) {
            bad_worker = i;
            bad_status = status;
        }
    }

    if (bad_worker >= 0) {
        char digit = (char)('0' + bad_worker);
        print("hello50: FAIL (worker ");
        syscall3(SYS_WRITE, 1, (uint64_t)&digit, 1);
        print(" status ");
        print_dec(bad_status);
        print(")\nhello50 done\n");
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }

    print("hello50: PASS (4 workers)\n");
    print("hello50 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
