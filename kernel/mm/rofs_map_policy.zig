//! Admission and sizing rules for mmap of a file on a mounted ext4/NTFS
//! volume. Pure, so it is host-tested.
//!
//! Volume files are mapped by copying their pages into private frames at
//! mmap time (the volume lock can sleep and the page-fault path cannot), so
//! the mapping is bounded and behaves like a private anonymous mapping
//! initialised from the file.

const std = @import("std");

pub const PAGE: u64 = 4096;
/// Longest mapping accepted: 32 MiB. Larger files can still be read().
pub const MAX_PAGES: u64 = 8192;

pub const Verdict = enum { ok, invalid, no_device, access, no_memory };

/// Decide whether `mmap(length, prot, shared, offset)` of a volume file may
/// proceed. Order follows Linux: a bad offset is EINVAL before anything else.
pub fn admit(is_dir: bool, offset: u64, length: u64, prot: u64, shared: bool) Verdict {
    if (offset % PAGE != 0) return .invalid;
    if (is_dir) return .no_device;
    // The volume is read-only: a shared writable mapping could never be
    // written back, which is what EACCES on a read-only descriptor means.
    if (shared and prot & 2 != 0) return .access;
    if (length > MAX_PAGES * PAGE) return .no_memory;
    return .ok;
}

pub fn pageCount(length: u64) u64 {
    return (length + PAGE - 1) / PAGE;
}

/// Bytes of page `index` of the mapping that come from the file; the rest of
/// the page is zero. Zero for pages wholly at or past the end of the file.
pub fn validBytes(file_size: u64, offset: u64, index: u64) u32 {
    const step = std.math.mul(u64, index, PAGE) catch return 0;
    const off = std.math.add(u64, offset, step) catch return 0;
    if (off >= file_size) return 0;
    return @intCast(@min(PAGE, file_size - off));
}
