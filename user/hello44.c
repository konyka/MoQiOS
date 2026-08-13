/// hello44: SCHED_FIFO / SCHED_RR realtime scheduling classes (F3).
///
/// (a) sched_get_priority_max/min report 99/1 for FIFO and RR, 0/0 for OTHER.
/// (b) a SCHED_FIFO child preempts an OTHER busy loop: while the FIFO child
///     runs, the parent's progress counter must not advance (no quantum).
/// (c) two SCHED_RR children at equal priority share the CPU: each observes
///     the other's progress counter advance before finishing.
/// (d) invalid policy/priority combinations are rejected with EINVAL.
///
/// Concurrency checks pin the whole test to CPU 0 (sched_setaffinity, mask
/// inherited across fork) so they are deterministic on SMP>1 as well.

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

static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE        1
#define SYS_EXIT         2
#define SYS_WAITPID      6
#define SYS_OPEN         9
#define SYS_READ        10
#define SYS_CLOSE       11
#define SYS_PREAD       17
#define SYS_PWRITE      18
#define SYS_FORK        57
#define SYS_GETPRIORITY 232
#define SYS_SETPRIORITY 233
#define SYS_SETAFFINITY 273
#define SYS_SCHED_GETATTR      309
#define SYS_SCHED_SETSCHEDULER 473
#define SYS_SCHED_GETSCHEDULER 474
#define SYS_SCHED_GET_PRIO_MAX 475
#define SYS_SCHED_GET_PRIO_MIN 476

#define SCHED_OTHER 0
#define SCHED_FIFO  1
#define SCHED_RR    2

#define O_WRONLY_CREAT 0x41

struct sched_param {
    int32_t sched_priority;
};

/* sched_attr layout expected by the kernel (u32 size; u32 policy; u64 flags;
   i32 nice; u32 priority; u64 runtime/deadline/period). */
struct sched_attr {
    uint32_t size;
    uint32_t sched_policy;
    uint64_t sched_flags;
    int32_t  sched_nice;
    uint32_t sched_priority;
    uint64_t sched_runtime;
    uint64_t sched_deadline;
    uint64_t sched_period;
};

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello44: FAIL (");
    print(why);
    print(")\nhello44 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

/* CPU burn that the compiler cannot optimise away. */
static void busy(uint64_t iters) {
    volatile uint64_t acc = 0;
    for (uint64_t i = 0; i < iters; i++) acc += i;
}

static int setscheduler(int32_t pid, int32_t policy, int32_t prio) {
    struct sched_param p = { .sched_priority = prio };
    return (int)syscall3(SYS_SCHED_SETSCHEDULER, (uint64_t)pid, (uint64_t)policy, (uint64_t)&p);
}

/* ── (b) FIFO child: verify the OTHER parent makes no progress while we run ─ */
static void fifo_child(void) {
    if (setscheduler(0, SCHED_FIFO, 50) != 0) syscall1(SYS_EXIT, 10);
    if (syscall1(SYS_SCHED_GETSCHEDULER, 0) != SCHED_FIFO) syscall1(SYS_EXIT, 11);

    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/rt44fifo", 0, 0);
    if (fd < 0) syscall1(SYS_EXIT, 12);

    uint32_t c0 = 0, c1 = 0;
    if (syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)&c0, 4, 0) != 4) syscall1(SYS_EXIT, 13);
    busy(200000000); /* several OTHER timeslices worth of CPU */
    if (syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)&c1, 4, 0) != 4) syscall1(SYS_EXIT, 14);
    syscall1(SYS_CLOSE, (uint64_t)fd);

    /* A preempted FIFO child would let the parent advance thousands of
       iterations; an un preempted one sees at most a boundary wobble. */
    if (c1 - c0 > 2) {
        /* DIAG: report the observed delta before failing. */
        char buf[64];
        int n = 0;
        const char *pfx = "hello44: diag c0=";
        while (pfx[n]) { buf[n] = pfx[n]; n++; }
        uint32_t v = c0; char tmp[16]; int t = 0;
        if (!v) tmp[t++] = '0';
        while (v) { tmp[t++] = '0' + (v % 10); v /= 10; }
        while (t) buf[n++] = tmp[--t];
        const char *mid = " c1=";
        for (int k = 0; mid[k]; k++) buf[n++] = mid[k];
        v = c1; t = 0;
        if (!v) tmp[t++] = '0';
        while (v) { tmp[t++] = '0' + (v % 10); v /= 10; }
        while (t) buf[n++] = tmp[--t];
        buf[n++] = '\n';
        syscall3(SYS_WRITE, 1, (uint64_t)buf, (uint64_t)n);
        syscall1(SYS_EXIT, 15);
    }
    print("hello44: fifo child held cpu\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

/* ── (c) RR child: run `rounds`, publishing progress; PASS if the peer's
        counter advanced before we finished ─ */
static void rr_child(int64_t my_off, int64_t peer_off) {
    if (setscheduler(0, SCHED_RR, 30) != 0) syscall1(SYS_EXIT, 20);
    if (syscall1(SYS_SCHED_GETSCHEDULER, 0) != SCHED_RR) syscall1(SYS_EXIT, 21);

    int64_t fdr = syscall3(SYS_OPEN, (uint64_t)"/tmp/rt44rr", 0, 0);
    int64_t fdw = syscall3(SYS_OPEN, (uint64_t)"/tmp/rt44rr", O_WRONLY_CREAT, 0666);
    if (fdr < 0 || fdw < 0) syscall1(SYS_EXIT, 22);

    uint32_t peer_seen = 0;
    for (uint32_t round = 1; round <= 40; round++) {
        busy(5000000);
        if (syscall4(SYS_PWRITE, (uint64_t)fdw, (uint64_t)&round, 4, (uint64_t)my_off) != 4)
            syscall1(SYS_EXIT, 23);
        uint32_t peer = 0;
        if (syscall4(SYS_PREAD, (uint64_t)fdr, (uint64_t)&peer, 4, (uint64_t)peer_off) != 4)
            syscall1(SYS_EXIT, 24);
        if (peer > peer_seen) peer_seen = peer;
    }
    syscall1(SYS_CLOSE, (uint64_t)fdr);
    syscall1(SYS_CLOSE, (uint64_t)fdw);

    if (peer_seen == 0) syscall1(SYS_EXIT, 25); /* peer never ran: no RR sharing */
    print("hello44: rr child observed peer progress\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

void _start(void) {
    /* Pin to CPU 0 — makes the concurrency checks SMP-safe (inherited by
       all children forked below). */
    uint64_t mask = 1;
    if (syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&mask) != 0)
        fail("sched_setaffinity cpu0");

    /* ── (a) sched_get_priority_max/min ─────────────────────────────── */
    if (syscall1(SYS_SCHED_GET_PRIO_MAX, SCHED_FIFO) != 99) fail("max FIFO != 99");
    if (syscall1(SYS_SCHED_GET_PRIO_MIN, SCHED_FIFO) != 1) fail("min FIFO != 1");
    if (syscall1(SYS_SCHED_GET_PRIO_MAX, SCHED_RR) != 99) fail("max RR != 99");
    if (syscall1(SYS_SCHED_GET_PRIO_MIN, SCHED_RR) != 1) fail("min RR != 1");
    if (syscall1(SYS_SCHED_GET_PRIO_MAX, SCHED_OTHER) != 0) fail("max OTHER != 0");
    if (syscall1(SYS_SCHED_GET_PRIO_MIN, SCHED_OTHER) != 0) fail("min OTHER != 0");
    if (syscall1(SYS_SCHED_GET_PRIO_MAX, 77) != -22) fail("max invalid policy");

    /* ── (d) invalid setscheduler/getscheduler arguments ────────────── */
    if (setscheduler(0, 9, 50) != -22) fail("invalid policy accepted");
    if (setscheduler(0, SCHED_FIFO, 0) != -22) fail("FIFO prio 0 accepted");
    if (setscheduler(0, SCHED_FIFO, 100) != -22) fail("FIFO prio 100 accepted");
    if (setscheduler(0, SCHED_RR, -5) != -22) fail("RR negative prio accepted");
    if (setscheduler(0, SCHED_OTHER, 5) != -22) fail("OTHER prio 5 accepted");
    if (setscheduler(99999, SCHED_FIFO, 50) != -3) fail("setscheduler bad pid");
    if (syscall1(SYS_SCHED_GETSCHEDULER, 99999) != -3) fail("getscheduler bad pid");
    if (syscall3(SYS_SCHED_SETSCHEDULER, 0, SCHED_FIFO, 0) != -14) fail("NULL param");

    /* ── set/get round-trip + nice orthogonality ────────────────────── */
    if (setscheduler(0, SCHED_RR, 50) != 0) fail("setscheduler RR 50");
    if (syscall1(SYS_SCHED_GETSCHEDULER, 0) != SCHED_RR) fail("getscheduler != RR");
    /* setpriority must not affect RT tasks (Linux: nice is orthogonal). */
    if (syscall3(SYS_SETPRIORITY, 0, 0, 10) != 0) fail("setpriority on RT");
    {
        struct sched_attr attr;
        if (syscall4(SYS_SCHED_GETATTR, 0, (uint64_t)&attr, sizeof(attr), 0) != 0)
            fail("sched_getattr");
        if (attr.sched_policy != SCHED_RR || attr.sched_priority != 50)
            fail("setpriority clobbered RT priority");
    }
    if (setscheduler(0, SCHED_OTHER, 0) != 0) fail("setscheduler back to OTHER");
    if (syscall1(SYS_SCHED_GETSCHEDULER, 0) != SCHED_OTHER) fail("getscheduler != OTHER");

    /* ── (b) FIFO child preempts OTHER busy loop ────────────────────── */
    {
        int64_t fdw = syscall3(SYS_OPEN, (uint64_t)"/tmp/rt44fifo", O_WRONLY_CREAT, 0666);
        if (fdw < 0) fail("open rt44fifo");
        uint32_t zero = 0;
        if (syscall4(SYS_PWRITE, (uint64_t)fdw, (uint64_t)&zero, 4, 0) != 4)
            fail("init rt44fifo");

        int64_t pid = syscall1(SYS_FORK, 0);
        if (pid < 0) fail("fork fifo child");
        if (pid == 0) fifo_child();

        /* OTHER parent: publish progress while competing with the FIFO child. */
        for (uint32_t cnt = 1; cnt <= 600; cnt++) {
            busy(3000000);
            if (syscall4(SYS_PWRITE, (uint64_t)fdw, (uint64_t)&cnt, 4, 0) != 4)
                fail("parent progress write");
        }
        syscall1(SYS_CLOSE, (uint64_t)fdw);

        int32_t status = -1;
        if (syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0) != pid)
            fail("waitpid fifo child");
        if (status != 0) fail("fifo child preempted");
    }

    /* ── (c) two RR children share the CPU ──────────────────────────── */
    {
        int64_t fdw = syscall3(SYS_OPEN, (uint64_t)"/tmp/rt44rr", O_WRONLY_CREAT, 0666);
        if (fdw < 0) fail("open rt44rr");
        uint32_t zeros[2] = { 0, 0 };
        if (syscall4(SYS_PWRITE, (uint64_t)fdw, (uint64_t)zeros, 8, 0) != 8)
            fail("init rt44rr");
        syscall1(SYS_CLOSE, (uint64_t)fdw);

        int64_t pida = syscall1(SYS_FORK, 0);
        if (pida < 0) fail("fork rr child A");
        if (pida == 0) rr_child(0, 4);

        int64_t pidb = syscall1(SYS_FORK, 0);
        if (pidb < 0) fail("fork rr child B");
        if (pidb == 0) rr_child(4, 0);

        int32_t sa = -1, sb = -1;
        if (syscall3(SYS_WAITPID, (uint64_t)pida, (uint64_t)&sa, 0) != pida)
            fail("waitpid rr child A");
        if (syscall3(SYS_WAITPID, (uint64_t)pidb, (uint64_t)&sb, 0) != pidb)
            fail("waitpid rr child B");
        if (sa != 0) fail("rr child A starved peer");
        if (sb != 0) fail("rr child B starved peer");
    }

    print("hello44: PASS\nhello44 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
