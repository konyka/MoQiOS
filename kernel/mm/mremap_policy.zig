//! Pure layout rules for mremap on a sub-range of a tracked region. The region table holds one record per mapping, so a
//! range that is only part of a region is first split into head, middle and tail records; the middle is then a whole
//! region and the existing whole-region code can move or resize it. No kernel state, so the host tests cover it all.

const huge_user = @import("huge_user.zig");

/// How [start, start+pages) divides the region [region_base, +region_pages): the three pieces, how many huge blocks each
/// one keeps (huge blocks sit at the start of a region, and a piece keeps one only when it starts at a block boundary).
pub const Plan = struct {
    head_pages: u64,
    mid_pages: u64,
    tail_pages: u64,
    head_huge: u32,
    mid_huge: u32,
    tail_huge: u32,

    /// Whether the region has to be split at all.
    pub fn needed(self: Plan) bool {
        return self.head_pages != 0 or self.tail_pages != 0;
    }

    /// Region-table slots the split needs beyond the one the region already uses: the original record keeps the head
    /// (or becomes the middle when there is no head), so a middle needs a new one only when a head exists, and a tail
    /// always does.
    pub fn extraSlots(self: Plan) u32 {
        var n: u32 = 0;
        if (self.head_pages != 0) n += 1; // the middle
        if (self.tail_pages != 0) n += 1;
        return n;
    }
};

/// The split of the region at `region_base` (`region_pages` pages, `region_huge` huge blocks at its start) around the
/// range at `start` of `pages` pages. Base and start are in the same unit (page numbers or byte addresses divided by the
/// page size; only their difference matters). Null when the range is empty or not wholly inside the region.
pub fn plan(region_base: u64, region_pages: u64, region_huge: u32, start: u64, pages: u64) ?Plan {
    if (pages == 0) return null;
    const region_end = @addWithOverflow(region_base, region_pages);
    const end = @addWithOverflow(start, pages);
    if (region_end[1] != 0 or end[1] != 0) return null;
    if (start < region_base or end[0] > region_end[0]) return null;
    const head = start - region_base;
    const tail = region_end[0] - end[0];
    const block = huge_user.HUGE_PAGES;
    // Whole huge blocks wholly inside [lo, hi) of the region, counted only from the start of the region.
    const head_huge: u32 = @intCast(@min(@as(u64, region_huge), head / block));
    const mid_huge: u32 = if (head == 0) @intCast(@min(@as(u64, region_huge), pages / block)) else 0;
    return .{
        .head_pages = head,
        .mid_pages = pages,
        .tail_pages = tail,
        .head_huge = head_huge,
        .mid_huge = mid_huge,
        .tail_huge = 0,
    };
}

/// What two neighbouring records must agree on to be one region again. File-backed, huge and device records are never
/// merged (each has its own backing reference or block layout), and neither are locked-flagged ones.
pub const Traits = struct {
    prot: u8,
    shared: bool,
    may_write: bool,
    file_kind: u8,
    no_free: bool,
    locked: bool,
    huge_pages: u32,
};

pub fn canCoalesce(a: Traits, b: Traits) bool {
    if (a.file_kind != 0 or b.file_kind != 0) return false;
    if (a.no_free or b.no_free or a.locked or b.locked) return false;
    if (a.huge_pages != 0 or b.huge_pages != 0) return false;
    return a.prot == b.prot and a.shared == b.shared and a.may_write == b.may_write;
}
