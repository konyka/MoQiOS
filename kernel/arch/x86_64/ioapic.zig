/// IOAPIC driver (x86_64) — routes GSIs >= 16 into the LAPIC via the
/// redirection table (REDTBL). The register-level MMIO lives here; the
/// REDTBL entry encode/decode is pure logic in ioapic_core.zig (host-tested).
///
/// Register interface (memory-mapped, accessed via the HHDM):
///   IOREGSEL (offset 0x00, u32): selects the indirect register
///   IOWIN    (offset 0x10, u32): reads/writes the selected register
/// Indirect registers: 0x00 = ID, 0x01 = VER (bits 23:16 = max entry - 1),
/// 0x10+2*i / 0x11+2*i = low/high dword of REDTBL entry i.
///
/// Scope notes:
///   - Only the FIRST IOAPIC from the MADT is used (acpi_parser records one
///     ioapic_address/gsi_base pair); enough for QEMU's single 82489DX.
///   - MADT Interrupt Source Override (type 2) entries are NOT parsed by
///     acpi_parser, so every line is programmed edge-triggered / active-high.
///     The legacy PIC lines (GSI 0-15) keep flowing through the 8259A path
///     unchanged, so this only affects userdrv-claimed GSIs >= 16 (PCI
///     defaults there are level/low, but no in-tree consumer depends on ISO
///     polarity yet — revisit if a device misbehaves).
const hhdm = @import("../../mm/hhdm.zig");
const serial = @import("serial.zig");
const fmt = @import("../../lib/fmt.zig");
const core = @import("ioapic_core.zig");

const REG_IOREGSEL: u64 = 0x00;
const REG_IOWIN: u64 = 0x10;

const IOAPIC_ID: u32 = 0x00;
const IOAPIC_VER: u32 = 0x01;
const REDTBL_BASE: u32 = 0x10;

/// MMIO base (virtual, via HHDM). 0 = not initialized.
var ioapic_base: u64 = 0;
/// Number of redirection entries (VER[23:16] + 1).
var max_entries: u32 = 0;
/// Global system interrupt base of this IOAPIC (from the MADT).
var gsi_base: u32 = 0;

fn readReg(reg: u32) u32 {
    const sel: *volatile u32 = @ptrFromInt(ioapic_base + REG_IOREGSEL);
    const win: *volatile u32 = @ptrFromInt(ioapic_base + REG_IOWIN);
    sel.* = reg;
    return win.*;
}

fn writeReg(reg: u32, value: u32) void {
    const sel: *volatile u32 = @ptrFromInt(ioapic_base + REG_IOREGSEL);
    const win: *volatile u32 = @ptrFromInt(ioapic_base + REG_IOWIN);
    sel.* = reg;
    win.* = value;
}

fn readRedEntry(index: u32) u64 {
    const lo = readReg(REDTBL_BASE + 2 * index);
    const hi = readReg(REDTBL_BASE + 2 * index + 1);
    return @as(u64, lo) | (@as(u64, hi) << 32);
}

fn writeRedEntry(index: u32, raw: u64) void {
    // High dword first: a partial write with the low dword unmasked could
    // otherwise fire a garbage vector at a stale destination.
    writeReg(REDTBL_BASE + 2 * index + 1, @truncate(raw >> 32));
    writeReg(REDTBL_BASE + 2 * index, @truncate(raw));
}

/// Initialize from the MADT results in acpi.info. Safe to call when no
/// IOAPIC was found (ioapic_address == 0): logs and leaves the driver
/// unavailable, so callers keep the PIC-only behavior.
pub fn init(ioapic_phys: u64, base_gsi: u32) void {
    if (ioapic_phys == 0) {
        serial.writeString("[IOAPIC] not present (PIC-only)\n");
        return;
    }

    // Map the MMIO window via the HHDM (huge-page mapping, cache-disabled —
    // same helper the ACPI table walk uses).
    @import("../../main.zig").mapAcpiPage(ioapic_phys);
    ioapic_base = hhdm.physToVirt(ioapic_phys);
    gsi_base = base_gsi;

    const ver = readReg(IOAPIC_VER);
    max_entries = ((ver >> 16) & 0xFF) + 1;

    // Mask every line at boot: nothing may fire until explicitly routed.
    var i: u32 = 0;
    while (i < max_entries) : (i += 1) {
        writeRedEntry(i, core.encodeRedEntry(.{
            .vector = 0,
            .dest_apic_id = 0,
            .masked = true,
        }));
    }

    serial.writeString("[IOAPIC] initialized (");
    fmt.writeDecimal(max_entries);
    serial.writeString(" entries)\n");
}

pub fn isAvailable() bool {
    return ioapic_base != 0;
}

pub fn maxRedirectionEntries() u32 {
    return max_entries;
}

pub fn gsiBase() u32 {
    return gsi_base;
}

/// REDTBL index for a GSI, or null when the GSI is outside this IOAPIC.
fn entryIndex(gsi: u32) ?u32 {
    if (ioapic_base == 0) return null;
    if (gsi < gsi_base) return null;
    const idx = gsi - gsi_base;
    if (idx >= max_entries) return null;
    return idx;
}

/// Route `gsi` to `vector` on the LAPIC `dest_apic_id`, unmasked,
/// edge-triggered, active-high (see the ISO note in the file header).
/// Returns false when the GSI is not handled by this IOAPIC.
pub fn routeGsi(gsi: u32, vector: u8, dest_apic_id: u8) bool {
    const idx = entryIndex(gsi) orelse return false;
    writeRedEntry(idx, core.encodeRedEntry(.{
        .vector = vector,
        .dest_apic_id = dest_apic_id,
        .masked = false,
    }));
    return true;
}

pub fn maskGsi(gsi: u32) void {
    const idx = entryIndex(gsi) orelse return;
    writeRedEntry(idx, core.setRedEntryMask(readRedEntry(idx), true));
}

pub fn unmaskGsi(gsi: u32) void {
    const idx = entryIndex(gsi) orelse return;
    writeRedEntry(idx, core.setRedEntryMask(readRedEntry(idx), false));
}
