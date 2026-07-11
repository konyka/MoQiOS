//! AArch64 stage-1 paging for the skeleton (Milestone 9-3).
//!
//! 39-bit VA / 4 KiB granule (T0SZ=25). Identity-maps DRAM with 2 MiB blocks
//! and PL011 MMIO with a 4 KiB page, then enables the MMU via SCTLR_EL1.M.

const pmm = @import("pmm.zig");

pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;
const BLOCK_2M: usize = 2 * 1024 * 1024;

// Descriptor bits
const DESC_VALID: u64 = 1 << 0;
const DESC_TABLE: u64 = 1 << 1; // table (or page at L3) when set with VALID
const DESC_BLOCK: u64 = 0; // block when VALID and bit1 clear (L1/L2)
const DESC_AF: u64 = 1 << 10;
const DESC_SH_IS: u64 = 0b11 << 8; // inner shareable
const DESC_AP_RW: u64 = 0 << 6; // EL1 RW
const DESC_ATTR_DEVICE: u64 = 0 << 2; // MAIR Attr0
const DESC_ATTR_NORMAL: u64 = 1 << 2; // MAIR Attr1
const DESC_PXN: u64 = 1 << 53;
const DESC_UXN: u64 = 1 << 54;

pub const MapFlags = struct {
    read: bool = true,
    write: bool = true,
    exec: bool = false,
    device: bool = false,
};

var root_phys: usize = 0; // L1 table (512 entries)

fn tableAt(phys: usize) *[512]u64 {
    return @ptrFromInt(phys);
}

fn attrBits(flags: MapFlags) u64 {
    var d: u64 = DESC_AF | DESC_SH_IS | DESC_AP_RW;
    if (flags.device) {
        d |= DESC_ATTR_DEVICE | DESC_PXN | DESC_UXN;
    } else {
        d |= DESC_ATTR_NORMAL;
        if (!flags.exec) d |= DESC_PXN;
        d |= DESC_UXN; // no EL0 exec in early bring-up
    }
    _ = flags.read;
    _ = flags.write;
    return d;
}

fn pteTable(next: usize) u64 {
    return DESC_VALID | DESC_TABLE | @as(u64, @intCast(next & ~@as(usize, 0xfff)));
}

fn pteBlock2M(pa: usize, flags: MapFlags) u64 {
    return DESC_VALID | DESC_BLOCK | attrBits(flags) | @as(u64, @intCast(pa & ~@as(usize, BLOCK_2M - 1)));
}

fn ptePage4K(pa: usize, flags: MapFlags) u64 {
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

fn ensureL2(l1: *[512]u64, va: usize) ?*[512]u64 {
    const i = idxL1(va);
    var d = l1[i];
    if ((d & DESC_VALID) == 0) {
        const next = pmm.allocPage();
        if (next == 0) return null;
        d = pteTable(next);
        l1[i] = d;
    } else if ((d & DESC_TABLE) == 0) {
        return null; // unexpected block at L1
    }
    return tableAt(@intCast(d & 0x0000fffffffff000));
}

fn ensureL3(l2: *[512]u64, va: usize) ?*[512]u64 {
    const i = idxL2(va);
    var d = l2[i];
    if ((d & DESC_VALID) == 0) {
        const next = pmm.allocPage();
        if (next == 0) return null;
        d = pteTable(next);
        l2[i] = d;
    } else if ((d & DESC_TABLE) == 0) {
        return null; // 2MB block already here
    }
    return tableAt(@intCast(d & 0x0000fffffffff000));
}

pub fn mapPage(va: usize, pa: usize, flags: MapFlags) bool {
    const l1 = tableAt(root_phys);
    const l2 = ensureL2(l1, va) orelse return false;
    const l3 = ensureL3(l2, va) orelse return false;
    l3[idxL3(va)] = ptePage4K(pa, flags);
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
    asm volatile (
        \\dsb ishst
        \\tlbi vaae1is, %[va]
        \\dsb ish
        \\isb
        :
        : [va] "r" (va >> 12),
        : .{ .memory = true });
}

fn mapBlock2MIdentity(pa: usize, flags: MapFlags) bool {
    const l1 = tableAt(root_phys);
    const l2 = ensureL2(l1, pa) orelse return false;
    l2[idxL2(pa)] = pteBlock2M(pa, flags);
    return true;
}

fn mapRange2M(phys_lo: usize, phys_hi: usize, flags: MapFlags) bool {
    var p = phys_lo & ~(BLOCK_2M - 1);
    const end = (phys_hi + BLOCK_2M - 1) & ~(BLOCK_2M - 1);
    while (p < end) : (p += BLOCK_2M) {
        if (!mapBlock2MIdentity(p, flags)) return false;
    }
    return true;
}

/// Build L1, identity-map DRAM + UART, enable MMU.
pub fn initIdentity(regions: []const @import("fdt.zig").MemRegion) bool {
    root_phys = pmm.allocPage();
    if (root_phys == 0) return false;

    // PL011 UART page as device memory.
    if (!mapPage(0x09000000, 0x09000000, .{ .read = true, .write = true, .exec = false, .device = true }))
        return false;

    for (regions) |r| {
        const lo: usize = @intCast(r.base);
        const hi: usize = @intCast(r.base + r.size);
        if (!mapRange2M(lo, hi, .{ .read = true, .write = true, .exec = true, .device = false }))
            return false;
    }

    // Also map the DTB loader window if it sits outside /memory (it shouldn't).
    _ = mapRange2M;

    // MAIR: Attr0 = device-nGnRnE, Attr1 = normal WB
    const mair: u64 = 0x00 | (@as(u64, 0xff) << 8);
    asm volatile ("msr mair_el1, %[v]"
        :
        : [v] "r" (mair),
    );

    // TCR: T0SZ=25 (39-bit), TG0=4K, inner/outer WB WA, inner shareable, IPS=40-bit
    const tcr: u64 = 25 | // T0SZ
        (0b00 << 14) | // TG0 = 4K
        (0b11 << 12) | // SH0 = IS
        (0b01 << 10) | // ORGN0 = WB WA
        (0b01 << 8) | // IRGN0 = WB WA
        (@as(u64, 2) << 32); // IPS = 40 bits
    asm volatile ("msr tcr_el1, %[v]"
        :
        : [v] "r" (tcr),
    );

    asm volatile ("msr ttbr0_el1, %[v]"
        :
        : [v] "r" (root_phys),
    );
    asm volatile ("isb");

    // Enable MMU (+ keep caches if already on; set M|C|I).
    var sctlr: u64 = asm volatile ("mrs %[r], sctlr_el1"
        : [r] "=r" (-> u64),
    );
    sctlr |= (1 << 0) | (1 << 2) | (1 << 12); // M | C | I
    asm volatile (
        \\msr sctlr_el1, %[v]
        \\isb
        :
        : [v] "r" (sctlr),
        : .{ .memory = true });
    return true;
}

pub fn rootPhys() usize {
    return root_phys;
}
