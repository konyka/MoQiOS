// Pure bounds for the mprotect transaction. The arrays live on the kernel
// stack, so rejecting oversized transactions is part of the safety contract.
pub const MAX_PARTIAL_HUGE_DEMOTIONS: u32 = 64;
pub const MAX_COW_COPIES: u32 = 256;

pub const PAGE_SIZE: u64 = 4096;

/// Pages touched by a range of `len` bytes — ceil(len/PAGE_SIZE), computed
/// without an overflowing len + PAGE_SIZE - 1 intermediate. Both the PTE
/// rewrite and the TLB shootdown must cover exactly this many pages.
pub fn pageCount(len: u64) u64 {
    return len / PAGE_SIZE + @intFromBool(len % PAGE_SIZE != 0);
}

pub fn supported(huge_demotions: u32, cow_copies: u32) bool {
    return huge_demotions <= MAX_PARTIAL_HUGE_DEMOTIONS and
        cow_copies <= MAX_COW_COPIES;
}

pub const CowCommitAction = enum { consume, defer_to_fault };

/// The commit loop re-reads each COW PTE after preflight reserved exactly
/// `reserved` data pages for the frames it counted as shared. A concurrent
/// fork/clone COW between the two phases can bump a sole-owned frame's
/// refcount 1→2, so commit may meet more shared frames than it reserved.
/// With the reservation exhausted, granting write is not an option: the PTE
/// keeps its COW bit and stays non-writable, so the next write faults and
/// unshares via the fault path (commit allocates nothing, so this degrade
/// cannot fail).
pub fn cowCommitAction(reserved: u32, used: u32) CowCommitAction {
    return if (used < reserved) .consume else .defer_to_fault;
}

/// mprotect on a swap entry (non-present PTE with the bit-1 swap marker, see
/// mm/swap.zig): the frame lives on disk, so the generic present/writable/NX
/// rewrite would destroy the entry — `present = true` would reinterpret the
/// swap slot as a physical address, and clearing bit 1 would erase the marker
/// (hello96 RED: mprotect on a swapped page → later fault finds neither a
/// present page nor a swap entry → spurious SIGSEGV). Only the preserved
/// permission bits may move: writable at bit 2, NX at bit 63; the COW-
/// preserved bit 3 and the slot bits pass through. Returns the updated entry,
/// or null when `pte` is not a swap entry (caller takes the normal path).
/// PROT_NONE needs no change: the entry is already not-present, and a later
/// PROT_READ update still finds the swap slot.
pub fn swapEntryUpdate(pte: u64, prot: u64) ?u64 {
    if ((pte & 1) != 0 or (pte & 0x2) == 0) return null; // present, or no marker
    if (prot == 0) return pte; // PROT_NONE: already not-present
    var e = pte;
    if ((prot & 2) != 0) e |= @as(u64, 1) << 2 else e &= ~(@as(u64, 1) << 2);
    if ((prot & 4) != 0) e &= ~(@as(u64, 1) << 63) else e |= @as(u64, 1) << 63;
    return e;
}
