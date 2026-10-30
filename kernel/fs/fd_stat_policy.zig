//! Pure st_mode / st_nlink / st_ino for descriptors that are not files on a
//! disk filesystem (pipes, sockets, event objects, devices, the console).
//!
//! Disk-backed descriptors (ext2, tmpfs, FAT32, read-only volumes) take their
//! metadata from the filesystem; everything here is the fallback so that
//! S_ISFIFO / S_ISSOCK / S_ISCHR classify descriptors correctly.

pub const S_IFMT: u32 = 0o170000;
pub const S_IFSOCK: u32 = 0o140000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFIFO: u32 = 0o010000;

pub const Kind = enum {
    regular,
    pipe,
    socket,
    char_device,
    directory,
    /// eventfd, epoll, timerfd, inotify, pidfd, devfs control: anonymous inodes.
    anon,
};

/// File-type bits for an anonymous descriptor kind. Linux reports these as
/// regular files with mode 0600 (anon_inodefs); keep that so programs that
/// only test for "is a socket/fifo/tty" see none of those.
pub fn typeBits(k: Kind) u32 {
    return switch (k) {
        .regular, .anon => S_IFREG,
        .pipe => S_IFIFO,
        .socket => S_IFSOCK,
        .char_device => S_IFCHR,
        .directory => S_IFDIR,
    };
}

/// st_mode: type bits plus permission bits. Pipes and sockets are 0600 on
/// Linux, anonymous inodes 0600, the console and devices 0620/0666-ish; here
/// read for all and write when the descriptor is writable, never execute.
pub fn mode(k: Kind, writable: bool) u32 {
    var perm: u32 = switch (k) {
        .pipe, .socket, .anon => 0o600,
        else => 0o444,
    };
    if (k == .char_device or k == .directory) {
        if (writable) perm |= 0o222;
    }
    return typeBits(k) | perm;
}

/// st_nlink for a descriptor with no directory entry of its own.
pub fn nlink(k: Kind) u64 {
    return switch (k) {
        .directory => 2,
        else => 1,
    };
}

/// A stable inode number for an anonymous object: the resource index mixed
/// with a per-kind tag so a pipe 3 and a socket 3 differ.
pub fn syntheticIno(tag: u8, resource_idx: u64) u64 {
    return (@as(u64, tag) << 56) | (resource_idx & 0x00FF_FFFF_FFFF_FFFF);
}

test "type bits classify every kind" {
    const std = @import("std");
    try std.testing.expectEqual(S_IFIFO, typeBits(.pipe));
    try std.testing.expectEqual(S_IFSOCK, typeBits(.socket));
    try std.testing.expectEqual(S_IFCHR, typeBits(.char_device));
    try std.testing.expectEqual(S_IFDIR, typeBits(.directory));
    try std.testing.expectEqual(S_IFREG, typeBits(.anon));
}

test "permissions: never executable, writable only where it makes sense" {
    const std = @import("std");
    try std.testing.expectEqual(S_IFIFO | 0o600, mode(.pipe, true));
    try std.testing.expectEqual(S_IFSOCK | 0o600, mode(.socket, false));
    try std.testing.expectEqual(S_IFCHR | 0o666, mode(.char_device, true));
    try std.testing.expectEqual(S_IFCHR | 0o444, mode(.char_device, false));
    try std.testing.expectEqual(@as(u32, 0), mode(.anon, true) & 0o111);
    try std.testing.expectEqual(@as(u64, 1), nlink(.pipe));
    try std.testing.expectEqual(@as(u64, 2), nlink(.directory));
}

test "synthetic inodes differ across kinds and indices" {
    const std = @import("std");
    try std.testing.expect(syntheticIno(1, 3) != syntheticIno(2, 3));
    try std.testing.expect(syntheticIno(1, 3) != syntheticIno(1, 4));
    try std.testing.expectEqual(syntheticIno(5, 9), syntheticIno(5, 9));
}
