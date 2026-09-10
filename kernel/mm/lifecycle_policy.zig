/// Pure address-space lifecycle decisions shared by clone and exec paths.
pub const CLONE_VM: u64 = 0x100;
pub const EINVAL: i64 = -22;
pub const EPERM: i64 = -1;

/// A shared address space is valid only when the parent supplies its Mm owner.
pub fn cloneVmResult(flags: u64, parent_has_mm: bool) i64 {
    if (flags & CLONE_VM != 0 and !parent_has_mm) return EINVAL;
    return 0;
}

/// Threaded tasks cannot replace an address space while siblings still run.
/// The same holds for a shared (CLONE_VM, refs > 1) Mm without CLONE_THREAD:
/// exec teardown would race siblings still faulting/unmapping in it.
pub fn execResult(is_thread: bool, mm_shared: bool) i64 {
    return if (is_thread or mm_shared) EPERM else 0;
}
