//! Pure stat-field policy shared by fstat/statx: on-disk ext2 inode fields
//! → Linux struct stat / struct statx values. No arch/driver imports so the
//! mapping can be host-tested.

pub const S_IFMT: u32 = 0o170000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFDIR: u32 = 0o040000;

/// Snapshot of the authoritative inode metadata for one open file.
pub const StatInfo = struct {
    ino: u64 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u32 = 0,
    size: u64 = 0,
};

/// Raw ext2 inode fields needed for stat (base inode + osd2/dir_acl high
/// halves, as laid out by the Linux ext2 driver).
pub const Ext2Raw = struct {
    mode: u16,
    uid_lo: u16,
    uid_hi: u16,
    gid_lo: u16,
    gid_hi: u16,
    links_count: u16,
    size_lo: u32,
    size_hi: u32,
};

/// ext2 i_mode already uses the POSIX S_IF* encoding; keep type + permission
/// bits verbatim. A corrupt inode with no type bits is reported as regular.
pub fn ext2StMode(i_mode: u16) u32 {
    const m: u32 = i_mode;
    if (m & S_IFMT == 0) return S_IFREG | (m & 0o7777);
    return m & (S_IFMT | 0o7777);
}

/// i_size_high (stored in i_dir_acl) only extends regular-file sizes.
pub fn ext2Size(i_mode: u16, size_lo: u32, size_hi: u32) u64 {
    const m: u32 = i_mode;
    if (m & S_IFMT == S_IFREG) return (@as(u64, size_hi) << 32) | size_lo;
    return size_lo;
}

pub fn ext2Id(lo: u16, hi: u16) u32 {
    return (@as(u32, hi) << 16) | lo;
}

pub fn fromExt2(inode_num: u32, raw: Ext2Raw) StatInfo {
    return .{
        .ino = inode_num,
        .mode = ext2StMode(raw.mode),
        .uid = ext2Id(raw.uid_lo, raw.uid_hi),
        .gid = ext2Id(raw.gid_lo, raw.gid_hi),
        .nlink = raw.links_count,
        .size = ext2Size(raw.mode, raw.size_lo, raw.size_hi),
    };
}
