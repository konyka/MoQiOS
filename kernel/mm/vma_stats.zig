//! Pure statistics for the fixed-size mmap_regions VMA table.

pub const MAX_REGIONS: u64 = 64;

pub const ScanCost = struct {
    slots_scanned: u64,
    active_seen: u64,
};

/// A table scan always visits every fixed slot, while active entries are
/// bounded by the table capacity.
pub fn scanCost(active_count: u64) ScanCost {
    return .{
        .slots_scanned = MAX_REGIONS,
        .active_seen = if (active_count < MAX_REGIONS) active_count else MAX_REGIONS,
    };
}

/// Return the average number of slots scanned per scan. An empty sample has
/// no measured cost.
pub fn avgCost(total_scans: u64, total_slots: u64) u64 {
    if (total_scans == 0) return 0;
    return total_slots / total_scans;
}
