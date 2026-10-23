//! Which syscalls mutate the namespace or file metadata by PATH, and in which
//! argument registers their path operands live. A single check before
//! dispatch turns every such call on a read-only volume into EROFS, instead
//! of each handler (or the flat filesystems behind them) having to know about
//! mounted volumes.
//!
//! Operands are named by register index: 0 = rdi, 1 = rsi, 2 = rdx, 3 = r10,
//! 4 = r8, 5 = r9. `none` means the slot holds no path.

pub const NONE: u8 = 0xFF;

pub const Entry = struct {
    nr: u64,
    a: u8,
    b: u8 = NONE,
};

pub const table = [_]Entry{
    .{ .nr = 76, .a = 0 }, // truncate (MoQiOS-native numbering)
    .{ .nr = 82, .a = 0, .b = 1 }, // rename
    .{ .nr = 83, .a = 0 }, // mkdir
    .{ .nr = 84, .a = 0 }, // rmdir
    .{ .nr = 85, .a = 0 }, // creat
    .{ .nr = 86, .a = 0, .b = 1 }, // link
    .{ .nr = 87, .a = 0 }, // unlink
    .{ .nr = 88, .a = 1 }, // symlink (only linkpath is created; target is data)
    .{ .nr = 90, .a = 0 }, // chmod
    .{ .nr = 92, .a = 0 }, // chown
    .{ .nr = 94, .a = 0 }, // lchown
    .{ .nr = 210, .a = 0 }, // truncate
    .{ .nr = 212, .a = 0, .b = 1 }, // rename
    .{ .nr = 257, .a = 1 }, // mkdirat
    .{ .nr = 260, .a = 1 }, // fchmodat
    .{ .nr = 261, .a = 1, .b = 3 }, // renameat2
    .{ .nr = 329, .a = 0, .b = 1 }, // link
    .{ .nr = 330, .a = 1 }, // symlink
    .{ .nr = 463, .a = 1 }, // setxattrat
    .{ .nr = 466, .a = 1 }, // removexattrat
};

pub fn lookup(nr: u64) ?Entry {
    for (table) |e| {
        if (e.nr == nr) return e;
    }
    return null;
}
