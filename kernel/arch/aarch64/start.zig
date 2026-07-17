//! AArch64 kernel early bring-up — Milestone 9.
//!
//! Boot model: QEMU `virt` with `-cpu max -kernel kernel.elf`. QEMU loads the
//! ELF at 0x40000000 and enters `_start` in EL1. Non-Linux ELF images do not
//! get a DTB pointer in x0, so the run script also loads a dumped virt DTB at
//! `DTB_FALLBACK` via `-device loader`.
//!
//! M9-1: PL011 UART console
//! M9-2: VBAR_EL1 exception vectors + `brk` self-test
//! M9-3: FDT `/memory` → PMM → identity map + map/unmap + #PF test

const uart = @import("uart.zig");
const trap = @import("trap.zig");
const fdt = @import("fdt.zig");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");

extern const __kernel_end: u8;

// SK-15: bring-up creates several Tasks (FdTable ~57KiB memset each); keep headroom.
const BOOT_STACK_SIZE: usize = 256 * 1024;
/// Must match `qemu_run_aarch64.sh` loader address.
const DTB_FALLBACK: usize = 0x4a000000;
const FDT_MAGIC: u32 = 0xd00dfeed;

comptime {
    _ = @import("arch_impl.zig");
}

export var boot_stack: [BOOT_STACK_SIZE]u8 align(16) = undefined;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\adrp x1, boot_stack
        \\add  x1, x1, :lo12:boot_stack
        \\mov  x2, #0x40000
        \\add  x1, x1, x2
        \\bic  x1, x1, #0xf
        \\mov  sp, x1
        \\bl   kmain
        \\1:
        \\wfi
        \\b    1b
    );
}

fn putStr(s: []const u8) void {
    uart.writeString(s);
}

fn putHex(v: u64) void {
    const hex = "0123456789abcdef";
    putStr("0x");
    var i: u6 = 60;
    while (true) {
        uart.writeByte(hex[@intCast((v >> i) & 0xf)]);
        if (i == 0) break;
        i -= 4;
    }
}

fn putDec(v: u64) void {
    if (v == 0) {
        uart.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (n += 1) {
        buf[n] = @intCast('0' + (x % 10));
        x /= 10;
    }
    while (n > 0) {
        n -= 1;
        uart.writeByte(buf[n]);
    }
}

fn readBe32(addr: usize) u32 {
    const p: [*]const u8 = @ptrFromInt(addr);
    return (@as(u32, p[0]) << 24) |
        (@as(u32, p[1]) << 16) |
        (@as(u32, p[2]) << 8) |
        @as(u32, p[3]);
}

fn fdtLooksValid(addr: usize) bool {
    if (addr == 0) return false;
    return readBe32(addr) == FDT_MAGIC;
}

fn resolveDtb(x0: usize) usize {
    if (fdtLooksValid(x0)) return x0;
    if (fdtLooksValid(DTB_FALLBACK)) return DTB_FALLBACK;
    return 0;
}

export fn kmain(x0_dtb: usize) callconv(.c) noreturn {
    // Zig may emit FP/NEON for memcpy/memset; allow EL1 access.
    var cpacr: u64 = asm volatile ("mrs %[r], cpacr_el1"
        : [r] "=r" (-> u64),
    );
    cpacr |= @as(u64, 0b11) << 20; // FPEN = no trap
    asm volatile (
        \\msr cpacr_el1, %[v]
        \\isb
        :
        : [v] "r" (cpacr),
    );

    // QEMU/firmware may leave SCTLR.A set; clear strict alignment faults.
    var sctlr: u64 = asm volatile ("mrs %[r], sctlr_el1"
        : [r] "=r" (-> u64),
    );
    sctlr &= ~@as(u64, 1 << 1); // clear A
    asm volatile (
        \\msr sctlr_el1, %[v]
        \\isb
        :
        : [v] "r" (sctlr),
    );

    uart.init();
    trap.init();
    @import("../../shared/sk2.zig").announce();
    @import("../../shared/sk3.zig").announce();
    @import("../../shared/sk4.zig").announce();

    putStr("MoQiOS aarch64: M9 bring-up (PL011 + vectors + paging)\n");

    const dtb = resolveDtb(x0_dtb);
    var dtb_size: u32 = 0;
    putStr("  dtb=");
    putHex(dtb);
    if (dtb != 0) {
        putStr(" magic=");
        putHex(readBe32(dtb));
        dtb_size = readBe32(dtb + 4);
        putStr(" totalsize=");
        putDec(dtb_size);
        putStr(" (FDT OK)\n");
    } else {
        putStr(" (FDT MISSING)\n");
    }
    putStr("[aarch64] M9-1 complete\n");

    _ = trap.brkSelfTest();

    // ---- M9-3: FDT memory → PMM → identity map ----
    putStr("MoQiOS aarch64: M9-3 (PMM + paging)\n");
    var regions: [4]fdt.MemRegion = undefined;
    const nreg = fdt.findMemoryRegions(dtb, &regions);
    putStr("  memory regions=");
    putDec(nreg);
    putStr("\n");
    var ri: usize = 0;
    while (ri < nreg) : (ri += 1) {
        putStr("    [");
        putDec(ri);
        putStr("] base=");
        putHex(regions[ri].base);
        putStr(" size=");
        putHex(regions[ri].size);
        putStr("\n");
    }
    if (nreg == 0) {
        putStr("  M9-3 FAILED: no /memory in DTB\n");
        while (true) asm volatile ("wfi");
    }

    // SK-6: carve 4 MiB above the kernel for shared mm/pmm+slab.
    const sk6 = @import("../../shared/sk6.zig");
    const kernel_end = (@intFromPtr(&__kernel_end) + 4095) & ~@as(usize, 4095);
    const share_base = kernel_end;
    const share_len = sk6.SHARE_BYTES;
    const arch_free_start = share_base + share_len;

    pmm.init(regions[0..nreg], dtb, dtb_size, arch_free_start);
    putStr("  pmm free_pages=");
    putDec(pmm.freeCount());
    putStr("\n");
    if (pmm.freeCount() == 0) {
        putStr("  M9-3 FAILED: PMM empty\n");
        while (true) asm volatile ("wfi");
    }

    if (!paging.initIdentity(regions[0..nreg])) {
        putStr("  M9-3 FAILED: MMU enable\n");
        while (true) asm volatile ("wfi");
    }
    putStr("  MMU enabled (identity map)\n");

    // SK-6 after MMU + SCTLR.A clear: Zig Debug may emit `str q` for `?u64`.
    sk6.announce(@intCast(share_base), @intCast(share_len));
    @import("../../shared/sk7.zig").announce();
    @import("../../shared/sk8.zig").announce();
    @import("../../shared/sk9.zig").announce();
    @import("../../shared/sk10.zig").announce();
    @import("../../shared/sk11.zig").announce();
    @import("../../shared/sk12.zig").announce();
    @import("../../shared/sk13.zig").announce();
    @import("../../shared/sk14.zig").announce();
    @import("../../shared/sk15.zig").announce();
    @import("../../shared/sk17.zig").announce();
    @import("../../shared/sk18.zig").announce();
    @import("../../shared/sk19.zig").announce();
    @import("../../shared/sk20.zig").announce();
    @import("../../shared/sk21.zig").announce();
    @import("../../shared/sk22.zig").announce();
    @import("../../shared/sk23.zig").announce();
    @import("../../shared/sk24.zig").announce();
    @import("../../shared/sk25.zig").announce();
    @import("../../shared/sk26.zig").announce();
    @import("../../shared/sk27.zig").announce();
    @import("../../shared/sk28.zig").announce();
    @import("../../shared/sk29.zig").announce();
    @import("../../shared/sk30.zig").announce();
    @import("../../shared/sk31.zig").announce();

    // Map a fresh page at a non-identity VA, write/read, then unmap + #PF.
    const test_va: usize = 0x80000000;
    const test_pa = pmm.allocPage();
    if (test_pa == 0) {
        putStr("  M9-3 FAILED: alloc for map test\n");
        while (true) asm volatile ("wfi");
    }
    if (!paging.mapPage(test_va, test_pa, paging.F_WRITE)) {
        putStr("  M9-3 FAILED: mapPage\n");
        while (true) asm volatile ("wfi");
    }
    const cell: *volatile u64 = @ptrFromInt(test_va);
    cell.* = 0x4d39504147452121; // "M9PAGE!!"
    if (cell.* != 0x4d39504147452121) {
        putStr("  M9-3 FAILED: mapped R/W mismatch\n");
        while (true) asm volatile ("wfi");
    }
    putStr("  map/unmap R/W: OK\n");

    paging.unmapPage(test_va);
    trap.armPageFaultTest();
    asm volatile (
        \\ldr x0, [%[va]]
        :
        : [va] "r" (test_va),
        : .{ .memory = true, .x0 = true });
    if (trap.pageFaultWasCaught()) {
        putStr("  page-fault trap: OK\n");
    } else {
        putStr("  page-fault trap: FAILED\n");
    }

    putStr("[aarch64] M9-3 complete\n");

    // ---- M9-4: generic timer (CNTV ISTATUS poll) ----
    const timer = @import("timer.zig");
    _ = timer.selfTest();

    // ---- M9-5: GICv3 + timer IRQ ----
    _ = timer.irqSelfTest();

    // ---- M9-6: EL0 + SVC ----
    const user = @import("user.zig");
    user.enter();

    while (true) asm volatile ("wfi");
}
