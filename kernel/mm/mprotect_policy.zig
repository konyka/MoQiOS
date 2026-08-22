// Pure bounds for the mprotect transaction. The arrays live on the kernel
// stack, so rejecting oversized transactions is part of the safety contract.
pub const MAX_PARTIAL_HUGE_DEMOTIONS: u32 = 64;
pub const MAX_COW_COPIES: u32 = 256;

pub fn supported(huge_demotions: u32, cow_copies: u32) bool {
    return huge_demotions <= MAX_PARTIAL_HUGE_DEMOTIONS and
        cow_copies <= MAX_COW_COPIES;
}
