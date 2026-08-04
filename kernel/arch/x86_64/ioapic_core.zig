/// Pure encode/decode for the 64-bit IOAPIC redirection-table (REDTBL) entry.
///
/// No kernel imports — host-tested via tests/main.zig (wired through
/// kernel/host_test.zig). The MMIO glue lives in ioapic.zig.
///
/// REDTBL entry bit layout (Intel 82093AA / SDM vol. 3A):
///   0-7   interrupt vector
///   8-10  delivery mode (000 = fixed)
///   11    destination mode (0 = physical)
///   12    delivery status (RO)
///   13    pin polarity (0 = active high, 1 = active low)
///   14    remote IRR (RO)
///   15    trigger mode (0 = edge, 1 = level)
///   16    interrupt mask (1 = masked)
///   17-55 reserved
///   56-63 destination field (physical mode: target LAPIC ID)

pub const Trigger = enum(u1) { edge = 0, level = 1 };
pub const Polarity = enum(u1) { active_high = 0, active_low = 1 };

pub const RedEntryParams = struct {
    vector: u8,
    dest_apic_id: u8,
    masked: bool,
    trigger: Trigger = .edge,
    polarity: Polarity = .active_high,
};

const MASK_BIT: u64 = 1 << 16;

/// Encode a redirection entry. Fixed delivery mode, physical destination —
/// the only mode this kernel routes.
pub fn encodeRedEntry(p: RedEntryParams) u64 {
    var raw: u64 = p.vector;
    raw |= @as(u64, @intFromEnum(p.polarity)) << 13;
    raw |= @as(u64, @intFromEnum(p.trigger)) << 15;
    if (p.masked) raw |= MASK_BIT;
    raw |= @as(u64, p.dest_apic_id) << 56;
    return raw;
}

/// Decode the software-writable routing fields of a raw entry. The read-only
/// hardware status bits (delivery status, remote IRR) are dropped.
pub fn decodeRedEntry(raw: u64) RedEntryParams {
    return .{
        .vector = @truncate(raw),
        .dest_apic_id = @truncate(raw >> 56),
        .masked = raw & MASK_BIT != 0,
        .trigger = @enumFromInt(@as(u1, @truncate(raw >> 15))),
        .polarity = @enumFromInt(@as(u1, @truncate(raw >> 13))),
    };
}

/// Set or clear the mask bit, preserving every other bit verbatim (including
/// the read-only status bits a read-modify-write cycle may have picked up).
pub fn setRedEntryMask(raw: u64, masked: bool) u64 {
    return if (masked) raw | MASK_BIT else raw & ~MASK_BIT;
}

pub fn redEntryVector(raw: u64) u8 {
    return @truncate(raw);
}
