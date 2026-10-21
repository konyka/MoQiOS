//! Neighbor Advertisement → neighbor-cache decision (RFC 4861 §7.2.5).
//! Pure: no ndp/arch imports; the caller maps ndp.NeighborState onto
//! `EntryState` and applies the result through ndp.update.
//!
//! The only cache mutation available to the caller is ndp.update (install
//! MAC + REACHABLE), so this returns either the MAC to install as REACHABLE
//! or null (leave the entry alone). RFC transitions that would land in
//! STALE (unsolicited override with a new MAC, O=0 NA with a different MAC
//! on a REACHABLE entry, unsolicited NA completing an INCOMPLETE entry) are
//! all "leave alone" here: never overwrite without O, never REACHABLE
//! without S.

pub const EntryState = enum { none, incomplete, reachable, stale, delay, probe };

pub const Na = struct {
    solicited: bool,
    override: bool,
    /// Target Link-Layer Address option, if present.
    tlla: ?[6]u8,
};

/// Flags byte (first byte after the checksum): R=0x80, S=0x40, O=0x20.
pub fn parseFlags(flags_byte: u8, tlla: ?[6]u8) Na {
    return .{
        .solicited = (flags_byte & 0x40) != 0,
        .override = (flags_byte & 0x20) != 0,
        .tlla = tlla,
    };
}

fn macEq(a: [6]u8, b: [6]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// `cached` is the entry's current MAC (only consulted for non-incomplete
/// entries on a solicited NA; null there means the entry vanished).
pub fn decide(state: EntryState, na: Na, cached: ?[6]u8) ?[6]u8 {
    // Only a solicited NA may make an entry REACHABLE.
    if (!na.solicited) return null;
    switch (state) {
        // No entry: the advertisement SHOULD be silently discarded.
        .none => return null,
        .incomplete => return na.tlla,
        .reachable, .stale, .delay, .probe => {
            const cur = cached orelse return null;
            const t = na.tlla orelse return cur;
            if (!na.override and !macEq(t, cur)) return null;
            return t;
        },
    }
}
