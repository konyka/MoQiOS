// kernel/mm/cow_pte.zig — page-table entry derivation for copy-on-write clones
//
// Deliberately free of imports so the host test runner can exercise it.

/// Write permission — cleared on both sides of a COW share so the next write
/// faults.
pub const WRITABLE: u64 = 1 << 1;

/// COW marker. Bit 9 is one of the entry's available bits, so hardware ignores
/// it and the page-fault handler can recognise a shared page by it.
pub const COW: u64 = 1 << 9;

/// Bit 63 — no-execute. It sits *above* the address field rather than among the
/// low permission bits, which is why deriving a child entry as
/// `phys | (pte & 0xFFF)` silently dropped it and handed every forked child an
/// executable stack and heap.
pub const NO_EXECUTE: u64 = 1 << 63;

/// The entry both sides of a copy-on-write share must hold: the parent's frame
/// and permissions, minus write access, plus the COW marker.
///
/// Parent and child get the same entry, so they derive it from the same place.
/// Reconstructing the child's from its parts is what lost NX.
pub fn cowPte(parent_pte: u64) u64 {
    return (parent_pte & ~WRITABLE) | COW;
}

/// Whether an entry already describes a COW share, meaning the parent side has
/// been downgraded by an earlier clone and needs no second TLB invalidation.
pub fn isCow(pte: u64) bool {
    return pte & COW != 0;
}
