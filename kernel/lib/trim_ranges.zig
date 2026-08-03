//! TRIM/discard extent coalescing (G5) — pure logic, host-testable.
//!
//! Filesystem free paths (fat32 cluster chains, ext2 block frees) produce
//! per-cluster/per-block extents, often out of order (ext2 indirect trees).
//! Device TRIM commands want few, large, contiguous ranges, so the free
//! paths accumulate extents in a small buffer and pass them through
//! coalesce() before issuing block_dev.discard() per resulting range.
//!
//! No imports: this file must stay dependency-free so kernel/host_test.zig
//! can compile it for `zig build test` without dragging in arch code.

pub const Extent = struct {
    start: u64, // first sector (LBA)
    count: u32, // number of sectors
};

/// Coalesce `input` into maximal contiguous ranges written to `out`
/// (sorted by start). Adjacent (touching) and overlapping extents merge;
/// zero-count extents are dropped. `out` must be at least `input.len` long
/// (callers flush before their accumulation buffer fills). Returns the
/// number of ranges written, ≤ input.len.
pub fn coalesce(input: []const Extent, out: []Extent) usize {
    if (input.len == 0) return 0;
    std_assert(out.len >= input.len);

    // Copy + insertion sort by start (inputs are tiny: one free batch).
    for (input, 0..) |e, i| out[i] = e;
    const items = out[0..input.len];
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and items[j - 1].start > key.start) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }

    // Merge adjacent/overlapping runs in place.
    var n: usize = 0;
    for (items) |e| {
        if (e.count == 0) continue;
        if (n > 0) {
            const cur = &out[n - 1];
            const cur_end = cur.start + cur.count;
            if (e.start <= cur_end) {
                const e_end = e.start + e.count;
                if (e_end > cur_end) cur.count = @intCast(e_end - cur.start);
                continue;
            }
        }
        out[n] = e;
        n += 1;
    }
    return n;
}

inline fn std_assert(ok: bool) void {
    if (!ok) unreachable; // caller contract: out.len >= input.len
}
