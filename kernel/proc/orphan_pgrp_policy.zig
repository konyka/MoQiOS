//! Orphaned process groups (POSIX; Linux kill_orphaned_pgrp / will_become_orphaned_pgrp).
//!
//! A process group is orphaned when no member has a parent that is in a
//! different group of the same session: nobody left in the session can
//! continue a stopped job. When an exit (or the reparenting it causes) makes a
//! group orphaned and that group has a stopped member, every member gets
//! SIGHUP and then SIGCONT. A group that has no stopped member is left alone,
//! and so is a group that was never linked to its session from outside.
//!
//! Linux checks two places on every exit (exit_notify):
//!   - the exiting process's own group, ignoring the exiting process, when its
//!     parent was the group's link to the session;
//!   - each child's group, when the exiting process was that child's link.
//! Init's children do not count as links (is_global_init(real_parent)).

const std = @import("std");

pub const Member = struct {
    pid: u32,
    pgid: u32,
    sid: u32,
    parent_pid: u32 = 0,
    /// Parent's pgid and sid, read before the exit reparents anything.
    parent_pgid: u32,
    parent_sid: u32,
    /// The parent is init (pid 1 or the boot task): never a link.
    parent_is_init: bool,
    stopped: bool,
    zombie: bool,
};

/// Linux will_become_orphaned_pgrp: true when no member other than `ignored`
/// links `pgid` to its session through a parent in another group of the same
/// session.
pub fn willBeOrphaned(members: []const Member, pgid: u32, ignored: ?u32) bool {
    for (members) |m| {
        if (m.pgid != pgid) continue;
        if (ignored != null and m.pid == ignored.?) continue;
        if (m.zombie or m.parent_is_init) continue;
        if (m.parent_pgid != pgid and m.parent_sid == m.sid) return false;
    }
    return true;
}

pub fn hasStopped(members: []const Member, pgid: u32) bool {
    for (members) |m| {
        if (m.pgid == pgid and !m.zombie and m.stopped) return true;
    }
    return false;
}

/// Linux kill_orphaned_pgrp for a group whose link through (`link_pgid`,
/// `link_sid`) is going away. `ignored` is the exiting process when its own
/// group is checked; null when a child's group is checked.
pub fn hangsUp(members: []const Member, pgid: u32, sid: u32, link_pgid: u32, link_sid: u32, ignored: ?u32) bool {
    if (link_pgid == pgid or link_sid != sid) return false;
    return willBeOrphaned(members, pgid, ignored) and hasStopped(members, pgid);
}

/// The groups to hang up when `exiting` exits: at most its own group and one
/// group per child. Writes distinct pgids into `out`, returns the count.
pub fn groupsToHangUp(members: []const Member, exiting: Member, out: []u32) usize {
    var n: usize = 0;
    if (!exiting.parent_is_init and hangsUp(members, exiting.pgid, exiting.sid, exiting.parent_pgid, exiting.parent_sid, exiting.pid)) {
        out[n] = exiting.pgid;
        n += 1;
    }
    for (members) |c| {
        if (c.zombie or c.pid == exiting.pid) continue;
        if (!isChildOf(members, c, exiting)) continue;
        var seen = false;
        for (out[0..n]) |g| seen = seen or g == c.pgid;
        if (seen) continue;
        // The child's group loses this link when the child is reparented to
        // init: the link check therefore ignores this child.
        if (c.pgid != exiting.pgid and c.sid == exiting.sid and willBeOrphanedWithout(members, c.pgid, exiting.pid, c.pid) and hasStopped(members, c.pgid)) {
            if (n < out.len) {
                out[n] = c.pgid;
                n += 1;
            }
        }
    }
    return n;
}

fn isChildOf(members: []const Member, c: Member, exiting: Member) bool {
    _ = members;
    return c.parent_pid == exiting.pid;
}

/// willBeOrphaned after `exiting` is gone and its child `child` has been
/// reparented to init: neither of them links `pgid` any more.
fn willBeOrphanedWithout(members: []const Member, pgid: u32, exiting: u32, child: u32) bool {
    for (members) |m| {
        if (m.pgid != pgid or m.pid == exiting) continue;
        if (m.zombie or m.parent_is_init or m.pid == child) continue;
        if (m.parent_pid == exiting) continue;
        if (m.parent_pgid != pgid and m.parent_sid == m.sid) return false;
    }
    return true;
}

fn member(pid: u32, parent: u32, pgid: u32, sid: u32, parent_pgid: u32, parent_sid: u32, stopped: bool) Member {
    return .{ .pid = pid, .parent_pid = parent, .pgid = pgid, .sid = sid, .parent_pgid = parent_pgid, .parent_sid = parent_sid, .parent_is_init = false, .stopped = stopped, .zombie = false };
}

test "hello58 section 5: a session leader's stopped child in the leader's own group is not hung up (Linux mode 1/7)" {
    // M (pid 10, pgid 10, sid 10) -> D (pid 20) setsid -> C (pid 30) stays in group 20 and stops.
    const d = member(20, 10, 20, 20, 10, 10, false);
    const c = member(30, 20, 20, 20, 20, 20, true);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), groupsToHangUp(&.{ d, c }, d, &out));
}

test "a stopped child in its own group of the leader's session is hung up when the leader exits (Linux mode 6)" {
    const d = member(20, 10, 20, 20, 10, 10, false);
    const c = member(30, 20, 30, 20, 20, 20, true);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), groupsToHangUp(&.{ d, c }, d, &out));
    try std.testing.expectEqual(@as(u32, 30), out[0]);
}

test "the exiting process's own group with a stopped member is hung up when it was the link (Linux mode 2)" {
    // M (10, pgid 10, sid 10) -> D (20) setpgid(0,0): group 20 in session 10 -> C (30) in group 20, stopped.
    const d = member(20, 10, 20, 10, 10, 10, false);
    const c = member(30, 20, 20, 10, 20, 10, true);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), groupsToHangUp(&.{ d, c }, d, &out));
    try std.testing.expectEqual(@as(u32, 20), out[0]);
}

test "a child's own group with a stopped member is hung up when its parent was the link (Linux mode 3)" {
    // D (20) stays in M's group 10; C (30) setpgid(0,0) -> group 30, stops.
    const m = member(10, 1, 10, 10, 1, 1, false);
    const d = member(20, 10, 10, 10, 10, 10, false);
    const c = member(30, 20, 30, 10, 10, 10, true);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), groupsToHangUp(&.{ m, d, c }, d, &out));
    try std.testing.expectEqual(@as(u32, 30), out[0]);
}

test "an orphaned group without a stopped member is left alone (Linux mode 4)" {
    const d = member(20, 10, 20, 10, 10, 10, false);
    const c = member(30, 20, 20, 10, 20, 10, false);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), groupsToHangUp(&.{ d, c }, d, &out));
}

test "a group that keeps another link to its session is not orphaned (Linux mode 5)" {
    // E (40), a child of M in group 10, joined group 20: it still links group 20.
    const m = member(10, 1, 10, 10, 1, 1, false);
    const d = member(20, 10, 20, 10, 10, 10, false);
    const c = member(30, 20, 20, 10, 20, 10, true);
    const e = member(40, 10, 20, 10, 10, 10, false);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), groupsToHangUp(&.{ m, d, c, e }, d, &out));
}

test "init's children are never links" {
    var d = member(20, 10, 20, 10, 1, 1, false);
    d.parent_is_init = true;
    const c = member(30, 20, 20, 10, 20, 10, true);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), groupsToHangUp(&.{ d, c }, d, &out));
}
