//! IPv6 flow label management (Linux net/ipv6/ip6_flowlabel.c, setsockopt IPV6_FLOWLABEL_MGR): a socket leases flow labels from a
//! system-wide table, shared with other sockets as the label's share mode allows (any socket, the creating process, the creating
//! user, or none). While some label is held exclusively, an IPv6 send or connect may only use a label its own socket holds (EINVAL
//! otherwise). A label nobody holds lingers for its linger time, then goes away.
//!
//! The table and the per-socket holdings are fixed arrays; a socket is named by a `Holder` key that its owner moves when the
//! socket's own key changes (UDP autobind / bind).
const std = @import("std");

pub const IPV6_FLOWLABEL_MGR: u64 = 32;
pub const REQ_LEN: usize = 32;

pub const A_GET: u8 = 0;
pub const A_PUT: u8 = 1;
pub const A_RENEW: u8 = 2;

pub const F_CREATE: u16 = 1;
pub const F_EXCL: u16 = 2;
pub const F_REFLECT: u16 = 4;
pub const F_REMOTE: u16 = 8;

pub const S_NONE: u8 = 0;
pub const S_EXCL: u8 = 1;
pub const S_PROCESS: u8 = 2;
pub const S_USER: u8 = 3;
pub const S_ANY: u8 = 255;

pub const LABEL_MASK: u32 = 0x000F_FFFF;
/// FL_MIN_LINGER / FL_MAX_LINGER, seconds: a shorter linger or expiry is raised to the minimum, a longer one needs CAP_NET_ADMIN.
pub const MIN_LINGER: u32 = 6;
pub const MAX_LINGER: u32 = 150;
/// Labels in the table (Linux FL_MAX_SIZE 4096) and labels one socket may hold (FL_MAX_PER_SOCK).
pub const MAX_LABELS: usize = 64;
pub const MAX_PER_SOCK: usize = 32;
/// Holdings in all (one socket holding one label each).
pub const MAX_HOLDINGS: usize = 256;

/// struct in6_flowlabel_req: flr_dst, flr_label (network order), flr_action, flr_share, flr_flags, flr_expires, flr_linger.
pub const Req = struct {
    dst: [16]u8 = @splat(0),
    label: u32 = 0,
    action: u8 = 0,
    share: u8 = 0,
    flags: u16 = 0,
    expires: u16 = 0,
    linger: u16 = 0,

    pub fn parse(b: *const [REQ_LEN]u8) Req {
        return .{
            .dst = b[0..16].*,
            .label = std.mem.readInt(u32, b[16..20], .big),
            .action = b[20],
            .share = b[21],
            .flags = std.mem.readInt(u16, b[22..24], .little),
            .expires = std.mem.readInt(u16, b[24..26], .little),
            .linger = std.mem.readInt(u16, b[26..28], .little),
        };
    }

    pub fn write(r: Req, b: *[REQ_LEN]u8) void {
        @memset(b, 0);
        b[0..16].* = r.dst;
        std.mem.writeInt(u32, b[16..20], r.label, .big);
        b[20] = r.action;
        b[21] = r.share;
        std.mem.writeInt(u16, b[22..24], r.flags, .little);
        std.mem.writeInt(u16, b[24..26], r.expires, .little);
        std.mem.writeInt(u16, b[26..28], r.linger, .little);
    }
};

/// A socket that can hold labels: its kind and its key (UDP port key, raw socket index, TCB index).
pub const Holder = struct {
    kind: enum(u8) { none, udp, raw, tcp } = .none,
    key: u32 = 0,

    fn eql(a: Holder, b: Holder) bool {
        return a.kind == b.kind and a.key == b.key;
    }
};

/// Who is asking: the process (tgid), the effective uid, CAP_NET_ADMIN, and the time now in milliseconds (monotonic).
pub const Caller = struct { tgid: u32 = 0, euid: u32 = 0, net_admin: bool = false, now_ms: u64 = 0 };

const Label = struct {
    used: bool = false,
    label: u32 = 0,
    dst: [16]u8 = @splat(0),
    share: u8 = 0,
    owner_pid: u32 = 0,
    owner_uid: u32 = 0,
    users: u32 = 0,
    /// Seconds a label nobody holds stays (fl->linger), and when it may go at the earliest (fl->expires, ms).
    linger_s: u32 = 0,
    expires_ms: u64 = 0,
    lastuse_ms: u64 = 0,
};

const Holding = struct { used: bool = false, holder: Holder = .{}, label: u32 = 0 };

pub const State = struct {
    labels: [MAX_LABELS]Label = @splat(.{}),
    holdings: [MAX_HOLDINGS]Holding = @splat(.{}),
    /// The deferred static key is active while an exclusive label exists and for one second after the last one is freed
    /// (ipv6_flowlabel_exclusive). Linux's separate flowlabel_has_excl flag remains sticky, but is not consulted once that key is off.
    has_excl: bool = false,
    excl_off_ms: u64 = 0,
    rng: u64 = 0x9E37_79B9_7F4A_7C15,

    fn find(s: *State, label: u32, now_ms: u64) ?*Label {
        s.gc(now_ms);
        for (&s.labels) |*l| {
            if (l.used and l.label == label) return l;
        }
        return null;
    }

    /// ip6_fl_gc: a label nobody holds goes once its expiry (no earlier than the last use plus the linger) has passed. The deferred
    /// key's deadline comes from that expiry too, so a caller that has not touched the table for a while does not add another second.
    fn gc(s: *State, now_ms: u64) void {
        var last_excl_free_ms: u64 = 0;
        for (&s.labels) |*l| {
            if (!l.used or l.users != 0) continue;
            const ttd = @max(l.expires_ms, l.lastuse_ms + @as(u64, l.linger_s) * 1000);
            if (now_ms >= ttd) {
                if (l.share != S_ANY) last_excl_free_ms = @max(last_excl_free_ms, ttd);
                l.* = .{};
            }
        }
        var exclusive = false;
        for (&s.labels) |*l| {
            if (l.used and l.share != S_ANY) {
                exclusive = true;
                break;
            }
        }
        if (exclusive) {
            s.has_excl = true;
            s.excl_off_ms = 0;
        } else if (s.has_excl) {
            if (last_excl_free_ms != 0) s.excl_off_ms = last_excl_free_ms + 1000;
            if (s.excl_off_ms != 0 and now_ms >= s.excl_off_ms) {
                s.has_excl = false;
                s.excl_off_ms = 0;
            }
        }
    }

    fn holds(s: *const State, h: Holder, label: u32) bool {
        for (&s.holdings) |*x| {
            if (x.used and x.holder.eql(h) and x.label == label) return true;
        }
        return false;
    }

    fn heldCount(s: *const State, h: Holder) usize {
        var n: usize = 0;
        for (&s.holdings) |*x| {
            if (x.used and x.holder.eql(h)) n += 1;
        }
        return n;
    }

    fn link(s: *State, h: Holder, label: u32) bool {
        for (&s.holdings) |*x| {
            if (!x.used) {
                x.* = .{ .used = true, .holder = h, .label = label };
                return true;
            }
        }
        return false;
    }

    fn release(l: *Label, now_ms: u64) void {
        l.lastuse_ms = now_ms;
        l.users -|= 1;
        if (l.users == 0) l.expires_ms = @max(l.expires_ms, now_ms + @as(u64, l.linger_s) * 1000);
    }

    fn nextRandom(s: *State) u32 {
        s.rng ^= s.rng << 13;
        s.rng ^= s.rng >> 7;
        s.rng ^= s.rng << 17;
        return @truncate(s.rng);
    }

    /// setsockopt(IPV6_FLOWLABEL_MGR). `req` is updated with the label a GET with label 0 picked (the caller copies flr_label
    /// back). `is_tcp` for F_REFLECT. Returns 0 or -errno.
    pub fn opt(s: *State, h: Holder, req: *Req, c: Caller, is_tcp: bool) i64 {
        return switch (req.action) {
            A_PUT => s.put(h, req.*, c, is_tcp),
            A_RENEW => s.renew(h, req.*, c),
            A_GET => s.get(h, req, c, is_tcp),
            else => -22,
        };
    }

    fn put(s: *State, h: Holder, req: Req, c: Caller, is_tcp: bool) i64 {
        if (req.flags & F_REFLECT != 0) return if (is_tcp) -3 else -92; // ESRCH (REPFLOW never set: consistency is on), ENOPROTOOPT
        for (&s.holdings) |*x| {
            if (x.used and x.holder.eql(h) and x.label == req.label) {
                x.* = .{};
                if (s.find(req.label, c.now_ms)) |l| release(l, c.now_ms);
                return 0;
            }
        }
        return -3; // ESRCH
    }

    /// check_linger: seconds, raised to the minimum; past the maximum without CAP_NET_ADMIN null (EPERM).
    fn checkLinger(t: u32, c: Caller) ?u32 {
        if (t < MIN_LINGER) return MIN_LINGER;
        if (t > MAX_LINGER and !c.net_admin) return null;
        return t;
    }

    fn renewLabel(l: *Label, linger: u32, expires: u32, c: Caller) i64 {
        const lg = checkLinger(linger, c) orelse return -1;
        var ex = checkLinger(expires, c) orelse return -1;
        l.lastuse_ms = c.now_ms;
        if (l.linger_s < lg) l.linger_s = lg;
        if (ex < l.linger_s) ex = l.linger_s;
        l.expires_ms = @max(l.expires_ms, c.now_ms + @as(u64, ex) * 1000);
        return 0;
    }

    fn renew(s: *State, h: Holder, req: Req, c: Caller) i64 {
        if (s.holds(h, req.label)) {
            const l = s.find(req.label, c.now_ms) orelse return -3;
            return renewLabel(l, req.linger, req.expires, c);
        }
        if (req.share == S_NONE and c.net_admin) {
            if (s.find(req.label, c.now_ms)) |l| return renewLabel(l, req.linger, req.expires, c);
        }
        return -3; // ESRCH
    }

    fn get(s: *State, h: Holder, req: *Req, c: Caller, is_tcp: bool) i64 {
        // flowlabel_consistency is on (the default): F_REFLECT is refused before the protocol is looked at.
        if (req.flags & F_REFLECT != 0) {
            _ = is_tcp;
            return -1; // EPERM
        }
        if (req.label & ~LABEL_MASK != 0) return -22;
        // fl_create: the linger and expiry, the destination, the share mode.
        var fresh: Label = .{ .used = true, .share = req.share, .dst = req.dst, .users = 1, .expires_ms = c.now_ms, .lastuse_ms = c.now_ms };
        const rr = renewLabel(&fresh, req.linger, req.expires, c);
        if (rr != 0) return rr;
        if (std.mem.allEqual(u8, &req.dst, 0) or isV4Mapped(req.dst)) return -22;
        switch (req.share) {
            S_EXCL, S_ANY => {},
            S_PROCESS => fresh.owner_pid = c.tgid,
            S_USER => fresh.owner_uid = c.euid,
            else => return -22,
        }
        if (req.label != 0) {
            const mine = s.holds(h, req.label);
            if (mine and req.flags & F_EXCL != 0) return -17; // EEXIST
            if (s.find(req.label, c.now_ms)) |l| {
                if (req.flags & F_EXCL != 0) return -17;
                if (l.share == S_EXCL or l.share != fresh.share or
                    (l.share == S_PROCESS and l.owner_pid != fresh.owner_pid) or
                    (l.share == S_USER and l.owner_uid != fresh.owner_uid)) return -1; // EPERM
                if (fresh.linger_s > l.linger_s) l.linger_s = fresh.linger_s;
                if (fresh.expires_ms > l.expires_ms) l.expires_ms = fresh.expires_ms;
                if (!s.link(h, req.label)) return -12;
                l.users += 1;
                return 0;
            }
        }
        if (req.flags & F_CREATE == 0) return -2; // ENOENT
        // mem_check: past the per-socket limit, or with the table filling up, only CAP_NET_ADMIN may take more.
        const used = s.usedLabels();
        const room = MAX_LABELS - used;
        if (room == 0 or ((s.heldCount(h) >= MAX_PER_SOCK or (s.heldCount(h) > 0 and room < MAX_LABELS / 2) or room < MAX_LABELS / 4) and !c.net_admin))
            return -105; // ENOBUFS
        if (req.label == 0) {
            while (true) {
                const l = s.nextRandom() & LABEL_MASK;
                if (l != 0 and s.find(l, c.now_ms) == null) {
                    fresh.label = l;
                    break;
                }
            }
            req.label = fresh.label;
        } else fresh.label = req.label;
        const slot = s.freeLabel() orelse return -105;
        if (!s.link(h, fresh.label)) return -12;
        slot.* = fresh;
        if (fresh.share != S_ANY) {
            s.has_excl = true;
            s.excl_off_ms = 0;
        }
        return 0;
    }

    fn usedLabels(s: *const State) usize {
        var n: usize = 0;
        for (&s.labels) |*l| n += @intFromBool(l.used);
        return n;
    }

    fn freeLabel(s: *State) ?*Label {
        for (&s.labels) |*l| {
            if (!l.used) return l;
        }
        return null;
    }

    /// getsockopt(IPV6_FLOWLABEL_MGR) for the label the socket's flow_label names (np->flow_label: set by connect with
    /// IPV6_FLOWINFO_SEND). ENOENT when the socket holds no such label.
    pub fn optGet(s: *State, h: Holder, flow_label: u32, c: Caller) union(enum) { ok: Req, err: i64 } {
        const want = flow_label & LABEL_MASK;
        if (want == 0 or !s.holds(h, want)) return .{ .err = -2 };
        const l = s.find(want, c.now_ms) orelse return .{ .err = -2 };
        const left_ms = if (l.expires_ms > c.now_ms) l.expires_ms - c.now_ms else 0;
        return .{ .ok = .{ .label = l.label, .dst = l.dst, .share = l.share, .expires = @intCast(@min(left_ms / 1000, 0xFFFF)), .linger = @intCast(@min(l.linger_s, 0xFFFF)) } };
    }

    /// fl6_sock_lookup on a send or connect with flow label `label` (its low 20 bits): EINVAL while the deferred exclusive key
    /// is active and this socket does not hold `label`; otherwise 0.
    pub fn checkSend(s: *State, h: Holder, label: u32, now_ms: u64) i64 {
        s.gc(now_ms);
        const l = label & LABEL_MASK;
        if (l == 0 or !s.has_excl) return 0;
        if (!s.holds(h, l)) return -22;
        if (s.find(l, now_ms)) |x| x.lastuse_ms = now_ms;
        return 0;
    }

    /// fl6_free_socklist: the socket went away; its labels start lingering.
    pub fn dropHolder(s: *State, h: Holder, now_ms: u64) void {
        for (&s.holdings) |*x| {
            if (x.used and x.holder.eql(h)) {
                const label = x.label;
                x.* = .{};
                if (s.find(label, now_ms)) |l| release(l, now_ms);
            }
        }
    }

    /// The socket's key changed (UDP autobind / bind): its holdings follow it.
    pub fn rekey(s: *State, old: Holder, new: Holder) void {
        if (old.eql(new)) return;
        for (&s.holdings) |*x| {
            if (x.used and x.holder.eql(old)) x.holder = new;
        }
    }
};

fn isV4Mapped(a: [16]u8) bool {
    return std.mem.allEqual(u8, a[0..10], 0) and a[10] == 0xFF and a[11] == 0xFF;
}

const lo6 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

fn mkReq(action: u8, share: u8, flags: u16, label: u32) Req {
    return .{ .dst = lo6, .label = label, .action = action, .share = share, .flags = flags, .linger = 6, .expires = 6 };
}

test "GET creates, joins and refuses as Linux measured (hello484 A-N)" {
    var s: State = .{};
    const a: Holder = .{ .kind = .udp, .key = 1 };
    const b: Holder = .{ .kind = .udp, .key = 2 };
    const c: Caller = .{ .tgid = 10, .euid = 0 };
    var r = mkReq(A_GET, S_ANY, F_CREATE, 0);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    try std.testing.expect(r.label != 0 and r.label & ~LABEL_MASK == 0);
    r = mkReq(A_GET, S_ANY, 0, 0x12345);
    try std.testing.expectEqual(@as(i64, -2), s.opt(a, &r, c, false));
    r = mkReq(A_GET, S_ANY, F_CREATE, 0x12345);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    r = mkReq(A_GET, S_ANY, 0, 0x12345);
    try std.testing.expectEqual(@as(i64, 0), s.opt(b, &r, c, false));
    r = mkReq(A_GET, S_ANY, F_EXCL, 0x12345);
    try std.testing.expectEqual(@as(i64, -17), s.opt(b, &r, c, false));
    r = mkReq(A_GET, S_EXCL, F_CREATE, 0x22222);
    try std.testing.expectEqual(@as(i64, 0), s.opt(b, &r, c, false));
    r = mkReq(A_GET, S_EXCL, 0, 0x22222);
    try std.testing.expectEqual(@as(i64, -1), s.opt(a, &r, c, false));
    r = mkReq(A_GET, S_USER, 0, 0x12345);
    try std.testing.expectEqual(@as(i64, -1), s.opt(a, &r, c, false));
    r = mkReq(A_PUT, 0, 0, 0x99999);
    try std.testing.expectEqual(@as(i64, -3), s.opt(a, &r, c, false));
    r = mkReq(A_RENEW, 0, 0, 0x12345);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    r = mkReq(A_RENEW, 0, 0, 0x99999);
    try std.testing.expectEqual(@as(i64, -3), s.opt(a, &r, c, false));
    r = mkReq(A_GET, S_ANY, F_CREATE, 0x100000);
    try std.testing.expectEqual(@as(i64, -22), s.opt(a, &r, c, false));
    r = mkReq(7, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, -22), s.opt(a, &r, c, false));
    r = mkReq(A_GET, S_ANY, F_CREATE, 0x33333);
    r.dst = @splat(0);
    try std.testing.expectEqual(@as(i64, -22), s.opt(a, &r, c, false));
    r = mkReq(A_GET, 9, F_CREATE, 0x33333);
    try std.testing.expectEqual(@as(i64, -22), s.opt(a, &r, c, false));
    r = mkReq(A_GET, S_ANY, F_REFLECT, 0);
    try std.testing.expectEqual(@as(i64, -1), s.opt(a, &r, c, true));
}

test "sends need a held label once one is exclusive; PROCESS and USER sharing; linger after the last holder" {
    var s: State = .{};
    const a: Holder = .{ .kind = .udp, .key = 1 };
    const b: Holder = .{ .kind = .udp, .key = 2 };
    var c: Caller = .{ .tgid = 10, .euid = 0, .now_ms = 1000 };
    try std.testing.expectEqual(@as(i64, 0), s.checkSend(a, 0x54321, c.now_ms));
    var r = mkReq(A_GET, S_ANY, F_CREATE, 0x11111);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    try std.testing.expectEqual(@as(i64, 0), s.checkSend(a, 0x54321, c.now_ms));
    r = mkReq(A_GET, S_PROCESS, F_CREATE, 0x22222);
    try std.testing.expectEqual(@as(i64, 0), s.opt(b, &r, c, false));
    try std.testing.expectEqual(@as(i64, -22), s.checkSend(a, 0x54321, c.now_ms));
    try std.testing.expectEqual(@as(i64, 0), s.checkSend(a, 0x11111, c.now_ms));
    r = mkReq(A_GET, S_PROCESS, 0, 0x22222);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    var other = c;
    other.tgid = 11;
    r = mkReq(A_GET, S_PROCESS, 0, 0x22222);
    try std.testing.expectEqual(@as(i64, -1), s.opt(.{ .kind = .udp, .key = 3 }, &r, other, false));
    r = mkReq(A_GET, S_USER, F_CREATE, 0x88888);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    r = mkReq(A_GET, S_USER, 0, 0x88888);
    try std.testing.expectEqual(@as(i64, 0), s.opt(.{ .kind = .udp, .key = 3 }, &r, other, false));
    r = mkReq(A_GET, S_ANY, F_CREATE, 0x45444);
    r.linger = 151;
    try std.testing.expectEqual(@as(i64, -1), s.opt(a, &r, c, false));
    // After every holder goes the label lingers 6 s: joining it then is EPERM for an exclusive one, ENOENT once it is gone.
    s.dropHolder(b, c.now_ms);
    s.dropHolder(a, c.now_ms);
    s.dropHolder(.{ .kind = .udp, .key = 3 }, c.now_ms);
    c.now_ms += 1000;
    r = mkReq(A_GET, S_EXCL, F_CREATE, 0x22222);
    try std.testing.expectEqual(@as(i64, -1), s.opt(b, &r, c, false));
    c.now_ms += 7000;
    r = mkReq(A_GET, S_ANY, 0, 0x11111);
    try std.testing.expectEqual(@as(i64, -2), s.opt(b, &r, c, false));
}

test "holdings follow a rekeyed socket; getsockopt reports the connected label" {
    var s: State = .{};
    const a: Holder = .{ .kind = .udp, .key = 1 };
    const a2: Holder = .{ .kind = .udp, .key = 0x10001 };
    const c: Caller = .{ .now_ms = 5 };
    var r = mkReq(A_GET, S_EXCL, F_CREATE, 0x4d0c1);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    s.rekey(a, a2);
    try std.testing.expectEqual(@as(i64, 0), s.checkSend(a2, 0x4d0c1, c.now_ms));
    try std.testing.expectEqual(@as(i64, -22), s.checkSend(a, 0x4d0c1, c.now_ms));
    switch (s.optGet(a2, 0x4d0c1, c)) {
        .ok => |q| {
            try std.testing.expectEqual(@as(u32, 0x4d0c1), q.label);
            try std.testing.expectEqual(S_EXCL, q.share);
            try std.testing.expectEqual(@as(u16, 6), q.linger);
        },
        .err => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(i64, -2), switch (s.optGet(a2, 0, c)) {
        .ok => 0,
        .err => |e| e,
    });
    var b: [REQ_LEN]u8 = undefined;
    r.write(&b);
    try std.testing.expectEqual(r.label, Req.parse(&b).label);
    try std.testing.expectEqual(@as(u8, 0xd0), b[18]);
}

// ── The kernel's table ───────────────────────────────────────────────────────

var state: State = .{};
var lock: @import("../sync/irq_spinlock.zig").IrqSpinlock = .{};

fn nowMs() u64 {
    return @import("../arch/arch.zig").tsc.nanos() / 1_000_000;
}

/// The calling task as a Caller (its process, effective uid, CAP_NET_ADMIN).
pub fn currentCaller() Caller {
    const sched = @import("../proc/sched.zig");
    const t = sched.currentTask() orelse return .{ .now_ms = nowMs() };
    return .{ .tgid = if (t.is_thread and t.parent_tid != 0) t.parent_tid else t.tid, .euid = t.euid, .net_admin = t.effective_caps.cap_net_admin, .now_ms = nowMs() };
}

pub fn opt(h: Holder, r: *Req, is_tcp: bool) i64 {
    const c = currentCaller();
    const f = lock.acquire();
    defer lock.release(f);
    if (state.rng == 0x9E37_79B9_7F4A_7C15) state.rng ^= @import("../arch/arch.zig").tsc.nanos() | 1;
    return state.opt(h, r, c, is_tcp);
}

pub fn optGet(h: Holder, flow_label: u32) union(enum) { ok: Req, err: i64 } {
    const c = currentCaller();
    const f = lock.acquire();
    defer lock.release(f);
    return switch (state.optGet(h, flow_label, c)) {
        .ok => |q| .{ .ok = q },
        .err => |e| .{ .err = e },
    };
}

pub fn checkSend(h: Holder, label: u32) i64 {
    const f = lock.acquire();
    defer lock.release(f);
    return state.checkSend(h, label, nowMs());
}

pub fn dropHolder(h: Holder) void {
    const f = lock.acquire();
    defer lock.release(f);
    state.dropHolder(h, nowMs());
}

pub fn rekey(old: Holder, new: Holder) void {
    const f = lock.acquire();
    defer lock.release(f);
    state.rekey(old, new);
}

test "exclusive send gate turns off one second after the final label expires (hello484 P)" {
    var s: State = .{};
    const a: Holder = .{ .kind = .udp, .key = 1 };
    const b: Holder = .{ .kind = .udp, .key = 2 };
    var c: Caller = .{ .now_ms = 1000 };
    var r = mkReq(A_GET, S_EXCL, F_CREATE, 0x5a5a5);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    try std.testing.expectEqual(@as(i64, -22), s.checkSend(b, 0x54321, c.now_ms));
    s.dropHolder(a, c.now_ms);
    c.now_ms = 6999;
    try std.testing.expectEqual(@as(i64, -22), s.checkSend(b, 0x54321, c.now_ms));
    c.now_ms = 7000;
    try std.testing.expectEqual(@as(i64, -22), s.checkSend(b, 0x54321, c.now_ms));
    c.now_ms = 7999;
    try std.testing.expectEqual(@as(i64, -22), s.checkSend(b, 0x54321, c.now_ms));
    c.now_ms = 8000;
    try std.testing.expectEqual(@as(i64, 0), s.checkSend(b, 0x54321, c.now_ms));
    r = mkReq(A_GET, S_EXCL, F_CREATE, 0x6b6b6);
    try std.testing.expectEqual(@as(i64, 0), s.opt(a, &r, c, false));
    try std.testing.expectEqual(@as(i64, -22), s.checkSend(b, 0x54321, c.now_ms));
}
