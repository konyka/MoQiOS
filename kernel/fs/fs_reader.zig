//! Byte-addressed read access to a volume, shared by the read-only ext4 and
//! NTFS parsers. The parsers never touch a driver: the kernel supplies a
//! Reader backed by a block device (with its own cache), host tests supply
//! one backed by an image file.

const std = @import("std");

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

/// Filesystem-wide statistics for statfs(2). Block counts are in `block_size`
/// units; `bavail` is what an unprivileged user may still allocate.
pub const FsStat = struct {
    magic: u32 = 0,
    block_size: u32 = 0,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
    name_max: u32 = 255,
    fsid: u64 = 0,
};

pub const ST_RDONLY: u64 = 1;
pub const STATFS_SIZE: usize = 120;

/// Linux x86_64 `struct statfs`. The volumes are always mounted read-only.
pub fn encodeStatfs(st: FsStat, out: *[STATFS_SIZE]u8) void {
    @memset(out, 0);
    const w = std.mem.writeInt;
    w(u64, out[0..8], st.magic, .little);
    w(u64, out[8..16], st.block_size, .little);
    w(u64, out[16..24], st.blocks, .little);
    w(u64, out[24..32], st.bfree, .little);
    w(u64, out[32..40], st.bavail, .little);
    w(u64, out[40..48], st.files, .little);
    w(u64, out[48..56], st.ffree, .little);
    w(u64, out[56..64], st.fsid, .little);
    w(u64, out[64..72], st.name_max, .little);
    w(u64, out[72..80], st.block_size, .little);
    w(u64, out[80..88], ST_RDONLY, .little);
}
