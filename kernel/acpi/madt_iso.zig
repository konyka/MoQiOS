/// MADT Interrupt Source Override (ISO, entry type 2) table — pure logic.
///
/// No kernel imports — host-tested via tests/main.zig (wired through
/// kernel/host_test.zig). acpi_parser.zig fills an IsoTable while walking
/// the MADT; ioapic.zig consults it when routing a GSI so firmware-declared
/// trigger/polarity win over the edge/active-high defaults.
///
/// MADT type-2 entry layout: type(1) length(1) bus(1) source-irq(1)
/// gsi(4) flags(2). Flags:
///   bits 0-1 polarity: 0 = conforms to bus spec, 1 = active high,
///                      3 = active low (2 reserved)
///   bits 2-3 trigger:  0 = conforms to bus spec, 1 = edge,
///                      3 = level (2 reserved)
/// "Conforms" for the ISA bus means edge-triggered, active-high — the same
/// defaults the IOAPIC used before ISOs were parsed.

pub const MAX_ISO: u32 = 16;

pub const Trigger = enum { edge, level };
pub const Polarity = enum { active_high, active_low };

pub const IsoEntry = struct {
    bus: u8 = 0,
    irq: u8 = 0,
    gsi: u32 = 0,
    flags: u16 = 0,
};

pub const IsoTable = struct {
    entries: [MAX_ISO]IsoEntry = @splat(.{}),
    count: u32 = 0,

    /// Record an ISO entry. A later entry for the same GSI overrides the
    /// earlier one in place (firmware tables occasionally repeat a GSI);
    /// returns false only when the table is full.
    pub fn add(self: *IsoTable, e: IsoEntry) bool {
        for (self.entries[0..self.count]) |*known| {
            if (known.gsi == e.gsi) {
                known.* = e;
                return true;
            }
        }
        if (self.count >= MAX_ISO) return false;
        self.entries[self.count] = e;
        self.count += 1;
        return true;
    }

    /// Find the ISO entry overriding `gsi`, if any.
    pub fn lookup(self: *const IsoTable, gsi: u32) ?IsoEntry {
        for (self.entries[0..self.count]) |e| {
            if (e.gsi == gsi) return e;
        }
        return null;
    }
};

/// Polarity for an ISO flags word; "conforms" and the reserved encoding
/// both fall back to active-high (the pre-ISO default).
pub fn polarityOf(flags: u16) Polarity {
    return switch (flags & 0x3) {
        0x3 => .active_low,
        else => .active_high,
    };
}

/// Trigger mode for an ISO flags word; "conforms" and the reserved
/// encoding both fall back to edge (the pre-ISO default).
pub fn triggerOf(flags: u16) Trigger {
    return switch ((flags >> 2) & 0x3) {
        0x3 => .level,
        else => .edge,
    };
}
