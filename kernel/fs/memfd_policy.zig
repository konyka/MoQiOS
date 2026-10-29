//! Pure memfd_create(2) argument rules.

pub const MFD_CLOEXEC: u32 = 0x0001;
pub const MFD_ALLOW_SEALING: u32 = 0x0002;
pub const MFD_HUGETLB: u32 = 0x0004;

/// Accepted flags. MFD_HUGETLB (and its size bits) needs hugetlbfs, which
/// does not exist here: EINVAL. MFD_ALLOW_SEALING is accepted; seals are not
/// implemented, so F_ADD_SEALS still fails (fcntl reports EINVAL).
pub fn flagsValid(flags: u32) bool {
    return flags & ~(MFD_CLOEXEC | MFD_ALLOW_SEALING) == 0;
}

/// Linux limits the name to 249 bytes (NAME_MAX minus the "memfd:" prefix).
pub fn nameLenValid(len: usize) bool {
    return len <= 249;
}
