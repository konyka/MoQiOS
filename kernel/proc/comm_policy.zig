//! A process's short name ("comm"), the 16-byte field prctl(PR_SET_NAME/PR_GET_NAME) and /proc/<pid>/{comm,status,stat} report.
//! Linux (measured): a new image's name is its program file name cut to 15 bytes; PR_SET_NAME cuts a longer name to 15 bytes and zero-fills
//! the rest of the 16 (a shorter name must not leave bytes of the previous one behind); the empty name is allowed.
const std = @import("std");

pub const LEN: usize = 16;
pub const Comm = [LEN]u8;

/// The name a program gets when it is loaded or exec'd: the first 15 bytes of its file name, zero-padded.
pub fn fromProgram(file_name: []const u8) Comm {
    return fromBytes(file_name);
}

/// The name PR_SET_NAME stores for the bytes copied from user space: up to the first NUL, at most 15 bytes, zero-padded.
pub fn fromBytes(raw: []const u8) Comm {
    var out: Comm = @splat(0);
    var n: usize = 0;
    while (n < raw.len and n < LEN - 1 and raw[n] != 0) : (n += 1) out[n] = raw[n];
    return out;
}

/// The length of the name in `comm` (up to its first NUL).
pub fn textLen(comm: *const Comm) usize {
    var n: usize = 0;
    while (n < LEN and comm[n] != 0) : (n += 1) {}
    return n;
}

test "comm: program names and PR_SET_NAME names are cut to 15 bytes and zero-padded" {
    const a = fromProgram("hello258");
    try std.testing.expectEqualSlices(u8, "hello258" ++ "\x00" ** 8, &a);
    const long = fromProgram("abcdefghijklmnopqrstuvwxyz");
    try std.testing.expectEqualSlices(u8, "abcdefghijklmno\x00", &long);
    try std.testing.expectEqual(@as(usize, 15), textLen(&long));
    const empty = fromBytes("");
    try std.testing.expectEqualSlices(u8, &(@as(Comm, @splat(0))), &empty);
}

test "comm: a name stops at its first NUL and nothing after it is kept" {
    const c = fromBytes("xy\x00cdefghij");
    try std.testing.expectEqualSlices(u8, "xy" ++ "\x00" ** 14, &c);
    try std.testing.expectEqual(@as(usize, 2), textLen(&c));
}
