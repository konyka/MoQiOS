/// hello51: userspace driver framework v1 (L1) end-to-end proof.
///
/// Drives the QEMU e1000 from userspace using only the L1 syscalls:
///   1. Read /dev/pci and find the Intel NIC (vendor 0x8086, class 02).
///   2. dev_map_mmio its BAR0; read STATUS (0x0008, must be non-zero) and
///      RAL/RAH (0x5400/0x5404) — the kernel e1000 driver programs RAL/RAH
///      with the MAC it prints at boot, so the MAC read back through the
///      user mapping must equal 52:54:00:12:34:56.
///   3. dev_irq_register: a kernel-owned GSI (the e1000's own IRQ line, or
///      the keyboard line 1) must fail with -EBUSY; a free GSI (10) must
///      succeed; dev_irq_wait with a 50ms timeout must return -ETIMEDOUT
///      (-110), not hang; dev_irq_unregister must succeed and a second
///      unregister must fail with -EINVAL.
///   4. dev_dma_alloc a 4 KiB buffer, write/read-verify it through the
///      returned user VA, dev_dma_free it.
///   5. munmap the BAR0 mapping (exercises the no_free unmap path).
///
/// Prints "hello51: PASS" on success, "hello51: FAIL <tag>" + exit(1)
/// otherwise, and always ends with "hello51 done" on the success path.

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
#define SYS_OPEN        9
#define SYS_READ        10
#define SYS_CLOSE       11
#define SYS_MUNMAP      12

#define SYS_DEV_MAP_MMIO        477
#define SYS_DEV_IRQ_REGISTER    478
#define SYS_DEV_IRQ_WAIT        479
#define SYS_DEV_IRQ_UNREGISTER  480
#define SYS_DEV_DMA_ALLOC       481
#define SYS_DEV_DMA_FREE        482

#define O_RDONLY 0

#define EPERM     1
#define EACCES    13
#define EBUSY     16
#define EINVAL    22
#define ETIMEDOUT 110

/* e1000 register offsets (must match kernel/drivers/e1000.zig). */
#define E1000_STATUS 0x0008
#define E1000_RAL    0x5400
#define E1000_RAH    0x5404

/* QEMU user-net default MAC (printed by the kernel as "[e1000] MAC:"). */
static const uint8_t EXPECT_MAC[6] = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

/* A legacy IRQ line no QEMU device in this configuration raises: the kernel
   owns 1 (keyboard) and the NIC line (11); 10 stays quiet. */
#define FREE_GSI 10

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void print_hex(uint64_t v, int digits) {
    char buf[16];
    for (int i = digits - 1; i >= 0; i--) {
        uint8_t nib = (uint8_t)(v & 0xF);
        buf[i] = (char)(nib < 10 ? '0' + nib : 'a' + (nib - 10));
        v >>= 4;
    }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, (uint64_t)digits);
}

static void fail(const char *tag) {
    print("hello51: FAIL ");
    print(tag);
    print("\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

/* Parse 8 hex digits at p (the BAR fields emitted by /dev/pci). */
static uint64_t parse_hex8(const char *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        char c = p[i];
        uint8_t nib;
        if (c >= '0' && c <= '9') nib = (uint8_t)(c - '0');
        else if (c >= 'a' && c <= 'f') nib = (uint8_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') nib = (uint8_t)(c - 'A' + 10);
        else return 0;
        v = (v << 4) | nib;
    }
    return v;
}

static uint64_t parse_dec(const char *p, int max_digits) {
    uint64_t v = 0;
    for (int i = 0; i < max_digits && p[i] >= '0' && p[i] <= '9'; i++)
        v = v * 10 + (uint64_t)(p[i] - '0');
    return v;
}

static char pci_buf[8192];

void _start(void) {
    /* ── 1. /dev/pci snapshot ──────────────────────────────────────── */
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/pci", O_RDONLY, 0);
    if (fd < 0) fail("open /dev/pci");

    uint64_t total = 0;
    for (;;) {
        int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)(pci_buf + total),
                             (uint64_t)(sizeof(pci_buf) - total - 1));
        if (n < 0) fail("read /dev/pci");
        if (n == 0) break;
        total += (uint64_t)n;
        if (total >= sizeof(pci_buf) - 1) fail("pci listing too long");
    }
    syscall1(SYS_CLOSE, (uint64_t)fd);
    pci_buf[total] = 0;
    print("--- /dev/pci ---\n");
    print(pci_buf);
    print("----------------\n");

    /* Find the e1000: a line whose vendor is 8086 and class is 02.
       Line format: "00:03.0 8086:100e class=02:00 irq=11 bar0=febc0000+00020000 ..." */
    uint64_t bar0 = 0, bar0_size = 0, nic_irq = 0;
    const char *p = pci_buf;
    while (*p && bar0 == 0) {
        const char *nl = p;
        while (*nl && *nl != '\n') nl++;
        uint64_t len = (uint64_t)(nl - p);
        /* vendor at offset 8, class digits at offset 24 ("... class=02:00") */
        if (len > 27 && p[8] == '8' && p[9] == '0' && p[10] == '8' && p[11] == '6' &&
            p[24] == '0' && p[25] == '2') {
            const char *q = p;
            while (q < nl) {
                if (q + 11 < nl && q[0] == ' ' && q[1] == 'i' && q[2] == 'r' && q[3] == 'q' && q[4] == '=') {
                    nic_irq = parse_dec(q + 5, 3);
                }
                if (q + 15 < nl && q[0] == ' ' && q[1] == 'b' && q[2] == 'a' && q[3] == 'r' &&
                    q[4] == '0' && q[5] == '=') {
                    bar0 = parse_hex8(q + 6);
                    if (q[14] == '+') bar0_size = parse_hex8(q + 15);
                }
                q++;
            }
        }
        p = *nl ? nl + 1 : nl;
    }
    if (bar0 == 0 || bar0_size == 0) fail("e1000 not found in /dev/pci");

    print("hello51: e1000 bar0=0x");
    print_hex(bar0, 8);
    print(" size=0x");
    print_hex(bar0_size, 8);
    print(" irq=");
    print_hex(nic_irq, 2);
    print("\n");

    /* ── 2. dev_map_mmio the BAR ───────────────────────────────────── */
    uint64_t map_size = bar0_size < (16 * 1024 * 1024) ? bar0_size : (16 * 1024 * 1024);
    /* Mapping a RAM range must be refused. */
    if (syscall2(SYS_DEV_MAP_MMIO, 0x100000, 4096) != -EACCES)
        fail("map_mmio accepted RAM");

    int64_t mmio = syscall2(SYS_DEV_MAP_MMIO, bar0, map_size);
    if (mmio < 0) fail("dev_map_mmio bar0");
    volatile uint32_t *regs = (volatile uint32_t *)(uint64_t)mmio;

    uint32_t status = regs[E1000_STATUS / 4];
    if (status == 0) fail("e1000 STATUS read as 0");
    print("hello51: e1000 STATUS=0x");
    print_hex(status, 8);
    print("\n");

    uint32_t ral = regs[E1000_RAL / 4];
    uint32_t rah = regs[E1000_RAH / 4];
    uint8_t mac[6];
    mac[0] = (uint8_t)ral;
    mac[1] = (uint8_t)(ral >> 8);
    mac[2] = (uint8_t)(ral >> 16);
    mac[3] = (uint8_t)(ral >> 24);
    mac[4] = (uint8_t)rah;
    mac[5] = (uint8_t)(rah >> 8);
    print("hello51: e1000 MAC ");
    for (int i = 0; i < 6; i++) {
        if (i) print(":");
        print_hex(mac[i], 2);
    }
    print("\n");
    for (int i = 0; i < 6; i++)
        if (mac[i] != EXPECT_MAC[i]) fail("MAC mismatch");

    /* ── 3. IRQ register/wait/unregister semantics ─────────────────── */
    /* A kernel-owned line must be refused: the NIC's own IRQ when the
       kernel driver claimed one, else the keyboard line. */
    uint64_t owned_gsi = nic_irq != 0 ? nic_irq : 1;
    if (syscall1(SYS_DEV_IRQ_REGISTER, owned_gsi) != -EBUSY)
        fail("register kernel-owned GSI not EBUSY");

    /* Pick a GSI that is really free: keyboard(1)/cascade(2) plus every
       irq= line in the pci listing are taken — scan for them. */
    uint32_t used = 0x6; /* bits 1,2 */
    {
        const char *q = pci_buf;
        while (*q) {
            if (q[0] == 'i' && q[1] == 'r' && q[2] == 'q' && q[3] == '=') {
                uint64_t v = parse_dec(q + 4, 3);
                if (v < 16) used |= (uint32_t)1 << v;
            }
            q++;
        }
    }
    int free_gsi = -1;
    for (int g = 3; g < 16; g++) {
        if (!(used & ((uint32_t)1 << g))) { free_gsi = g; break; }
    }
    if (free_gsi < 0) fail("no free GSI found");

    if (syscall1(SYS_DEV_IRQ_REGISTER, (uint64_t)free_gsi) != 0)
        fail("register free GSI");

    /* No device raises this GSI: a 50ms wait must time out, not hang. */
    int64_t w = syscall2(SYS_DEV_IRQ_WAIT, (uint64_t)free_gsi, 50);
    if (w != -ETIMEDOUT) fail("irq_wait did not time out");

    /* Non-owner/unregistered semantics. */
    if (syscall1(SYS_DEV_IRQ_UNREGISTER, (uint64_t)free_gsi) != 0)
        fail("unregister");
    if (syscall1(SYS_DEV_IRQ_UNREGISTER, (uint64_t)free_gsi) != -EINVAL)
        fail("double unregister not EINVAL");
    if (syscall2(SYS_DEV_IRQ_WAIT, (uint64_t)free_gsi, 1) != -EINVAL)
        fail("wait on unregistered GSI not EINVAL");

    /* ── 4. DMA alloc/free ─────────────────────────────────────────── */
    uint64_t dma_info[2] = { 0, 0 }; /* { user_va, phys } */
    if (syscall2(SYS_DEV_DMA_ALLOC, 4096, (uint64_t)dma_info) != 0)
        fail("dev_dma_alloc");
    if (dma_info[0] == 0 || dma_info[1] == 0 || (dma_info[1] & 0xFFF) != 0)
        fail("dev_dma_alloc result");
    volatile uint64_t *dbuf = (volatile uint64_t *)dma_info[0];
    for (int i = 0; i < 512; i++) dbuf[i] = 0xA5A50000ULL + (uint64_t)i;
    for (int i = 0; i < 512; i++)
        if (dbuf[i] != 0xA5A50000ULL + (uint64_t)i) fail("dma buffer verify");
    print("hello51: dma user=0x");
    print_hex(dma_info[0], 8);
    print(" phys=0x");
    print_hex(dma_info[1], 8);
    print("\n");
    if (syscall1(SYS_DEV_DMA_FREE, dma_info[0]) != 0)
        fail("dev_dma_free");
    if (syscall1(SYS_DEV_DMA_FREE, dma_info[0]) != -EINVAL)
        fail("double dma_free not EINVAL");

    /* ── 5. munmap the MMIO window (no_free unmap path) ────────────── */
    if (syscall2(SYS_MUNMAP, (uint64_t)mmio, map_size) != 0)
        fail("munmap mmio");

    print("hello51: PASS\n");
    print("hello51 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
