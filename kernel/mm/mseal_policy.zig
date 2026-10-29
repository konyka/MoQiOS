//! Pure rules for mseal(2): argument checks and a bounded table of sealed
//! ranges. A sealed range may not be unmapped, remapped, re-protected or
//! replaced by MAP_FIXED for the rest of the address space's life.

pub const MAX_SEALS: usize = 32;
const PAGE: u64 = 4096;

/// 0 when the call is well-formed, else a negative errno.
pub fn validate(addr: u64, len: u64, flags: u64) i64 {
    if (flags != 0) return -22;
    if (addr % PAGE != 0) return -22;
    if (len == 0) return 0;
    const rounded = (len + PAGE - 1) & ~(PAGE - 1);
    if (rounded < len) return -22;
    if (addr +% rounded < addr) return -22;
    return 0;
}

pub fn roundLen(len: u64) u64 {
    return (len + PAGE - 1) & ~(PAGE - 1);
}

pub const Range = struct { base: u64 = 0, len: u64 = 0 };

pub const Table = struct {
    ranges: [MAX_SEALS]Range = [_]Range{.{}} ** MAX_SEALS,
    count: usize = 0,

    /// Whether [base, base+len) touches any sealed range.
    pub fn overlaps(self: *const Table, base: u64, len: u64) bool {
        if (len == 0) return false;
        const end = base +| len;
        for (self.ranges[0..self.count]) |r| {
            if (base < r.base + r.len and r.base < end) return true;
        }
        return false;
    }

    /// Record a sealed range. A range already fully covered by one seal is
    /// a no-op. False when the table is full.
    pub fn add(self: *Table, base: u64, len: u64) bool {
        for (self.ranges[0..self.count]) |r| {
            if (base >= r.base and base + len <= r.base + r.len) return true;
        }
        if (self.count == MAX_SEALS) return false;
        self.ranges[self.count] = .{ .base = base, .len = len };
        self.count += 1;
        return true;
    }
};

/// MADV_DONTNEED / MADV_FREE on a sealed page: Linux refuses (EPERM) when
/// the page is private anonymous and not writable, since discarding it
/// would change contents the caller could not otherwise change.
pub fn discardBlocked(sealed: bool, anonymous: bool, writable: bool) bool {
    return sealed and anonymous and !writable;
}
