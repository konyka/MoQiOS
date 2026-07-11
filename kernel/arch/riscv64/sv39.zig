//! Sv39 page tables for the riscv64 skeleton (Milestone 3).
//!
//! Early bring-up identity-maps DRAM + UART MMIO, then enables paging via
//! `satp`. Additional map/unmap helpers support the M3 self-test.

const pmm = @import("pmm.zig");

pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;

const PTE_V: u64 = 1 << 0;
const PTE_R: u64 = 1 << 1;
const PTE_W: u64 = 1 << 2;
const PTE_X: u64 = 1 << 3;
const PTE_U: u64 = 1 << 4;
const PTE_G: u64 = 1 << 5;
const PTE_A: u64 = 1 << 6;
const PTE_D: u64 = 1 << 7;

pub const MapFlags = struct {
    read: bool = true,
    write: bool = true,
    exec: bool = false,
    user: bool = false,
};

var root_phys: usize = 0;

fn pteLeaf(phys: usize, flags: MapFlags) u64 {
    var pte: u64 = PTE_V | PTE_A | PTE_D | (@as(u64, @intCast(phys >> 12)) << 10);
    if (flags.user) {
        pte |= PTE_U;
    } else {
        pte |= PTE_G;
    }
    if (flags.read) pte |= PTE_R;
    if (flags.write) pte |= PTE_W;
    if (flags.exec) pte |= PTE_X;
    return pte;
}

fn pteTable(next_phys: usize) u64 {
    return PTE_V | (@as(u64, @intCast(next_phys >> 12)) << 10);
}

fn vpn(va: usize, level: u2) usize {
    return (va >> (@as(u6, 12) + @as(u6, level) * 9)) & 0x1ff;
}

fn tableAt(phys: usize) *[512]u64 {
    return @ptrFromInt(phys);
}

fn walkAlloc(va: usize, create: bool) ?struct { pte: *u64 } {
    var table_phys = root_phys;
    var level: i32 = 2;
    while (level > 0) : (level -= 1) {
        const idx = vpn(va, @intCast(level));
        const table = tableAt(table_phys);
        var pte = table[idx];
        if ((pte & PTE_V) == 0) {
            if (!create) return null;
            const next = pmm.allocPage() orelse return null;
            pte = pteTable(next);
            table[idx] = pte;
        } else if ((pte & (PTE_R | PTE_W | PTE_X)) != 0) {
            // Mid-level leaf (huge page) — not used in M3.
            return null;
        }
        table_phys = @as(usize, @intCast((pte >> 10) << 12));
    }
    const idx0 = vpn(va, 0);
    return .{ .pte = &tableAt(table_phys)[idx0] };
}

pub fn mapPage(va: usize, pa: usize, flags: MapFlags) bool {
    const slot = walkAlloc(va, true) orelse return false;
    slot.pte.* = pteLeaf(pa, flags);
    return true;
}

pub fn unmapPage(va: usize) void {
    const slot = walkAlloc(va, false) orelse return;
    slot.pte.* = 0;
    // Local TLB shootdown for this VA.
    asm volatile ("sfence.vma %[va], zero"
        :
        : [va] "r" (va),
        : .{ .memory = true });
}

pub fn isMapped(va: usize) bool {
    const slot = walkAlloc(va, false) orelse return false;
    return (slot.pte.* & PTE_V) != 0;
}

fn mapRangeIdentity(phys_lo: usize, phys_hi: usize, flags: MapFlags) bool {
    var p = phys_lo & ~(PAGE_SIZE - 1);
    const end = (phys_hi + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    while (p < end) : (p += PAGE_SIZE) {
        if (!mapPage(p, p, flags)) return false;
    }
    return true;
}

/// Build root PT, identity-map DRAM regions + UART, enable Sv39.
pub fn initIdentity(regions: []const @import("fdt.zig").MemRegion) bool {
    root_phys = pmm.allocPage() orelse return false;

    // UART MMIO (NS16550 at 0x10000000 on QEMU virt).
    if (!mapPage(0x10000000, 0x10000000, .{ .read = true, .write = true, .exec = false }))
        return false;

    for (regions) |r| {
        const lo: usize = @intCast(r.base);
        const hi: usize = @intCast(r.base + r.size);
        // DRAM needs R/W/X so the kernel text keeps executing after satp.
        if (!mapRangeIdentity(lo, hi, .{ .read = true, .write = true, .exec = true }))
            return false;
    }

    const satp: usize = (@as(usize, 8) << 60) | (root_phys >> 12);
    asm volatile (
        \\csrw satp, %[s]
        \\sfence.vma
        :
        : [s] "r" (satp),
        : .{ .memory = true });
    return true;
}

pub fn rootPhys() usize {
    return root_phys;
}
