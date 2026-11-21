//! madvise(MADV_DONTFORK / MADV_DOFORK / MADV_WIPEONFORK / MADV_KEEPONFORK) on pages no mmap region tracks: the brk heap and the
//! stack (Linux keeps those in vmas too, so the marks work there; the program image is file-backed, so WIPEONFORK is EINVAL on it,
//! DONTFORK is allowed). The marks are kept as page ranges per address space; a fork child skips DONTFORK pages and gets WIPEONFORK
//! ones zero-filled. Ranges with the same marks are merged; setting a mark on part of a range splits it.
const std = @import("std");

pub const MAX_RANGES: usize = 4;
pub const PAGE: u64 = 4096;

pub const Marks = packed struct(u8) {
    dontfork: bool = false,
    wipeonfork: bool = false,
    _pad: u6 = 0,

    fn none(m: Marks) bool {
        return !m.dontfork and !m.wipeonfork;
    }
};

/// A run of marked pages as page numbers (32 bits: user space ends below 2^44) so the table keeps Mm in its 1024-byte slab class.
pub const Range = struct { start_pg: u32 = 0, end_pg: u32 = 0, marks: Marks = .{} };

pub const Which = enum { dontfork, wipeonfork };

pub const Table = struct {
    ranges: [MAX_RANGES]Range = @splat(.{}),
    count: usize = 0,

    /// The marks of page `addr`.
    pub fn at(t: *const Table, addr: u64) Marks {
        const pg = addr / PAGE;
        for (t.ranges[0..t.count]) |r| {
            if (pg >= r.start_pg and pg < r.end_pg) return r.marks;
        }
        return .{};
    }

    /// Set (or clear) mark `which` on [start, end) (page-aligned). False when the table cannot hold the result (ENOMEM; nothing
    /// changed).
    pub fn set(t: *Table, start: u64, end: u64, which: Which, value: bool) bool {
        if (start >= end) return true;
        // Build the result page-boundary by page-boundary over the union of the old ranges' edges and the new one's.
        var edges: [2 * MAX_RANGES + 2]u64 = undefined;
        var ne: usize = 0;
        for (t.ranges[0..t.count]) |r| {
            edges[ne] = @as(u64, r.start_pg) * PAGE;
            edges[ne + 1] = @as(u64, r.end_pg) * PAGE;
            ne += 2;
        }
        edges[ne] = start;
        edges[ne + 1] = end;
        ne += 2;
        std.mem.sort(u64, edges[0..ne], {}, std.sort.asc(u64));
        var out: [2 * MAX_RANGES + 2]Range = undefined;
        var no: usize = 0;
        var i: usize = 0;
        while (i + 1 < ne) : (i += 1) {
            const a = edges[i];
            const b = edges[i + 1];
            if (a == b) continue;
            var m = t.at(a);
            if (a >= start and b <= end) {
                if (which == .dontfork) m.dontfork = value else m.wipeonfork = value;
            }
            if (m.none()) continue;
            if (no > 0 and @as(u64, out[no - 1].end_pg) * PAGE == a and @as(u8, @bitCast(out[no - 1].marks)) == @as(u8, @bitCast(m))) {
                out[no - 1].end_pg = @intCast(b / PAGE);
            } else {
                out[no] = .{ .start_pg = @intCast(a / PAGE), .end_pg = @intCast(b / PAGE), .marks = m };
                no += 1;
            }
        }
        if (no > MAX_RANGES) return false;
        @memcpy(t.ranges[0..no], out[0..no]);
        t.count = no;
        return true;
    }

    /// Forget [start, end) (the pages went away: munmap, brk shrink, exec).
    pub fn forget(t: *Table, start: u64, end: u64) void {
        _ = t.set(start, end, .dontfork, false);
        _ = t.set(start, end, .wipeonfork, false);
    }
};

test "marks split, merge and come back off" {
    var t: Table = .{};
    try std.testing.expect(t.set(0x10000, 0x14000, .wipeonfork, true));
    try std.testing.expect(t.at(0x11000).wipeonfork);
    try std.testing.expect(!t.at(0x14000).wipeonfork);
    try std.testing.expect(t.set(0x12000, 0x13000, .dontfork, true));
    try std.testing.expectEqual(@as(usize, 3), t.count);
    try std.testing.expect(t.at(0x12000).dontfork and t.at(0x12000).wipeonfork);
    try std.testing.expect(t.set(0x12000, 0x13000, .dontfork, false));
    try std.testing.expectEqual(@as(usize, 1), t.count);
    t.forget(0x10000, 0x14000);
    try std.testing.expectEqual(@as(usize, 0), t.count);
}

test "a full table refuses and keeps what it had" {
    var t: Table = .{};
    var i: u64 = 0;
    while (i < MAX_RANGES) : (i += 1) try std.testing.expect(t.set(i * 2 * PAGE, i * 2 * PAGE + PAGE, .dontfork, true));
    try std.testing.expect(!t.set(MAX_RANGES * 2 * PAGE, MAX_RANGES * 2 * PAGE + PAGE, .dontfork, true));
    try std.testing.expectEqual(MAX_RANGES, t.count);
}
