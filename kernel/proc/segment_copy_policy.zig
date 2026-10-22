//! Pure per-page ELF segment copy window.
//!
//! A PT_LOAD whose p_vaddr is not page aligned starts `poff` bytes into its
//! first page; the bytes that fit there are PAGE_SIZE - poff, not PAGE_SIZE.
//! The next page's file offset already accounts for the shift (it is derived
//! from page_vaddr - seg_vaddr), so clamping loses nothing.

pub const PAGE_SIZE: u64 = 4096;

pub const Window = struct {
    /// Offset into the destination page.
    page_off: u64,
    /// Bytes to copy from the file.
    len: u64,
    /// Offset of the first byte within the segment's file image.
    file_off: u64,
};

/// Copy window for the page starting at `page_vaddr` of a segment at
/// `seg_vaddr` with `seg_filesz` file bytes; null when the page holds none.
pub fn window(page_vaddr: u64, seg_vaddr: u64, seg_filesz: u64) ?Window {
    const ps = page_vaddr -| seg_vaddr;
    const fcs = @min(ps, seg_filesz);
    const fce = @min(ps +| PAGE_SIZE, seg_filesz);
    if (fce <= fcs) return null;
    const poff: u64 = if (page_vaddr < seg_vaddr) seg_vaddr - page_vaddr else 0;
    if (poff >= PAGE_SIZE) return null;
    return .{ .page_off = poff, .len = @min(fce - fcs, PAGE_SIZE - poff), .file_off = fcs };
}
