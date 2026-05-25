/// Local APIC driver — per-CPU timer, EOI, spurious interrupt handling.
/// The LAPIC is at physical 0xFEE00000, accessed via HHDM.
/// Timer uses vector 240, calibrated via PIT channel 2.

const hhdm = @import("../../mm/hhdm.zig");
const serial = @import("serial.zig");
const io = @import("io.zig");
const paging = @import("../../arch/x86_64/paging.zig");
const main_mod = @import("../../main.zig");

/// LAPIC timer fires on this vector.
pub const TIMER_VECTOR: u8 = 240;

/// LAPIC MMIO base (virtual address via HHDM)
var lapic_base: u64 = 0;

// LAPIC register offsets
const REG_ID: u32 = 0x020;
const REG_EOI: u32 = 0x0B0;
const REG_SVR: u32 = 0x0F0;
const REG_ICR_LOW: u32 = 0x300;
const REG_ICR_HIGH: u32 = 0x310;
const REG_LVT_TIMER: u32 = 0x320;
const REG_TIMER_INIT: u32 = 0x380;
const REG_TIMER_CUR: u32 = 0x390;
const REG_TIMER_DIV: u32 = 0x3E0;

// LVT Timer mode bits
const TIMER_PERIODIC: u32 = 1 << 17;
const TIMER_MASKED: u32 = 1 << 16;

/// Calibrated tick count for ~100Hz
pub var ticks_per_10ms: u32 = 0;

fn read(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(lapic_base + offset);
    return addr.*;
}

fn writeReg(offset: u32, value: u32) void {
    const addr: *volatile u32 = @ptrFromInt(lapic_base + offset);
    addr.* = value;
}

/// Send End-of-Interrupt.
pub fn eoi() void {
    writeReg(REG_EOI, 0);
}

/// Read this CPU's LAPIC ID.
pub fn id() u8 {
    return @truncate(read(REG_ID) >> 24);
}

/// Send INIT IPI to target AP (resets the AP to real mode).
pub fn sendInitIpi(apic_id: u8) void {
    writeReg(REG_ICR_HIGH, @as(u32, apic_id) << 24);
    // Delivery mode=INIT (0b101), assert level, edge trigger
    writeReg(REG_ICR_LOW, 0x00004500);
    // Wait for delivery (poll bit 12 = delivery status)
    while (read(REG_ICR_LOW) & (1 << 12) != 0) {
        asm volatile ("pause");
    }
}

/// Send Startup IPI (SIPI) to target AP at given 4KB-aligned vector page.
pub fn sendStartupIpi(apic_id: u8, vector_page: u8) void {
    writeReg(REG_ICR_HIGH, @as(u32, apic_id) << 24);
    // Delivery mode=Startup (0b110), assert level, vector = page frame
    writeReg(REG_ICR_LOW, 0x00004600 | @as(u32, vector_page));
    while (read(REG_ICR_LOW) & (1 << 12) != 0) {
        asm volatile ("pause");
    }
}

/// Initialize LAPIC for an AP (no timer calibration — reuse BSP calibrated value).
pub fn initAp() void {
    // Enable APIC: set bit 8 in SVR, spurious vector 0xFF
    writeReg(REG_SVR, 0x100 | 0xFF);

    // Start periodic timer using BSP-calibrated ticks
    writeReg(REG_LVT_TIMER, TIMER_PERIODIC | TIMER_VECTOR);
    writeReg(REG_TIMER_DIV, 0x3);
    writeReg(REG_TIMER_INIT, ticks_per_10ms);
}

/// Get the calibrated ticks per 10ms (needed by APs).
pub fn getTicksPer10ms() u32 {
    return ticks_per_10ms;
}

/// Get the LAPIC MMIO base virtual address (needed by APs).
pub fn getBase() u64 {
    return lapic_base;
}

/// Set the LAPIC MMIO base (used by APs to initialize their local APIC access).
pub fn setBase(base: u64) void {
    lapic_base = base;
}

/// Initialize the BSP's Local APIC and start the periodic timer.
pub fn init(lapic_phys: u64) void {
    // Map LAPIC MMIO region using a 2MB huge page to avoid splitting
    const virt = hhdm.physToVirt(lapic_phys);
    if (!paging.isPageMapped(paging.getKernelPml4(), virt)) {
        const huge_base = lapic_phys & ~@as(u64, paging.PAGE_2MB - 1);
        const pml4 = paging.getKernelPml4();
        const flags = paging.MapFlags{
            .writable = true,
            .user = false,
            .no_execute = true,
            .global = true,
            .write_through = true,
            .cache_disable = true,
        };
        paging.mapHugePage(pml4, hhdm.physToVirt(huge_base), huge_base, flags) catch {};
    }

    lapic_base = virt;

    // Enable APIC: set bit 8 in SVR, spurious vector 0xFF
    writeReg(REG_SVR, 0x100 | 0xFF);

    // Calibrate LAPIC timer using PIT
    calibrateTimer();

    // Configure timer: periodic mode, vector 240
    writeReg(REG_LVT_TIMER, TIMER_PERIODIC | TIMER_VECTOR);
    writeReg(REG_TIMER_DIV, 0x3); // Divide by 16
    writeReg(REG_TIMER_INIT, ticks_per_10ms);

    serial.writeString("[lapic] BSP APIC enabled, timer at ~100Hz (ticks=");
    writeDecimal(ticks_per_10ms);
    serial.writeString(")\n");
}

/// Calibrate LAPIC timer using PIT channel 2 one-shot as reference.
/// Measures how many LAPIC ticks occur in ~10ms.
fn calibrateTimer() void {
    const PIT_CH2_DATA: u16 = 0x42;
    const PIT_CMD: u16 = 0x43;
    const PIT_GATE: u16 = 0x61;

    // 10ms worth of PIT ticks: 1193182 / 100 = 11932
    const PIT_10MS: u16 = 11932;

    // Set LAPIC timer divide to 16
    writeReg(REG_TIMER_DIV, 0x3);

    // Program PIT channel 2 for one-shot mode
    var gate = io.inb(PIT_GATE);
    gate &= 0xFD; // Clear bit 1 (gate off)
    gate |= 0x01; // Set bit 0
    io.outb(PIT_GATE, gate);

    // Channel 2, lobyte/hibyte, mode 0 (one-shot)
    io.outb(PIT_CMD, 0xB0);
    io.outb(PIT_CH2_DATA, @truncate(PIT_10MS & 0xFF));
    io.outb(PIT_CH2_DATA, @truncate(PIT_10MS >> 8));

    // Start LAPIC timer with max count
    writeReg(REG_TIMER_INIT, 0xFFFFFFFF);

    // Gate on — start PIT countdown
    gate = io.inb(PIT_GATE);
    gate |= 0x01;
    io.outb(PIT_GATE, gate);

    // Wait for PIT to expire (bit 5 of port 0x61 goes high)
    while (io.inb(PIT_GATE) & 0x20 == 0) {
        asm volatile ("pause");
    }

    // Read LAPIC timer current count
    const elapsed = 0xFFFFFFFF - read(REG_TIMER_CUR);

    // Stop LAPIC timer
    writeReg(REG_LVT_TIMER, TIMER_MASKED);

    // elapsed ticks in ~10ms → use directly for 100Hz period
    ticks_per_10ms = elapsed;
}

fn writeDecimal(value: u32) void {
    if (value == 0) {
        serial.writeString("0");
        return;
    }
    var buf: [10]u8 = undefined;
    var v = value;
    var i: usize = 0;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    serial.writeString(buf[0..i]);
}
