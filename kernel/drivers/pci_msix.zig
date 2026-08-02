//! Pure MSI-X capability parsing and message composition helpers.
//!
//! Everything here operates on byte slices / plain values so it can be host
//! tested (wired into tests/main.zig via kernel/host_test.zig). The MMIO and
//! config-space access that drives a real device lives in pci.zig as thin
//! wrappers over these functions.

const byte_order = @import("../lib/byte_order.zig");

/// PCI capability IDs.
pub const CAP_ID_MSI: u8 = 0x05;
pub const CAP_ID_MSIX: u8 = 0x11;

/// Decoded MSI-X capability contents.
pub const MsixInfo = struct {
    /// Number of MSI-X table entries (message-control table size is N-1).
    table_size: u16,
    /// BAR index holding the MSI-X table.
    table_bir: u8,
    /// Byte offset of the table within that BAR (8-byte aligned).
    table_offset: u32,
    /// BAR index holding the Pending Bit Array.
    pba_bir: u8,
    /// Byte offset of the PBA within that BAR (8-byte aligned).
    pba_offset: u32,
};

/// Cap on capability-list hops: guards against a corrupt list that loops.
const MAX_CAP_STEPS = 48;

/// Walk the capability list of a PCI config-space image and return the
/// offset of capability `cap_id`, or null if absent. `config` is the raw
/// config space (first byte = config offset 0); short slices return null
/// rather than reading out of bounds.
pub fn findCapability(config: []const u8, cap_id: u8) ?u8 {
    if (config.len < 0x40) return null;
    // Status register (offset 0x06), bit 4: capabilities list present.
    const status = byte_order.readU16Le(config[0x06..0x08]);
    if ((status & 0x10) == 0) return null;

    var off: u8 = config[0x34] & 0xFC;
    var steps: u32 = 0;
    while (off != 0 and steps < MAX_CAP_STEPS) : (steps += 1) {
        const idx: usize = off;
        if (idx + 1 >= config.len) return null;
        if (config[idx] == cap_id) return off;
        off = config[idx + 1] & 0xFC;
    }
    return null;
}

/// Decode the MSI-X table size field (message control bits 10:0, N-1 based).
pub fn msixTableSize(msg_control: u16) u16 {
    return (msg_control & 0x07FF) + 1;
}

/// Parse an MSI-X capability at `cap_offset` within a config-space image.
/// Returns null if the bytes at that offset are not an MSI-X capability.
pub fn parseMsixCapability(config: []const u8, cap_offset: u8) ?MsixInfo {
    const idx: usize = cap_offset;
    if (idx + 12 > config.len) return null;
    if (config[idx] != CAP_ID_MSIX) return null;
    const msg_control = byte_order.readU16Le(config[idx + 2 ..][0..2]);
    const table_reg = byte_order.readU32Le(config[idx + 4 ..][0..4]);
    const pba_reg = byte_order.readU32Le(config[idx + 8 ..][0..4]);
    return parseMsixRegs(msg_control, table_reg, pba_reg);
}

/// Decode an MSI-X capability from its three raw register values:
/// message control, table BIR/offset, PBA BIR/offset.
pub fn parseMsixRegs(msg_control: u16, table_reg: u32, pba_reg: u32) MsixInfo {
    return .{
        .table_size = msixTableSize(msg_control),
        .table_bir = @truncate(table_reg & 0x7),
        .table_offset = table_reg & 0xFFFF_FFF8,
        .pba_bir = @truncate(pba_reg & 0x7),
        .pba_offset = pba_reg & 0xFFFF_FFF8,
    };
}

/// Compose the MSI/MSI-X message address for xAPIC fixed delivery:
/// the LAPIC MMIO base with the destination APIC ID in bits 19:12.
pub fn composeMessageAddress(lapic_base: u64, dest_apic_id: u8) u64 {
    return lapic_base | (@as(u64, dest_apic_id) << 12);
}

/// Compose the MSI/MSI-X message data word: delivery mode fixed (000),
/// edge-triggered — only the interrupt vector occupies the low byte.
pub fn composeMessageData(vector: u8) u32 {
    return vector;
}
