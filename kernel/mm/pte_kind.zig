//! Non-present PTE classification — the single source of truth for the
//! bit-level encodings of user page-table entries that are NOT present.
//!
//! Taxonomy (x86_64; a non-present entry's bits are OS-defined):
//!   - free:      the raw entry is 0 — no frame, no slot, address is reusable.
//!   - swap:      bit 11 marker. Bit 2 preserves writable, bit 3 preserves
//!                COW, bits 12-51 hold the swap slot, bit 63 preserves NX.
//!                Written by swap.zig's swapOut; the frame lives on disk.
//!   - prot_none: bit 10 marker. mprotect(PROT_NONE) clears present but keeps
//!                the physical frame and the original permission bits so a
//!                later mprotect can restore the mapping in place. Any access
//!                must SIGSEGV — the frame must NOT be faulted back in.
//!   - unknown:   non-present, non-zero, neither marker. No producer in the
//!                tree writes these; fault paths treat them as SIGSEGV.
//!
//! Bits 9-11 are the OS-available PTE bits; bit 9 is the COW marker
//! (cow_pte.zig), bits 10/11 are claimed above. The pre-§6.48 swap encoding
//! used bit 1 as its marker — which a PROT_NONE reservation of a formerly
//! writable page also has set, so fault paths mistook the reservation for a
//! swap entry and "swapped in" a disk page indexed by the frame number
//! (silent data corruption), and mprotect's swapEntryUpdate hijacked every
//! PROT_NONE → PROT_RW restore. Keeping the two encodings on disjoint
//! dedicated bits closes both.

pub const PRESENT: u64 = 1 << 0;
pub const PROT_NONE_MARKER: u64 = 1 << 10; // OS-available bit 10
pub const SWAP_MARKER: u64 = 1 << 11; // OS-available bit 11

pub const Kind = enum { present, free, swap, prot_none, unknown };

pub fn classify(pte: u64) Kind {
    if (pte & PRESENT != 0) return .present;
    if (pte == 0) return .free;
    if (pte & SWAP_MARKER != 0) return .swap;
    if (pte & PROT_NONE_MARKER != 0) return .prot_none;
    return .unknown;
}

/// What tearing down a mapped-then-removed PTE must reclaim (§6.49).
/// munmap/exit used to consult only the present bit, so the two non-present
/// resource-holding encodings leaked: a reservation's frame and a swap
/// entry's slot were never returned.
pub const TeardownAction = enum {
    /// free/unknown: the entry holds neither a frame nor a slot.
    none,
    /// present or prot_none: the entry pins a physical frame — drop one
    /// reference (pmm.freePage: decRef, free at zero). A reservation frame
    /// can still be COW-shared: fork addRefs only present entries, but a
    /// page forked while present and PROT_NONE'd afterwards keeps the
    /// child's reference, so an unconditional free would corrupt the sharer.
    free_frame,
    /// swap: the entry holds a swap slot but no frame — free the slot.
    /// fork never copies non-present entries, so a slot has exactly one
    /// owning PTE and teardown frees it exactly once.
    free_slot,
};

pub fn teardownAction(pte: u64) TeardownAction {
    return switch (classify(pte)) {
        .present, .prot_none => .free_frame,
        .swap => .free_slot,
        .free, .unknown => .none,
    };
}

/// Encode a swap slot index into a PTE swap entry.
pub fn encodeSwapEntry(slot: u64) u64 {
    return SWAP_MARKER | (slot << 12);
}

/// Extract the swap slot index from a PTE swap entry.
pub fn decodeSwapEntry(pte: u64) u64 {
    return (pte >> 12) & 0xF_FFFF_FFFF; // 40 bits
}

