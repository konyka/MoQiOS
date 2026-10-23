//! Byte-addressed read access to a volume, shared by the read-only ext4 and
//! NTFS parsers. The parsers never touch a driver: the kernel supplies a
//! Reader backed by a block device (with its own cache), host tests supply
//! one backed by an image file.

pub const Reader = struct {
    ctx: *anyopaque,
    /// Fill `buf` from byte `offset` of the volume. False on any I/O error or
    /// when the range lies outside the volume.
    read_fn: *const fn (ctx: *anyopaque, offset: u64, buf: []u8) bool,

    pub fn read(self: Reader, offset: u64, buf: []u8) bool {
        return self.read_fn(self.ctx, offset, buf);
    }
};

pub const FileKind = enum(u8) { unknown = 0, regular = 1, directory = 2, symlink = 3, other = 4 };

/// Result of a stat on a volume object (mode carries the S_IF* type bits).
pub const Stat = struct {
    ino: u64 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u32 = 1,
    size: u64 = 0,
    /// 512-byte units.
    blocks: u64 = 0,
    atime: u64 = 0,
    mtime: u64 = 0,
    ctime: u64 = 0,
};

pub const S_IFMT: u32 = 0o170000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFLNK: u32 = 0o120000;

pub const MAX_NAME: usize = 255;

/// One directory entry produced by a volume's iterator.
pub const DirEntry = struct {
    ino: u64 = 0,
    kind: FileKind = .unknown,
    name_len: u16 = 0,
    /// UTF-8, not NUL terminated.
    name: [MAX_NAME]u8 = undefined,

    pub fn nameSlice(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Linux d_type values for getdents64.
pub fn dType(kind: FileKind) u8 {
    return switch (kind) {
        .regular => 8,
        .directory => 4,
        .symlink => 10,
        else => 0,
    };
}
