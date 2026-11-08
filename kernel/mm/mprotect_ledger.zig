//! How an mprotect changes the RLIMIT_DATA ledger (Mm.data_used, shown as VmData). Linux (measured with gcc probes): a private mapping counts as data
//! while it is writable; making it writable adds its pages, taking writability away gives them back, PROT_NONE and execute-only mean "not writable",
//! a shared mapping never counts, and a change that would push the ledger past the limit is ENOMEM and changes nothing.
const std = @import("std");

pub const PROT_WRITE: u8 = 2;

/// Whether a region with this protection and sharing is counted as data.
pub fn counts(prot: u8, shared: bool) bool {
    return (prot & PROT_WRITE) != 0 and !shared;
}

/// What mprotect does to the ledger for the `pages` of one region that fall inside the changed range: pages added (the region was not data and the
/// new protection makes it data) or pages released (the opposite). Both are zero when nothing changes.
pub const Delta = struct { add: u64 = 0, release: u64 = 0 };

pub fn delta(old_prot: u8, new_prot: u8, shared: bool, pages: u64) Delta {
    const was = counts(old_prot, shared);
    const will = counts(new_prot, shared);
    if (!was and will) return .{ .add = pages };
    if (was and !will) return .{ .release = pages };
    return .{};
}

/// The ledger after applying one delta; the release saturates so a ledger that was already lowered (or never charged) cannot underflow.
pub fn apply(used: u64, d: Delta, page: u64) u64 {
    return (used +| (d.add * page)) -| (d.release * page);
}

/// Whether the whole mprotect fits the limit: the net growth (everything added minus everything released in the same call) must pass the same
/// check as any other data charge. `limit` is RLIM_INFINITY for no limit.
pub fn fits(used: u64, add_pages: u64, release_pages: u64, page: u64, limit: u64, infinity: u64) bool {
    if (limit == infinity) return true;
    const add = add_pages * page;
    const release = release_pages * page;
    if (add <= release) return true;
    const net = add - release;
    return used <= limit and net <= limit - used;
}

test "ledger: only a private mapping that is writable counts" {
    try std.testing.expect(counts(3, false));
    try std.testing.expect(!counts(1, false));
    try std.testing.expect(!counts(0, false));
    try std.testing.expect(!counts(5, false)); // read+exec
    try std.testing.expect(counts(7, false));
    try std.testing.expect(!counts(3, true)); // shared never counts
}

test "ledger: becoming writable adds, giving writability up releases, everything else is zero" {
    try std.testing.expectEqual(Delta{ .add = 256 }, delta(1, 3, false, 256));
    try std.testing.expectEqual(Delta{ .release = 256 }, delta(3, 1, false, 256));
    try std.testing.expectEqual(Delta{ .release = 7 }, delta(3, 0, false, 7)); // PROT_NONE is not data
    try std.testing.expectEqual(Delta{ .add = 7 }, delta(0, 2, false, 7));
    try std.testing.expectEqual(Delta{}, delta(1, 5, false, 9)); // read -> read+exec
    try std.testing.expectEqual(Delta{}, delta(3, 7, false, 9)); // still writable
    try std.testing.expectEqual(Delta{}, delta(1, 3, true, 9)); // shared
}

test "ledger: apply saturates and never underflows" {
    try std.testing.expectEqual(@as(u64, 4096 * 5), apply(4096 * 2, .{ .add = 3 }, 4096));
    try std.testing.expectEqual(@as(u64, 4096), apply(4096 * 3, .{ .release = 2 }, 4096));
    try std.testing.expectEqual(@as(u64, 0), apply(4096, .{ .release = 100 }, 4096));
    try std.testing.expectEqual(std.math.maxInt(u64), apply(std.math.maxInt(u64) - 1, .{ .add = 1000 }, 4096));
}

test "ledger: the limit check uses the net growth of the whole call" {
    const inf = std.math.maxInt(u64);
    const page: u64 = 4096;
    // 3 MiB limit, 2 MiB used: adding 2 MiB does not fit, adding 1 MiB does.
    try std.testing.expect(!fits(2 << 20, 512, 0, page, 3 << 20, inf));
    try std.testing.expect(fits(2 << 20, 256, 0, page, 3 << 20, inf));
    // Releasing in the same call pays for the addition.
    try std.testing.expect(fits(2 << 20, 512, 512, page, 3 << 20, inf));
    try std.testing.expect(fits(2 << 20, 512, 256, page, 3 << 20, inf)); // net +1 MiB lands exactly on the limit
    try std.testing.expect(!fits(2 << 20, 512, 128, page, 3 << 20, inf)); // net +1.5 MiB does not
    // No limit: anything fits. A ledger already past a lowered limit still blocks growth but allows a net shrink.
    try std.testing.expect(fits(1 << 40, 1 << 30, 0, page, inf, inf));
    try std.testing.expect(!fits(4 << 20, 1, 0, page, 3 << 20, inf));
    try std.testing.expect(fits(4 << 20, 1, 5, page, 3 << 20, inf));
}
