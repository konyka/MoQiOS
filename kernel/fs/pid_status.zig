//! The text of /proc/<pid>/status. Linux (measured with gcc probes) prints one "Key:\tvalue" line per field in a fixed order: Name, Umask
//! (four octal digits), State, Tgid, Ngid, Pid, PPid, TracerPid, Uid and Gid (real, effective, saved and filesystem id, tab separated),
//! FDSize, Groups (every group followed by a space), Threads and NoNewPrivs. A runnable process is "R (running)", a blocked one
//! "S (sleeping)", a stopped one "T (stopped)" and one that exited but was not waited for "Z (zombie)".
const std = @import("std");

pub const State = enum {
    running,
    sleeping,
    stopped,
    zombie,

    pub fn letter(self: State) u8 {
        return switch (self) {
            .running => 'R',
            .sleeping => 'S',
            .stopped => 'T',
            .zombie => 'Z',
        };
    }

    pub fn text(self: State) []const u8 {
        return switch (self) {
            .running => "R (running)",
            .sleeping => "S (sleeping)",
            .stopped => "T (stopped)",
            .zombie => "Z (zombie)",
        };
    }
};

/// What the scheduler says about a task, in the terms status uses. A stopped task is stopped whatever its scheduler state; a ready task is
/// runnable, which Linux also calls running.
pub fn stateOf(zombie: bool, stopped: bool, blocked: bool) State {
    if (zombie) return .zombie;
    if (stopped) return .stopped;
    if (blocked) return .sleeping;
    return .running;
}

pub const Status = struct {
    name: []const u8,
    state: State,
    tgid: u32,
    pid: u32,
    ppid: u32,
    umask: u32,
    uid: [4]u32,
    gid: [4]u32,
    fd_size: u32,
    groups: []const u32,
    threads: u32,
    no_new_privs: bool,
};

const Out = struct {
    buf: [*]u8,
    max: u32,
    pos: u32 = 0,

    fn char(self: *Out, c: u8) void {
        if (self.pos >= self.max) return;
        self.buf[self.pos] = c;
        self.pos += 1;
    }

    fn str(self: *Out, s: []const u8) void {
        for (s) |c| self.char(c);
    }

    fn dec(self: *Out, value: u64) void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var v = value;
        if (v == 0) {
            self.char('0');
            return;
        }
        while (v > 0) : (v /= 10) {
            i -= 1;
            tmp[i] = @intCast('0' + v % 10);
        }
        self.str(tmp[i..]);
    }

    fn octal4(self: *Out, value: u32) void {
        var tmp: [11]u8 = undefined;
        var i: usize = tmp.len;
        var v = value;
        while (v > 0) : (v >>= 3) {
            i -= 1;
            tmp[i] = @intCast('0' + (v & 7));
        }
        var digits = tmp.len - i;
        while (digits < 4) : (digits += 1) self.char('0');
        self.str(tmp[i..]);
    }

    fn ids(self: *Out, v: [4]u32) void {
        for (v, 0..) |id, k| {
            if (k != 0) self.char('\t');
            self.dec(id);
        }
    }
};

/// Writes the status text for `s` into buf[0..max_len] and returns its length (cut at max_len, like the other generators).
pub fn render(buf: [*]u8, max_len: u32, s: Status) u32 {
    var o: Out = .{ .buf = buf, .max = max_len };
    o.str("Name:\t");
    o.str(s.name);
    o.str("\nUmask:\t");
    o.octal4(s.umask);
    o.str("\nState:\t");
    o.str(s.state.text());
    o.str("\nTgid:\t");
    o.dec(s.tgid);
    o.str("\nNgid:\t0\nPid:\t");
    o.dec(s.pid);
    o.str("\nPPid:\t");
    o.dec(s.ppid);
    o.str("\nTracerPid:\t0\nUid:\t");
    o.ids(s.uid);
    o.str("\nGid:\t");
    o.ids(s.gid);
    o.str("\nFDSize:\t");
    o.dec(s.fd_size);
    o.str("\nGroups:\t");
    for (s.groups) |g| {
        o.dec(g);
        o.char(' ');
    }
    o.str("\nThreads:\t");
    o.dec(s.threads);
    o.str("\nNoNewPrivs:\t");
    o.char(if (s.no_new_privs) '1' else '0');
    o.char('\n');
    return o.pos;
}

fn sample() Status {
    return .{
        .name = "cat",
        .state = .running,
        .tgid = 42,
        .pid = 42,
        .ppid = 7,
        .umask = 0o22,
        .uid = .{ 1000, 1001, 1002, 1001 },
        .gid = .{ 1000, 1000, 1000, 1000 },
        .fd_size = 64,
        .groups = &.{ 10, 1000 },
        .threads = 1,
        .no_new_privs = false,
    };
}

test "status text: every field in Linux order, tab separated" {
    var buf: [512]u8 = undefined;
    const n = render(&buf, buf.len, sample());
    try std.testing.expectEqualStrings(
        "Name:\tcat\nUmask:\t0022\nState:\tR (running)\nTgid:\t42\nNgid:\t0\nPid:\t42\nPPid:\t7\nTracerPid:\t0\n" ++
            "Uid:\t1000\t1001\t1002\t1001\nGid:\t1000\t1000\t1000\t1000\nFDSize:\t64\nGroups:\t10 1000 \nThreads:\t1\nNoNewPrivs:\t0\n",
        buf[0..n],
    );
}

test "status text: umask is four octal digits, groups may be none, a thread has its own pid" {
    var s = sample();
    var buf: [512]u8 = undefined;
    s.umask = 0o027;
    var n = render(&buf, buf.len, s);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Umask:\t0027\n") != null);
    s.umask = 0;
    n = render(&buf, buf.len, s);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Umask:\t0000\n") != null);
    s.umask = 0o777;
    n = render(&buf, buf.len, s);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Umask:\t0777\n") != null);
    s.groups = &.{};
    s.pid = 43;
    s.threads = 2;
    s.no_new_privs = true;
    n = render(&buf, buf.len, s);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Tgid:\t42\nNgid:\t0\nPid:\t43\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Groups:\t\nThreads:\t2\nNoNewPrivs:\t1\n") != null);
}

test "status text: the output is cut at the buffer size and never overruns it" {
    var buf: [16]u8 = undefined;
    const n = render(&buf, 10, sample());
    try std.testing.expectEqual(@as(u32, 10), n);
    try std.testing.expectEqualStrings("Name:\tcat\n", buf[0..10]);
}

test "status state: stopped beats blocked, zombie beats everything, a ready task is running" {
    try std.testing.expectEqual(State.running, stateOf(false, false, false));
    try std.testing.expectEqual(State.sleeping, stateOf(false, false, true));
    try std.testing.expectEqual(State.stopped, stateOf(false, true, true));
    try std.testing.expectEqual(State.zombie, stateOf(true, true, true));
    try std.testing.expectEqual(@as(u8, 'T'), State.stopped.letter());
    try std.testing.expectEqualStrings("S (sleeping)", State.sleeping.text());
}
