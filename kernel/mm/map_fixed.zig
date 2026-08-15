// kernel/mm/map_fixed.zig -- Pure policy for bounded MAP_FIXED replacement.
//
// Keep this module import-free so host tests can pin the transaction boundary
// without pulling paging or the physical-memory manager into the test binary.

/// A transaction keeps old and new frame lists on the kernel stack. This cap
/// consumes 2 KiB for the two u64 lists, leaving ample room on a 128 KiB stack.
pub const MAX_ANON_REPLACEMENT_PAGES: u64 = 128;

pub fn pageCountSupported(num_pages: u64) bool {
    return num_pages != 0 and num_pages <= MAX_ANON_REPLACEMENT_PAGES;
}

/// Return the post-replacement ledger charge when it is representable and does
/// not exceed the soft limit. A null result means the transaction must not
/// begin, because it cannot settle accounting without losing the old mapping.
pub fn chargeAfterReplacement(used: u64, old_charge: u64, new_charge: u64, soft_limit: u64) ?u64 {
    if (old_charge > used) return null;
    const retained = used - old_charge;
    const result, const overflow = @addWithOverflow(retained, new_charge);
    if (overflow != 0) return null;
    if (soft_limit != 0xFFFF_FFFF_FFFF_FFFF and result > soft_limit) return null;
    return result;
}
