//! Legacy virtio-PCI virtqueue memory layout (virtio 0.9.5 / spec 2.6.2), as pure arithmetic so the host tests can
//! check it for every queue size the device may offer.
//!
//! A legacy device is given ONE physical address (the queue PFN) and finds the three rings at fixed offsets from
//! it: the descriptor table first, the available ring right after it, and the used ring at the next 4 KiB
//! boundary after the available ring. The memory must therefore be one physically contiguous block.

pub const PAGE: usize = 4096;

fn alignUp(n: usize) usize {
    return (n + PAGE - 1) / PAGE * PAGE;
}

/// Bytes of the descriptor table (16 bytes per entry).
pub fn descBytes(n: usize) usize {
    return 16 * n;
}

/// Offset of the available ring: it follows the descriptor table directly.
pub fn availOffset(n: usize) usize {
    return descBytes(n);
}

/// Bytes of the available ring: flags, idx, n entries of u16, used_event.
pub fn availBytes(n: usize) usize {
    return 6 + 2 * n;
}

/// Offset of the used ring: the next page boundary after the available ring.
pub fn usedOffset(n: usize) usize {
    return alignUp(availOffset(n) + availBytes(n));
}

/// Bytes of the used ring: flags, idx, n entries of {u32 id, u32 len}, avail_event.
pub fn usedBytes(n: usize) usize {
    return 6 + 8 * n;
}

/// Total contiguous bytes to hand the device, rounded up to whole pages.
pub fn totalBytes(n: usize) usize {
    return alignUp(usedOffset(n) + usedBytes(n));
}

pub fn totalPages(n: usize) usize {
    return totalBytes(n) / PAGE;
}

/// Whether `n` is a queue size the layout supports: a power of two, between 1 and `max`.
pub fn sizeSupported(n: usize, max: usize) bool {
    if (n == 0 or n > max) return false;
    return n & (n - 1) == 0;
}
