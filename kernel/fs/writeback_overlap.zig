//! Pure arithmetic for serving a read from a staged writeback extent.
//!
//! Extents are keyed by their start offset, but a read can begin anywhere:
//! in the middle of an extent, before one and running into it, or across the
//! end. Only an exact-start lookup used to hit, so pread() of data written a
//! moment earlier returned the stale on-disk bytes (or nothing).

pub const Extent = struct { offset: u64, len: u32 };

/// How a read window [read_off, read_off+read_len) intersects an extent:
/// copy `copy` bytes from extent byte `skip` into the destination at `dst`.
pub const Hit = struct { skip: u32, copy: u32, dst: u32 };

pub fn overlap(e: Extent, read_off: u64, read_len: u32) ?Hit {
    if (read_len == 0 or e.len == 0) return null;
    const e_end = e.offset +| @as(u64, e.len);
    const r_end = read_off +| @as(u64, read_len);
    const lo = @max(e.offset, read_off);
    const hi = @min(e_end, r_end);
    if (lo >= hi) return null;
    return .{
        .skip = @intCast(lo - e.offset),
        .copy = @intCast(hi - lo),
        .dst = @intCast(lo - read_off),
    };
}
