//! Pure path assembly for an ext2 directory identified by inode.
//!
//! A directory descriptor must follow its inode, not the path it was opened
//! by. The path is rebuilt from the inode chain: each directory's ".." names
//! its parent, and the parent's entry for the directory's inode gives the
//! component name. Names are collected leaf-to-root and joined root-first.

const std = @import("std");

pub const ROOT_INO: u32 = 2;
pub const MAX_DEPTH: usize = 32;
pub const MAX_NAME: usize = 255;
pub const MAX_PATH: usize = 255;

pub const Chain = struct {
    /// Component names from the directory (index 0) up to just below the root.
    names: [MAX_DEPTH][MAX_NAME]u8 = undefined,
    lens: [MAX_DEPTH]u8 = @splat(0),
    depth: usize = 0,

    pub fn push(self: *Chain, name: []const u8) bool {
        if (self.depth == MAX_DEPTH or name.len == 0 or name.len > MAX_NAME) return false;
        @memcpy(self.names[self.depth][0..name.len], name);
        self.lens[self.depth] = @intCast(name.len);
        self.depth += 1;
        return true;
    }
};

pub const JoinError = error{TooLong};

/// "/a/b/c" for a chain whose leaf is "c"; "/" for an empty chain.
pub fn join(chain: *const Chain, out: *[MAX_PATH + 1]u8) JoinError![]const u8 {
    if (chain.depth == 0) {
        out[0] = '/';
        return out[0..1];
    }
    var pos: usize = 0;
    var i = chain.depth;
    while (i > 0) {
        i -= 1;
        const len: usize = chain.lens[i];
        if (pos + 1 + len > MAX_PATH) return error.TooLong;
        out[pos] = '/';
        pos += 1;
        @memcpy(out[pos..][0..len], chain.names[i][0..len]);
        pos += len;
    }
    return out[0..pos];
}

/// One step up: `child` is entered under `parent` as `name`. The walk
/// continues while the parent is not the root; a parent equal to the child
/// (".." of the root) or one already seen is a corrupt or looping chain.
pub const Step = enum { done, up, invalid };

pub fn nextStep(child_ino: u32, parent_ino: u32, seen: []const u32) Step {
    if (child_ino == ROOT_INO) return .done;
    if (parent_ino == 0 or parent_ino == child_ino) return .invalid;
    for (seen) |s| if (s == parent_ino) return .invalid;
    return .up;
}

test "join assembles root-first and handles the root" {
    var c: Chain = .{};
    var out: [MAX_PATH + 1]u8 = undefined;
    try std.testing.expectEqualStrings("/", try join(&c, &out));
    try std.testing.expect(c.push("c"));
    try std.testing.expect(c.push("b"));
    try std.testing.expect(c.push("a"));
    try std.testing.expectEqualStrings("/a/b/c", try join(&c, &out));
}

test "join rejects an over-long path and push rejects bad names" {
    var c: Chain = .{};
    var out: [MAX_PATH + 1]u8 = undefined;
    const big: [200]u8 = @splat('x');
    try std.testing.expect(c.push(&big));
    try std.testing.expect(c.push(&big));
    try std.testing.expectError(error.TooLong, join(&c, &out));
    var d: Chain = .{};
    try std.testing.expect(!d.push(""));
    const huge: [256]u8 = @splat('y');
    try std.testing.expect(!d.push(&huge));
    var e: Chain = .{};
    for (0..MAX_DEPTH) |_| try std.testing.expect(e.push("d"));
    try std.testing.expect(!e.push("d"));
}

test "the walk stops at the root and refuses loops" {
    try std.testing.expectEqual(Step.done, nextStep(ROOT_INO, ROOT_INO, &.{}));
    try std.testing.expectEqual(Step.up, nextStep(12, ROOT_INO, &.{12}));
    try std.testing.expectEqual(Step.up, nextStep(12, 7, &.{12}));
    try std.testing.expectEqual(Step.invalid, nextStep(12, 12, &.{12}));
    try std.testing.expectEqual(Step.invalid, nextStep(12, 0, &.{12}));
    try std.testing.expectEqual(Step.invalid, nextStep(12, 7, &.{ 12, 7 }));
}
