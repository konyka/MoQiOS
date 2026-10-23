const std = @import("std");
const a = @import("kernel_shared").rofs_access_policy;

const owner_only: a.Meta = .{ .mode = 0o100600, .uid = 1000, .gid = 1000 };
const group_read: a.Meta = .{ .mode = 0o100640, .uid = 1000, .gid = 50 };
const world_read: a.Meta = .{ .mode = 0o100644, .uid = 1000, .gid = 1000 };
const locked_dir: a.Meta = .{ .mode = 0o040700, .uid = 1000, .gid = 1000 };

const alice: a.Creds = .{ .euid = 1000, .egid = 1000 };
const bob: a.Creds = .{ .euid = 2000, .egid = 2000 };
const grp: a.Creds = .{ .euid = 3000, .egid = 50 };
const root: a.Creds = .{ .euid = 0, .egid = 0 };

test "owner, group and other classes" {
    try std.testing.expect(a.canRead(owner_only, alice));
    try std.testing.expect(!a.canRead(owner_only, bob));
    try std.testing.expect(!a.canRead(owner_only, grp));
    try std.testing.expect(a.canRead(group_read, grp));
    try std.testing.expect(!a.canRead(group_read, bob));
    try std.testing.expect(a.canRead(world_read, bob));
}

test "the owner class wins even when it grants less than the others" {
    // mode 0o044: owner has nothing, group and other can read. The owner is
    // denied — POSIX picks the single matching class, it does not fall through.
    const odd: a.Meta = .{ .mode = 0o100044, .uid = 1000, .gid = 1000 };
    try std.testing.expect(!a.canRead(odd, alice));
    try std.testing.expect(a.canRead(odd, bob));
}

test "group class applies before other" {
    const odd: a.Meta = .{ .mode = 0o100604, .uid = 1000, .gid = 50 }; // group: none, other: read
    try std.testing.expect(!a.canRead(odd, grp)); // group member is held to the (empty) group class
    try std.testing.expect(a.canRead(odd, bob));
}

test "directories: search is separate from list" {
    const list_only: a.Meta = .{ .mode = 0o040744, .uid = 1000, .gid = 1000 }; // others: r--
    try std.testing.expect(a.canList(list_only, bob));
    try std.testing.expect(!a.canSearch(list_only, bob));
    try std.testing.expect(a.canSearch(list_only, alice));
    try std.testing.expect(!a.canList(locked_dir, bob));
    try std.testing.expect(!a.canSearch(locked_dir, bob));
}

test "root and CAP_DAC_OVERRIDE bypass read/write but not a missing execute bit" {
    try std.testing.expect(a.canRead(owner_only, root));
    try std.testing.expect(a.canSearch(locked_dir, root));
    try std.testing.expect(a.allows(owner_only, root, a.R | a.W));
    try std.testing.expect(!a.allows(owner_only, root, a.X)); // 0600 file: nobody can execute it
    const exe: a.Meta = .{ .mode = 0o100700, .uid = 1000, .gid = 1000 };
    try std.testing.expect(a.allows(exe, root, a.X));
    const capped: a.Creds = .{ .euid = 2000, .egid = 2000, .cap_dac_override = true };
    try std.testing.expect(a.canRead(owner_only, capped));
}

test "combined masks need every requested bit" {
    try std.testing.expect(!a.allows(world_read, bob, a.R | a.W));
    try std.testing.expect(a.allows(owner_only, alice, a.R | a.W));
    try std.testing.expect(a.allows(world_read, bob, 0));
}
