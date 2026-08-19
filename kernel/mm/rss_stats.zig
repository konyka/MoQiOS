//! Pure helpers for observation-only resident user-page telemetry.

pub const PAGE_BYTES: u64 = 4096;
pub const HUGE_2MB_PAGES: u64 = 512;

pub fn bytesForPages(pages: u64) u64 {
    return pages * PAGE_BYTES;
}

pub fn kibForPages(pages: u64) u64 {
    return pages * 4;
}

pub fn addLeafPages(total: u64, present_user: bool, huge_2mb: bool) u64 {
    if (!present_user) return total;
    return total + if (huge_2mb) HUGE_2MB_PAGES else 1;
}
