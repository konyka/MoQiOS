//! Pure memfd_create(2) argument rules.

pub const MFD_CLOEXEC: u32 = 0x0001;
pub const MFD_ALLOW_SEALING: u32 = 0x0002;
pub const MFD_HUGETLB: u32 = 0x0004;

/// Accepted flags. MFD_HUGETLB (and its size bits) needs hugetlbfs, which
/// does not exist here: EINVAL.
pub fn flagsValid(flags: u32) bool {
    return flags & ~(MFD_CLOEXEC | MFD_ALLOW_SEALING) == 0;
}

/// Linux limits the name to 249 bytes (NAME_MAX minus the "memfd:" prefix).
pub fn nameLenValid(len: usize) bool {
    return len <= 249;
}

// ── File seals (fcntl F_ADD_SEALS / F_GET_SEALS) ──────────────────────

pub const F_SEAL_SEAL: u32 = 0x0001;
pub const F_SEAL_SHRINK: u32 = 0x0002;
pub const F_SEAL_GROW: u32 = 0x0004;
pub const F_SEAL_WRITE: u32 = 0x0008;
pub const F_SEAL_FUTURE_WRITE: u32 = 0x0010;
const ALL_SEALS: u32 = F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_FUTURE_WRITE;

/// Without MFD_ALLOW_SEALING a memfd is born with F_SEAL_SEAL (Linux).
pub fn initialSeals(mfd_flags: u32) u32 {
    return if (mfd_flags & MFD_ALLOW_SEALING != 0) 0 else F_SEAL_SEAL;
}

pub const AddResult = union(enum) { ok: u32, eperm, einval, ebusy };

pub fn addSeals(current: u32, add: u32) AddResult {
    if (add & ~ALL_SEALS != 0) return .einval;
    if (current & F_SEAL_SEAL != 0) return .eperm;
    return .{ .ok = current | add };
}

/// A write of `count` bytes at `offset` on a file of `size` bytes.
/// F_SEAL_FUTURE_WRITE forbids write(2) like F_SEAL_WRITE.
pub fn writeAllowed(seals: u32, offset: u64, count: u64, size: u64) bool {
    if (seals & (F_SEAL_WRITE | F_SEAL_FUTURE_WRITE) != 0 and count > 0) return false;
    if (seals & F_SEAL_GROW != 0 and offset + count > size) return false;
    return true;
}

pub fn truncateAllowed(seals: u32, new_size: u64, size: u64) bool {
    if (new_size < size and seals & F_SEAL_SHRINK != 0) return false;
    if (new_size > size and seals & F_SEAL_GROW != 0) return false;
    return true;
}

/// mmap of a sealed file: a new MAP_SHARED mapping with PROT_WRITE is
/// refused under WRITE or FUTURE_WRITE (EPERM). Private mappings are COW and
/// never write the file, so they stay allowed.
pub fn mmapAllowed(seals: u32, shared: bool, writable: bool) bool {
    if (!shared or !writable) return true;
    return seals & (F_SEAL_WRITE | F_SEAL_FUTURE_WRITE) == 0;
}

/// Whether a mapping may ever be made writable by mprotect (Linux clears
/// VM_MAYWRITE on shared mappings of write-sealed files). `fd_writable` is
/// the descriptor's write access; private mappings are COW and unaffected.
pub fn mapMayWrite(seals: u32, shared: bool, fd_writable: bool) bool {
    if (!shared) return true;
    return fd_writable and seals & (F_SEAL_WRITE | F_SEAL_FUTURE_WRITE) == 0;
}

/// F_ADD_SEALS when `shared_writable_maps` shared writable mappings exist:
/// F_SEAL_WRITE would be bypassed through them, so it is EBUSY (Linux);
/// F_SEAL_FUTURE_WRITE only stops new writers and is allowed.
pub fn addSealsMapped(current: u32, add: u32, shared_writable_maps: u32) AddResult {
    const r = addSeals(current, add);
    if (r == .ok and add & F_SEAL_WRITE != 0 and shared_writable_maps != 0) return .ebusy;
    return r;
}
