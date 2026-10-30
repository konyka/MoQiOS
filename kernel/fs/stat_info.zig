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
    /// 512-byte sectors allocated (ext2 i_blocks already counts in 512 B).
    blocks: u64 = 0,
    atime: u64 = 0,
    mtime: u64 = 0,
    ctime: u64 = 0,
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
    blocks: u32 = 0,
    atime: u32 = 0,
    mtime: u32 = 0,
    ctime: u32 = 0,
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
        .blocks = raw.blocks,
        .atime = raw.atime,
        .mtime = raw.mtime,
        .ctime = raw.ctime,
    };
}

// ── statx(2) ────────────────────────────────────────────────────────────────

pub const STATX_TYPE: u32 = 0x1;
pub const STATX_MODE: u32 = 0x2;
pub const STATX_NLINK: u32 = 0x4;
pub const STATX_UID: u32 = 0x8;
pub const STATX_GID: u32 = 0x10;
pub const STATX_ATIME: u32 = 0x20;
pub const STATX_MTIME: u32 = 0x40;
pub const STATX_CTIME: u32 = 0x80;
pub const STATX_INO: u32 = 0x100;
pub const STATX_SIZE: u32 = 0x200;
pub const STATX_BLOCKS: u32 = 0x400;
pub const STATX_ALL_KNOWN: u32 = 0x7FF;

pub const AT_SYMLINK_NOFOLLOW: u32 = 0x100;
pub const AT_STATX_SYNC_TYPE: u32 = 0x6000; // sync-type bits: accepted, no effect here
pub const AT_NO_AUTOMOUNT: u32 = 0x800;
pub const AT_EMPTY_PATH: u32 = 0x1000;

pub const Times = struct { atime: u64, mtime: u64, ctime: u64 };

/// What statx reports about one file. `times` / `blocks` are null when the
/// filesystem does not keep them; the mask then leaves those bits out and the
/// bytes stay zero instead of claiming "0 seconds since 1970".
pub const Common = struct {
    mode: u32,
    nlink: u32 = 1,
    uid: u32 = 0,
    gid: u32 = 0,
    ino: u64 = 0,
    size: u64 = 0,
    blocks: ?u64 = null,
    times: ?Times = null,
};

fn put32(b: []u8, o: usize, v: u32) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
    b[o + 2] = @truncate(v >> 16);
    b[o + 3] = @truncate(v >> 24);
}
fn put64(b: []u8, o: usize, v: u64) void {
    put32(b, o, @truncate(v));
    put32(b, o + 4, @truncate(v >> 32));
}

/// Lay `c` out as struct statx (144 bytes): mask@0 blksize@4 attributes@8
/// nlink@16 uid@20 gid@24 mode@28 ino@32 size@40 blocks@48 attr_mask@56
/// atime@64 btime@80 ctime@96 mtime@112 (tv_sec, tv_nsec, pad).
pub fn packStatx(out: *[144]u8, c: Common) void {
    @memset(out, 0);
    var mask: u32 = STATX_TYPE | STATX_MODE | STATX_NLINK | STATX_UID | STATX_GID | STATX_INO | STATX_SIZE;
    put32(out, 4, 4096);
    put32(out, 16, c.nlink);
    put32(out, 20, c.uid);
    put32(out, 24, c.gid);
    out[28] = @truncate(c.mode);
    out[29] = @truncate(c.mode >> 8);
    put64(out, 32, c.ino);
    put64(out, 40, c.size);
    if (c.blocks) |b| {
        put64(out, 48, b);
        mask |= STATX_BLOCKS;
    }
    if (c.times) |t| {
        put64(out, 64, t.atime);
        put64(out, 96, t.ctime);
        put64(out, 112, t.mtime);
        mask |= STATX_ATIME | STATX_CTIME | STATX_MTIME;
    }
    put32(out, 0, mask);
}

pub const StatxArgs = struct {
    err: i64 = 0,
    empty_path: bool = false,
    follow: bool = true,

    pub fn err_or_zero(self: StatxArgs) i64 {
        return self.err;
    }
};

/// statx flag / mask validation. Unknown flag bits and the reserved mask bit
/// (STATX__RESERVED = 0x80000000) are EINVAL.
pub fn checkStatxArgs(flags: u32, mask: u32) StatxArgs {
    const known = AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT | AT_EMPTY_PATH | AT_STATX_SYNC_TYPE;
    if ((flags & ~known) != 0 or (mask & 0x8000_0000) != 0) return .{ .err = -22 };
    return .{ .empty_path = (flags & AT_EMPTY_PATH) != 0, .follow = (flags & AT_SYMLINK_NOFOLLOW) == 0 };
}
