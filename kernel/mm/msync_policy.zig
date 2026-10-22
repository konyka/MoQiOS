//! Pure msync(2) argument rules (Linux).

pub const MS_ASYNC: u32 = 1;
pub const MS_INVALIDATE: u32 = 2;
pub const MS_SYNC: u32 = 4;

pub const EINVAL: i64 = -22;

/// Validate addr/flags; null means OK. MS_SYNC and MS_ASYNC together, any
/// unknown bit, or an unaligned address are EINVAL.
pub fn validate(addr: u64, flags: u32) ?i64 {
    if (addr & 0xFFF != 0) return EINVAL;
    if (flags & ~(MS_ASYNC | MS_INVALIDATE | MS_SYNC) != 0) return EINVAL;
    if (flags & MS_ASYNC != 0 and flags & MS_SYNC != 0) return EINVAL;
    return null;
}

/// Page count covered by [addr, addr + length), or null on overflow.
pub fn pageSpan(addr: u64, length: u64) ?u64 {
    const len_up = (length +% 0xFFF) & ~@as(u64, 0xFFF);
    if (len_up < length) return null;
    if (addr +% len_up < addr) return null;
    return len_up / 0x1000;
}
