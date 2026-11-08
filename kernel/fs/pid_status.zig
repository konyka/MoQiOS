//! The text of /proc/<pid>/status. Linux (measured with gcc probes) prints one "Key:\tvalue" line per field in a fixed order: Name, Umask
//! (four octal digits), State, Tgid, Ngid, Pid, PPid, TracerPid, Uid and Gid (real, effective, saved and filesystem id, tab separated),
//! FDSize, Groups (every group followed by a space), VmSize and VmRSS (kB, right-aligned in eight columns; absent for a kernel thread), Threads, NoNewPrivs and the capability sets CapInh, CapPrm, CapEff, CapBnd and CapAmb (16 hex digits each). A runnable process is "R (running)", a blocked one
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
    /// Capability sets as Linux bitmasks (proc/cap_abi.zig).
    cap_inh: u64,
    cap_prm: u64,
    cap_eff: u64,
    cap_bnd: u64,
    /// Address-space size and resident size in kB; null for a task without a user address space (Linux prints no Vm lines for kernel threads).
    vm_size_kb: ?u64 = null,
    vm_rss_kb: ?u64 = null,
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

    fn hex16(self: *Out, value: u64) void {
        var i: u6 = 60;
        while (true) : (i -= 4) {
            self.char("0123456789abcdef"[@intCast((value >> i) & 0xf)]);
            if (i == 0) break;
        }
    }

    /// Linux prints these sizes right-aligned in eight columns: "VmSize:\t  231788 kB".
    fn kb8(self: *Out, value: u64) void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var v = value;
        if (v == 0) {
            i -= 1;
            tmp[i] = '0';
        }
        while (v > 0) : (v /= 10) {
            i -= 1;
            tmp[i] = @intCast('0' + v % 10);
        }
        var width = tmp.len - i;
        while (width < 8) : (width += 1) self.char(' ');
        self.str(tmp[i..]);
        self.str(" kB");
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
    if (s.vm_size_kb) |size| {
        o.str("\nVmSize:\t");
        o.kb8(size);
    }
    if (s.vm_rss_kb) |rss| {
        o.str("\nVmRSS:\t");
        o.kb8(rss);
    }
    o.str("\nThreads:\t");
    o.dec(s.threads);
    o.str("\nNoNewPrivs:\t");
    o.char(if (s.no_new_privs) '1' else '0');
    o.str("\nCapInh:\t");
    o.hex16(s.cap_inh);
    o.str("\nCapPrm:\t");
    o.hex16(s.cap_prm);
    o.str("\nCapEff:\t");
    o.hex16(s.cap_eff);
    o.str("\nCapBnd:\t");
    o.hex16(s.cap_bnd);
    o.str("\nCapAmb:\t0000000000000000\n");
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
        .cap_inh = 0x0000000800000000,
        .cap_prm = 0xc0,
        .cap_eff = 0x80,
        .cap_bnd = 0x1ffffffffff,
        .vm_size_kb = 231788,
        .vm_rss_kb = 2780,
    };
}

test "status text: every field in Linux order, tab separated" {
    var buf: [512]u8 = undefined;
    const n = render(&buf, buf.len, sample());
    try std.testing.expectEqualStrings(
        "Name:\tcat\nUmask:\t0022\nState:\tR (running)\nTgid:\t42\nNgid:\t0\nPid:\t42\nPPid:\t7\nTracerPid:\t0\n" ++
            "Uid:\t1000\t1001\t1002\t1001\nGid:\t1000\t1000\t1000\t1000\nFDSize:\t64\nGroups:\t10 1000 \nVmSize:\t  231788 kB\nVmRSS:\t    2780 kB\nThreads:\t1\nNoNewPrivs:\t0\n" ++
            "CapInh:\t0000000800000000\nCapPrm:\t00000000000000c0\nCapEff:\t0000000000000080\nCapBnd:\t000001ffffffffff\nCapAmb:\t0000000000000000\n",
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
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Groups:\t\nVmSize:\t  231788 kB\nVmRSS:\t    2780 kB\nThreads:\t2\nNoNewPrivs:\t1\nCapInh:") != null);
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

test "status text: Vm lines are right-aligned in eight columns and absent for a kernel thread" {
    var s = sample();
    var buf: [640]u8 = undefined;
    s.vm_size_kb = 0;
    s.vm_rss_kb = 123456789;
    var n = render(&buf, buf.len, s);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "VmSize:\t       0 kB\nVmRSS:\t123456789 kB\nThreads:") != null);
    s.vm_size_kb = null;
    s.vm_rss_kb = null;
    n = render(&buf, buf.len, s);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Vm") == null);
}
