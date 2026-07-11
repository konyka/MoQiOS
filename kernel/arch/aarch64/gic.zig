//! Minimal GICv3 for QEMU `virt` (Milestone 9-5).
//!
//! Enables the CPU interface + redistributor enough to deliver the virtual
//! timer PPI (INTID 27) as an EL1 IRQ. No SPI support yet.

const GICD_BASE: usize = 0x08000000;
const GICR_BASE: usize = 0x080A0000; // CPU0 redistributor
const GICR_SGI_BASE: usize = GICR_BASE + 0x10000;

const GICD_CTLR: usize = 0x000;
const GICD_IIDR: usize = 0x008;
const GICD_CTLR_ARE_NS: u32 = 1 << 4;
const GICD_CTLR_ENABLE_G1A: u32 = 1 << 1;

const GICR_WAKER: usize = 0x014;
const GICR_WAKER_PS: u32 = 1 << 0;
const GICR_WAKER_CA: u32 = 1 << 1;

const GICR_IGROUPR0: usize = 0x080;
const GICR_ISENABLER0: usize = 0x100;
const GICR_IPRIORITYR: usize = 0x400;

pub const TIMER_PPI: u32 = 27;

fn gicd(offset: usize) *volatile u32 {
    return @ptrFromInt(GICD_BASE + offset);
}

fn gicr(offset: usize) *volatile u32 {
    return @ptrFromInt(GICR_BASE + offset);
}

fn gicrSgi(offset: usize) *volatile u32 {
    return @ptrFromInt(GICR_SGI_BASE + offset);
}

fn gicrSgi8(offset: usize) *volatile u8 {
    return @ptrFromInt(GICR_SGI_BASE + offset);
}

fn dsb() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn writeIccSre(v: u64) void {
    asm volatile ("msr icc_sre_el1, %[v]"
        :
        : [v] "r" (v),
    );
    asm volatile ("isb");
}

fn writeIccPmr(v: u64) void {
    asm volatile ("msr icc_pmr_el1, %[v]"
        :
        : [v] "r" (v),
    );
}

fn writeIccBpr1(v: u64) void {
    asm volatile ("msr icc_bpr1_el1, %[v]"
        :
        : [v] "r" (v),
    );
}

fn writeIccIgrpen1(v: u64) void {
    asm volatile ("msr icc_igrpen1_el1, %[v]"
        :
        : [v] "r" (v),
    );
}

fn readIccIar1() u64 {
    return asm volatile ("mrs %[r], icc_iar1_el1"
        : [r] "=r" (-> u64),
    );
}

fn writeIccEoir1(v: u64) void {
    asm volatile ("msr icc_eoir1_el1, %[v]"
        :
        : [v] "r" (v),
    );
}

/// Physical range that must be identity-mapped as device memory before init.
pub fn mmioRange() struct { lo: usize, hi: usize } {
    return .{ .lo = 0x08000000, .hi = 0x08100000 };
}

pub fn distributorIidr() u32 {
    return gicd(GICD_IIDR).*;
}

pub fn init() bool {
    const uart = @import("uart.zig");

    // System register CPU interface.
    writeIccSre(0x7);
    writeIccPmr(0xff);
    writeIccBpr1(0);

    // Probe distributor MMIO.
    const iidr = gicd(GICD_IIDR).*;
    if (iidr == 0 or iidr == 0xffffffff) {
        uart.writeString("  gic: bad GICD_IIDR\n");
        return false;
    }

    // Probe redistributor.
    const typer = gicr(0x08).*; // GICR_TYPER
    if (typer == 0 or typer == 0xffffffff) {
        uart.writeString("  gic: bad GICR_TYPER\n");
        return false;
    }

    // Wake redistributor. QEMU sometimes leaves CA sticky; clear PS and
    // continue after a short wait rather than failing the bring-up.
    gicr(GICR_WAKER).* &= ~GICR_WAKER_PS;
    dsb();
    var spins: u32 = 0;
    while ((gicr(GICR_WAKER).* & GICR_WAKER_CA) != 0) {
        spins += 1;
        if (spins > 1_000_000) break;
        asm volatile ("yield");
    }

    // PPI/SGI → Group 1.
    gicrSgi(GICR_IGROUPR0).* = 0xffffffff;
    dsb();

    gicrSgi8(GICR_IPRIORITYR + TIMER_PPI).* = 0x80;
    gicrSgi(GICR_ISENABLER0).* = @as(u32, 1) << @intCast(TIMER_PPI);
    dsb();

    gicd(GICD_CTLR).* = GICD_CTLR_ARE_NS | GICD_CTLR_ENABLE_G1A;
    dsb();

    writeIccIgrpen1(1);
    return true;
}

pub fn enableCpuIrq() void {
    asm volatile ("msr daifclr, #2");
}

pub fn disableCpuIrq() void {
    asm volatile ("msr daifset, #2");
}

pub fn handleIrq() u32 {
    const iar = readIccIar1();
    const intid: u32 = @truncate(iar);
    if (intid < 1020) {
        if (intid == TIMER_PPI) {
            @import("timer.zig").onInterrupt();
        }
        writeIccEoir1(iar);
    }
    return intid;
}
