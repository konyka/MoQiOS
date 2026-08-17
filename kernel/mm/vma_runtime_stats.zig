//! Runtime counters for fixed-table VMA scans.

const model = @import("vma_stats.zig");

var scan_count: u64 = 0;

pub fn recordScan(active_count: u64) void {
    _ = active_count;
    _ = @atomicRmw(u64, &scan_count, .Add, 1, .monotonic);
}

pub fn snapshot() struct { scans: u64, slots: u64 } {
    const scans = @atomicLoad(u64, &scan_count, .monotonic);
    return .{
        .scans = scans,
        .slots = scans * model.MAX_REGIONS,
    };
}
