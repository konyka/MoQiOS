//! AArch64 stage-1 paging for the skeleton (Milestone 9-3/9-6).
//!
//! 39-bit VA / 4 KiB granule (T0SZ=25). Identity-maps DRAM with 2 MiB blocks
//! and PL011/GIC MMIO with device pages, then enables the MMU via SCTLR_EL1.M.
//!
//! Flag bits are a plain `u8` (not a Zig struct) to avoid Debug-mode NEON
//! loads of misaligned struct copies that Data-Abort on aarch64.

const pmm = @import("pmm.zig");

pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;
const BLOCK_2M: usize = 2 * 1024 * 1024;

pub const F_WRITE: u8 = 1 << 0;
pub const F_EXEC: u8 = 1 << 1;
pub const F_DEVICE: u8 = 1 << 2;
pub const F_USER: u8 = 1 << 3;

// Descriptor bits
const DESC_VALID: u64 = 1 << 0;
const DESC_TABLE: u64 = 1 << 1;
const DESC_BLOCK: u64 = 0;
const DESC_AF: u64 = 1 << 10;
const DESC_SH_IS: u64 = 0b11 << 8;
const DESC_AP_RW_EL1: u64 = 0 << 6;
const DESC_AP_RW_EL0: u64 = @as(u64, 0b01) << 6;
const DESC_AP_RO_EL0: u64 = @as(u64, 0b11) << 6;
const DESC_ATTR_DEVICE: u64 = 0 << 2;
const DESC_ATTR_NORMAL: u64 = 1 << 2;
const DESC_PXN: u64 = 1 << 53;
const DESC_UXN: u64 = 1 << 54;

var root_phys: usize = 0;
var mmu_on: bool = false;

fn tableAt(phys: usize) *[512]u64 {
    return @ptrFromInt(phys);
}

fn attrBits(flags: u8) u64 {
    if ((flags & F_DEVICE) != 0) {
        return DESC_AF | DESC_SH_IS | DESC_ATTR_DEVICE | DESC_PXN | DESC_UXN;
    }
    var d: u64 = DESC_AF | DESC_SH_IS | DESC_ATTR_NORMAL;
    const user = (flags & F_USER) != 0;
    const write = (flags & F_WRITE) != 0;
    const exec = (flags & F_EXEC) != 0;
    if (user) {
        d |= if (write) DESC_AP_RW_EL0 else DESC_AP_RO_EL0;
    } else {
        d |= DESC_AP_RW_EL1;
    }
    if (!exec) {
        d |= DESC_PXN | DESC_UXN;
    } else if (user) {
        d |= DESC_PXN;
    } else {
        d |= DESC_UXN;
    }
    return d;
}

fn pteTable(next: usize) u64 {
    return DESC_VALID | DESC_TABLE | @as(u64, @intCast(next & ~@as(usize, 0xfff)));
}

fn pteBlock2M(pa: usize, flags: u8) u64 {
    return DESC_VALID | DESC_BLOCK | attrBits(flags) | @as(u64, @intCast(pa & ~@as(usize, BLOCK_2M - 1)));
}

fn ptePage4K(pa: usize, flags: u8) u64 {
    return DESC_VALID | DESC_TABLE | attrBits(flags) | @as(u64, @intCast(pa & ~@as(usize, 0xfff)));
}

fn idxL1(va: usize) usize {
    return (va >> 30) & 0x1ff;
}
fn idxL2(va: usize) usize {
    return (va >> 21) & 0x1ff;
}
fn idxL3(va: usize) usize {
    return (va >> 12) & 0x1ff;
}

fn ensureL2(l1: *[512]u64, va: usize) usize {
    const i = idxL1(va);
    var d = l1[i];
    if ((d & DESC_VALID) == 0) {
        const next = pmm.allocPage();
        if (next == 0) return 0;
        d = pteTable(next);
        l1[i] = d;
    } else if ((d & DESC_TABLE) == 0) {
        return 0;
    }
    return @intCast(d & 0x0000fffffffff000);
}

fn ensureL3(l2: *[512]u64, va: usize) usize {
    const i = idxL2(va);
    var d = l2[i];
    if ((d & DESC_VALID) == 0) {
        const next = pmm.allocPage();
        if (next == 0) return 0;
        d = pteTable(next);
        l2[i] = d;
    } else if ((d & DESC_TABLE) == 0) {
        return 0;
    }
    return @intCast(d & 0x0000fffffffff000);
}

fn tlbInvalidate(va: usize) void {
    if (!mmu_on) return;
    asm volatile (
        \\dsb ishst
        \\tlbi vaae1is, %[va]
        \\dsb ish
        \\isb
        :
        : [va] "r" (va >> 12),
        : .{ .memory = true });
}

pub fn mapPage(va: usize, pa: usize, flags: u8) bool {
    const l1 = tableAt(root_phys);
    const l2p = ensureL2(l1, va);
    if (l2p == 0) return false;
    const l3p = ensureL3(tableAt(l2p), va);
    if (l3p == 0) return false;
    tableAt(l3p)[idxL3(va)] = ptePage4K(pa, flags);
    tlbInvalidate(va);
    return true;
}

pub fn unmapPage(va: usize) void {
    const l1 = tableAt(root_phys);
    const l1d = l1[idxL1(va)];
    if ((l1d & (DESC_VALID | DESC_TABLE)) != (DESC_VALID | DESC_TABLE)) return;
    const l2 = tableAt(@intCast(l1d & 0x0000fffffffff000));
    const l2d = l2[idxL2(va)];
    if ((l2d & (DESC_VALID | DESC_TABLE)) != (DESC_VALID | DESC_TABLE)) return;
    const l3 = tableAt(@intCast(l2d & 0x0000fffffffff000));
    l3[idxL3(va)] = 0;
    tlbInvalidate(va);
}

/// SK-40: valid descriptor with AP[1] set — page is EL0-accessible.
/// Handles both 2M blocks (L2 leaf) and 4K pages (L3 leaf).
pub fn isUserMapped(va: usize) bool {
    const l1d = tableAt(root_phys)[idxL1(va)];
    if ((l1d & (DESC_VALID | DESC_TABLE)) != (DESC_VALID | DESC_TABLE)) return false;
    const l2d = tableAt(@intCast(l1d & 0x0000fffffffff000))[idxL2(va)];
    if ((l2d & DESC_VALID) == 0) return false;
    if ((l2d & DESC_TABLE) == 0) {
        return (l2d & (@as(u64, 1) << 6)) != 0; // block: AP[1]
    }
    const l3d = tableAt(@intCast(l2d & 0x0000fffffffff000))[idxL3(va)];
    if ((l3d & DESC_VALID) == 0) return false;
    return (l3d & (@as(u64, 1) << 6)) != 0; // page: AP[1]
}

fn mapBlock2MIdentity(pa: usize, flags: u8) bool {
    const l1 = tableAt(root_phys);
    const l2p = ensureL2(l1, pa);
    if (l2p == 0) return false;
    tableAt(l2p)[idxL2(pa)] = pteBlock2M(pa, flags);
    return true;
}

fn mapRange2M(phys_lo: usize, phys_hi: usize, flags: u8) bool {
    var p = phys_lo & ~(BLOCK_2M - 1);
    const end = (phys_hi + BLOCK_2M - 1) & ~(BLOCK_2M - 1);
    while (p < end) : (p += BLOCK_2M) {
        if (!mapBlock2MIdentity(p, flags)) return false;
    }
    return true;
}

pub fn initIdentity(regions: []const @import("fdt.zig").MemRegion) bool {
    root_phys = pmm.allocPage();
    if (root_phys == 0) return false;

    if (!mapPage(0x09000000, 0x09000000, F_WRITE | F_DEVICE))
        return false;

    const gic = @import("gic.zig").mmioRange();
    if (!mapRange2M(gic.lo, gic.hi, F_WRITE | F_DEVICE))
        return false;

    for (regions) |r| {
        const lo: usize = @intCast(r.base);
        const hi: usize = @intCast(r.base + r.size);
        if (!mapRange2M(lo, hi, F_WRITE | F_EXEC))
            return false;
    }

    const mair: u64 = 0x00 | (@as(u64, 0xff) << 8);
    asm volatile ("msr mair_el1, %[v]"
        :
        : [v] "r" (mair),
    );

    const tcr: u64 = 25 |
        (0b00 << 14) |
        (0b11 << 12) |
        (0b01 << 10) |
        (0b01 << 8) |
        (@as(u64, 2) << 32);
    asm volatile ("msr tcr_el1, %[v]"
        :
        : [v] "r" (tcr),
    );

    asm volatile ("msr ttbr0_el1, %[v]"
        :
        : [v] "r" (root_phys),
    );
    asm volatile ("isb");

    var sctlr: u64 = asm volatile ("mrs %[r], sctlr_el1"
        : [r] "=r" (-> u64),
    );
    sctlr |= (1 << 0) | (1 << 2) | (1 << 12);
    sctlr &= ~@as(u64, 1 << 1); // keep A clear
    asm volatile (
        \\msr sctlr_el1, %[v]
        \\isb
        :
        : [v] "r" (sctlr),
        : .{ .memory = true });
    mmu_on = true;
    return true;
}

pub fn rootPhys() usize {
    return root_phys;
}
