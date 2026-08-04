/// hello54: userspace-owned /dev node (devfs proxy) end-to-end proof.
///
///   1. Child registers /dev/echo54 via devfs_register (syscall 484) and
///      serves it over the returned ctrl fd: writes store the payload,
///      reads return the most recent write's bytes.
///   2. Parent writes a string, closes, reopens the node fresh, reads it
///      back and verifies — the full client→kernel→owner→client round trip.
///   3. A second client open is served the same way.
///   4. Parent kills the server child (owner death): an already-open
///      client fd reports -EIO, a new open of the name reports -ENOENT
///      (the node is tombstoned).
///
/// Prints "hello54: PASS" on success, "hello54: FAIL <tag>" + exit(1)
/// otherwise, and always ends with "hello54 done" on the success path.

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

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_WAITPID     6
#define SYS_OPEN        9
#define SYS_READ        10
#define SYS_CLOSE       11
#define SYS_FORK        57
#define SYS_KILL        62
#define SYS_NANOSLEEP   199
#define SYS_DEVFS_REGISTER 484

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2

#define SIGKILL 9

#define EIO    5
#define ENOENT 2

/* devfs proxy wire protocol (kernel/fs/devfs_proxy.zig, all LE):
 *   request:  u32 seq @0, u32 op @4 (1=read, 2=write), u64 offset @8,
 *             u32 len @16, u8 payload[len] @20 (write only)
 *   response: u32 seq @0, i32 ret @4, u8 data[ret] @8 (read, ret>0 only) */
#define OP_READ  1
#define OP_WRITE 2
#define REQ_HDR  20
#define RSP_HDR  8
#define MAX_PAYLOAD 4096

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *tag) {
    print("hello54: FAIL ");
    print(tag);
    print("\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static int mem_eq(const uint8_t *a, const char *b, uint64_t n) {
    for (uint64_t i = 0; i < n; i++) {
        if (a[i] != (uint8_t)b[i]) return 0;
    }
    return 1;
}

static uint64_t str_len(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    return n;
}

static void sleep_ms(uint64_t ms) {
    uint64_t req[2] = { (uint64_t)(ms / 1000), (uint64_t)((ms % 1000) * 1000 * 1000) };
    syscall2(SYS_NANOSLEEP, (uint64_t)req, 0);
}

/* ── server child ─────────────────────────────────────────────────── */

static uint8_t req_buf[REQ_HDR + MAX_PAYLOAD];
static uint8_t rsp_buf[RSP_HDR + MAX_PAYLOAD];
static uint8_t last_payload[MAX_PAYLOAD];
static uint32_t last_len;

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void serve(int64_t ctrl) {
    for (;;) {
        int64_t n = syscall3(SYS_READ, (uint64_t)ctrl, (uint64_t)req_buf, sizeof(req_buf));
        if (n < REQ_HDR) continue; /* -EINTR/-EIO or short: retry/die */
        uint32_t seq = rd32(req_buf + 0);
        uint32_t op = rd32(req_buf + 4);
        uint32_t len = rd32(req_buf + 16);

        wr32(rsp_buf + 0, seq);
        if (op == OP_WRITE) {
            if (len > MAX_PAYLOAD) len = MAX_PAYLOAD;
            for (uint32_t i = 0; i < len; i++) last_payload[i] = req_buf[REQ_HDR + i];
            last_len = len;
            wr32(rsp_buf + 4, len);
            syscall3(SYS_WRITE, (uint64_t)ctrl, (uint64_t)rsp_buf, RSP_HDR);
        } else if (op == OP_READ) {
            uint32_t give = last_len < len ? last_len : len;
            wr32(rsp_buf + 4, give);
            for (uint32_t i = 0; i < give; i++) rsp_buf[RSP_HDR + i] = last_payload[i];
            syscall3(SYS_WRITE, (uint64_t)ctrl, (uint64_t)rsp_buf, RSP_HDR + give);
        } else {
            wr32(rsp_buf + 4, (uint32_t)-22); /* -EINVAL */
            syscall3(SYS_WRITE, (uint64_t)ctrl, (uint64_t)rsp_buf, RSP_HDR);
        }
    }
}

/* ── parent ───────────────────────────────────────────────────────── */

static int64_t open_node(void) {
    return syscall3(SYS_OPEN, (uint64_t)"/dev/echo54", O_RDWR, 0);
}

/* Write s to the node on a fresh fd, close, reopen, read it back and
 * verify the echo round trip. */
static void write_read_verify(const char *s, const char *tag) {
    uint64_t slen = str_len(s);

    int64_t fd = open_node();
    if (fd < 0) fail(tag);
    if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)s, slen) != (int64_t)slen)
        fail("client write");
    syscall1(SYS_CLOSE, (uint64_t)fd);

    int64_t fd2 = open_node();
    if (fd2 < 0) fail("reopen");
    static uint8_t back[128];
    for (int i = 0; i < (int)sizeof(back); i++) back[i] = 0;
    int64_t n = syscall3(SYS_READ, (uint64_t)fd2, (uint64_t)back, sizeof(back));
    if (n != (int64_t)slen) fail("read-back length");
    if (!mem_eq(back, s, slen)) fail("read-back content");
    syscall1(SYS_CLOSE, (uint64_t)fd2);
}

void _start(void) {
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid < 0) fail("fork");

    if (pid == 0) {
        /* Child: register and serve /dev/echo54. */
        int64_t ctrl = syscall2(SYS_DEVFS_REGISTER, (uint64_t)"echo54", 0);
        if (ctrl < 0) fail("devfs_register");
        serve(ctrl);
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }

    /* Parent: wait for the node to appear (child registers first). */
    int64_t fd = -1;
    for (int i = 0; i < 1000; i++) {
        fd = open_node();
        if (fd >= 0) break;
        sleep_ms(5);
    }
    if (fd < 0) fail("open /dev/echo54");
    syscall1(SYS_CLOSE, (uint64_t)fd);

    /* 1. Full round trip through the userspace owner. */
    write_read_verify("userspace echo via devfs proxy", "open first client");

    /* 2. A second client open is served too. */
    write_read_verify("second client also served", "second client");

    /* 3. Owner death: keep a client fd open across the kill. */
    int64_t stale = open_node();
    if (stale < 0) fail("open stale client");
    if (syscall2(SYS_KILL, (uint64_t)pid, SIGKILL) != 0) fail("kill server");
    int32_t status = 0;
    if (syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0) != pid)
        fail("waitpid server");

    /* The already-open fd fails with -EIO ... */
    uint8_t c;
    if (syscall3(SYS_READ, (uint64_t)stale, (uint64_t)&c, 1) != -EIO)
        fail("stale read not EIO");
    if (syscall3(SYS_WRITE, (uint64_t)stale, (uint64_t)"x", 1) != -EIO)
        fail("stale write not EIO");
    syscall1(SYS_CLOSE, (uint64_t)stale);

    /* ... and the tombstoned name no longer resolves. */
    if (open_node() != -ENOENT) fail("open after death not ENOENT");

    print("hello54: PASS\n");
    print("hello54 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
