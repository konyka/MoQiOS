/// Static host table — built-in name → IPv4 mappings consulted by
/// dns.resolve() BEFORE any cache lookup or network query.
///
/// Pure module: no kernel imports, host-tested via tests/main.zig
/// ("v1.1 finishing" block, wired through kernel/host_test.zig).
///
/// Rationale: the real resolver needs a configured NIC, a reachable DNS
/// server (DHCP-provided or the 8.8.8.8 fallback) and pumps RX polling
/// for ~2s per query. Names the kernel can answer authoritatively on its
/// own — above all "localhost", and the QEMU slirp default gateway —
/// must not depend on any of that.

pub const Entry = struct {
    name: []const u8,
    ip: [4]u8,
};

/// Built-in mappings. Keep small and authoritative: anything not listed
/// here falls through to the DNS cache and then the network query.
pub const table = [_]Entry{
    .{ .name = "localhost", .ip = .{ 127, 0, 0, 1 } },
    // QEMU user-mode networking (slirp) default gateway / host address.
    .{ .name = "gateway", .ip = .{ 10, 0, 2, 2 } },
};

/// Look up a hostname in the static table. DNS names are
/// case-insensitive (ASCII); the match must cover the whole name.
/// Returns the IPv4 address, or null when the name is not static.
pub fn lookup(name: []const u8) ?[4]u8 {
    for (&table) |*e| {
        if (eqlIgnoreCase(e.name, name)) return e.ip;
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
