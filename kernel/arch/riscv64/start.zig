//! RISC-V 64 kernel early bring-up — Milestones 2–3 of the cross-ISA port.
//!
//! Boot model: QEMU `virt` with `-bios default -kernel kernel.elf`. OpenSBI
//! enters `_start` in S-mode with:
//!   a0 = hartid
//!   a1 = pointer to the flattened device tree (DTB)
//!
//! M2: soft-float, UART16550, stvec + ebreak self-test
//! M3: FDT `/memory` → PMM freelist → Sv39 identity map + map/unmap + #PF test

const uart = @import("uart.zig");
const trap = @import("trap.zig");
const fdt = @import("fdt.zig");
const pmm = @import("pmm.zig");
const sv39 = @import("sv39.zig");

extern const __kernel_end: u8;

// SK-15: bring-up creates several Tasks (FdTable ~57KiB memset each); keep headroom.
const BOOT_STACK_SIZE: usize = 256 * 1024;

comptime {
    _ = @import("arch_impl.zig");
}

export var boot_stack: [BOOT_STACK_SIZE]u8 align(16) = undefined;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\la sp, boot_stack
        \\li t0, 0x40000
        \\add sp, sp, t0
        \\andi sp, sp, -16
        \\call kmain
        \\1:
        \\wfi
        \\j 1b
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

fn sbiShutdown() void {
    asm volatile ("ecall"
        :
        : [eid] "{a7}" (@as(usize, 0x53525354)),
          [fid] "{a6}" (@as(usize, 0)),
          [a0] "{a0}" (@as(usize, 0)),
          [a1] "{a1}" (@as(usize, 0)),
        : .{ .memory = true });
    asm volatile ("ecall"
        :
        : [eid] "{a7}" (@as(usize, 0x08)),
          [a0] "{a0}" (@as(usize, 0)),
        : .{ .memory = true });
}

export fn kmain(hartid: usize, dtb: usize) callconv(.c) noreturn {
    uart.init();
    @import("../../shared/sk2.zig").announce();
    @import("../../shared/sk3.zig").announce();
    @import("../../shared/sk4.zig").announce();
    putStr("MoQiOS riscv64: M3 bring-up (PMM + Sv39)\n");

    putStr("  hartid=");
    putDec(hartid);
    putStr("\n");

    var dtb_size: u32 = 0;
    putStr("  dtb=");
    putHex(dtb);
    if (dtb != 0) {
        const magic = readBe32(dtb);
        putStr(" magic=");
        putHex(magic);
        if (magic == fdt.MAGIC) {
            dtb_size = readBe32(dtb + 4);
            putStr(" totalsize=");
            putDec(dtb_size);
            putStr(" (FDT OK)");
        } else {
            putStr(" (bad FDT magic)");
        }
    }
    putStr("\n");

    trap.init();
    putStr("  stvec installed\n");

    trap.armBreakpointTest();
    putStr("  triggering breakpoint (ebreak)...\n");
    asm volatile (".word 0x00100073");
    if (trap.breakpointWasCaught()) {
        putStr("  breakpoint trap: OK\n");
    } else {
        putStr("  breakpoint trap: FAILED\n");
    }

    // ---- M3: FDT memory → PMM → Sv39 ----
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
        putStr("  M3 FAILED: no /memory in DTB\n");
        sbiShutdown();
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
        putStr("  M3 FAILED: PMM empty\n");
        sbiShutdown();
        while (true) asm volatile ("wfi");
    }

    if (!sv39.initIdentity(regions[0..nreg])) {
        putStr("  M3 FAILED: Sv39 enable\n");
        sbiShutdown();
        while (true) asm volatile ("wfi");
    }
    putStr("  satp Sv39 enabled (identity map)\n");

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

    // Map a fresh page at a non-identity VA, write/read, then unmap + #PF.
    const test_va: usize = 0x40000000;
    const test_pa = pmm.allocPage() orelse {
        putStr("  M3 FAILED: alloc for map test\n");
        sbiShutdown();
        while (true) asm volatile ("wfi");
    };
    if (!sv39.mapPage(test_va, test_pa, .{ .read = true, .write = true, .exec = false })) {
        putStr("  M3 FAILED: mapPage\n");
        sbiShutdown();
        while (true) asm volatile ("wfi");
    }
    const cell: *volatile u64 = @ptrFromInt(test_va);
    cell.* = 0x4d33504147452121; // "M3PAGE!!"
    if (cell.* != 0x4d33504147452121) {
        putStr("  M3 FAILED: mapped R/W mismatch\n");
        sbiShutdown();
        while (true) asm volatile ("wfi");
    }
    putStr("  map/unmap R/W: OK\n");

    sv39.unmapPage(test_va);
    pmm.freePage(test_pa);

    trap.armPageFaultTest();
    putStr("  triggering load page fault...\n");
    // 4-byte `ld t0, 0(a0)` with a0 = test_va (unmapped).
    asm volatile (
        \\li a0, 0x40000000
        \\ld t0, 0(a0)
        ::: .{ .memory = true });
    if (trap.pageFaultWasCaught()) {
        putStr("  page-fault trap: OK\n");
    } else {
        putStr("  page-fault trap: FAILED\n");
    }

    putStr("[riscv64] M3 complete\n");

    // ---- M7: virtio-mmio block + net ----
    const vblk = @import("virtio_blk.zig");
    if (!vblk.selfTest()) {
        putStr("  (M7 blk skipped/failed — continuing)\n");
    }
    const vnet = @import("virtio_net.zig");
    if (!vnet.selfTest()) {
        putStr("  (M7-net skipped/failed — continuing)\n");
    }

    // ---- M6: U-mode + ecall (continues into M5 on sys_exit) ----
    const user = @import("user.zig");
    user.enter();
}
