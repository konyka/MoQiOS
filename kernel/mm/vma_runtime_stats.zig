//! Runtime counters for fixed-table VMA scans.

const model = @import("vma_stats.zig");

var scan_count: u64 = 0;
var visited_slots: u64 = 0;

pub fn recordScan(active_mask: u64) void {
    _ = @atomicRmw(u64, &scan_count, .Add, 1, .monotonic);
    _ = @atomicRmw(u64, &visited_slots, .Add, model.visitedSlots(active_mask), .monotonic);
}

pub fn snapshot() struct { scans: u64, slots: u64, visited_slots: u64 } {
    const scans = @atomicLoad(u64, &scan_count, .monotonic);
    return .{
        .scans = scans,
        .slots = scans * model.MAX_REGIONS,
        .visited_slots = @atomicLoad(u64, &visited_slots, .monotonic),
    };
}
