//! The answer section of a DNS reply to an A query, read the way glibc's getanswer_r reads it (glibc 2.44, measured with a local
//! server): the records are walked in order with an "expected name" that starts as the queried name. A CNAME (whatever its
//! owner) makes its target the expected name and keeps the name it replaces as an alias; an A record counts only when its owner
//! is the expected name (compared without regard to ASCII case), and the canonical name is the expected name at the end, spelled
//! as the record that introduced it. Pure: no kernel imports, host-tested.

pub const MAX_ADDRS: u8 = 64;
pub const MAX_ALIASES: u8 = 16;
pub const MAX_NAME: usize = 253;
/// The longest encode() result: counts, every address, the canonical name and every alias with their NULs.
pub const MAX_ENCODED: usize = 2 + @as(usize, MAX_ADDRS) * 4 + (@as(usize, MAX_ALIASES) + 1) * (MAX_NAME + 1);

const TYPE_A: u16 = 1;
const TYPE_CNAME: u16 = 5;
const TYPE_PTR: u16 = 12;
const CLASS_IN: u16 = 1;

pub const Answer = struct {
    addrs: [MAX_ADDRS][4]u8 = undefined,
    naddr: u8 = 0,
    /// Name text: the canonical name first, then each alias, back to back; `ends[i]` is where name i stops.
    names: [(MAX_ALIASES + 1) * (MAX_NAME + 1)]u8 = undefined,
    ends: [MAX_ALIASES + 1]u16 = undefined,
    nalias: u8 = 0,

    pub fn canonName(self: *const Answer) []const u8 {
        return self.nameAt(self.nalias);
    }

    pub fn alias(self: *const Answer, i: usize) []const u8 {
        return self.nameAt(i);
    }

    /// Names are stored in the order they were met: aliases 0.., and the canonical (current expected) name last.
    fn nameAt(self: *const Answer, i: usize) []const u8 {
        const start: usize = if (i == 0) 0 else self.ends[i - 1];
        return self.names[start..self.ends[i]];
    }
};

/// A name in presentation form, decoded from the message at `start`, following compression pointers. `next` is where the record
/// continues after the name. null for a malformed or looping name or one longer than MAX_NAME.
const Decoded = struct { len: usize, next: usize };

fn readName(msg: []const u8, start: usize, out: *[MAX_NAME + 1]u8) ?Decoded {
    var pos = start;
    var next: ?usize = null;
    var len: usize = 0;
    var jumps: usize = 0;
    while (true) {
        if (pos >= msg.len) return null;
        const b = msg[pos];
        if (b == 0) {
            return .{ .len = len, .next = next orelse pos + 1 };
        }
        if (b & 0xC0 == 0xC0) {
            if (pos + 1 >= msg.len) return null;
            jumps += 1;
            if (jumps > 64) return null;
            if (next == null) next = pos + 2;
            const target = (@as(usize, b & 0x3F) << 8) | msg[pos + 1];
            if (target >= pos) return null; // a pointer must point back, which also rules out loops
            pos = target;
            continue;
        }
        if (b & 0xC0 != 0) return null;
        const l: usize = b;
        if (pos + 1 + l > msg.len) return null;
        const sep: usize = if (len == 0) 0 else 1;
        if (len + sep + l > MAX_NAME) return null;
        if (sep == 1) out[len] = '.';
        @memcpy(out[len + sep ..][0..l], msg[pos + 1 ..][0..l]);
        len += sep + l;
        pos += 1 + l;
    }
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

fn be16(msg: []const u8, at: usize) u16 {
    return @as(u16, msg[at]) << 8 | msg[at + 1];
}

/// Read `msg` (a whole reply) for addresses of `qname`. True when at least one address was found; false for no address (only
/// CNAMEs, records for other owners, a CNAME loop) or a malformed message.
pub fn parse(msg: []const u8, qname: []const u8, out: *Answer) bool {
    out.* = .{};
    if (msg.len < 12 or qname.len == 0 or qname.len > MAX_NAME) return false;
    const qdcount = be16(msg, 4);
    const ancount = be16(msg, 6);
    var pos: usize = 12;
    var scratch: [MAX_NAME + 1]u8 = undefined;
    for (0..qdcount) |_| {
        const d = readName(msg, pos, &scratch) orelse return false;
        pos = d.next + 4;
        if (pos > msg.len) return false;
    }
    // The expected name lives at the end of out.names (it is the last entry); aliases are pushed in front of it.
    @memcpy(out.names[0..qname.len], qname);
    out.ends[0] = @intCast(qname.len);
    for (0..ancount) |_| {
        var owner: [MAX_NAME + 1]u8 = undefined;
        const od = readName(msg, pos, &owner) orelse return false;
        pos = od.next;
        if (pos + 10 > msg.len) return false;
        const rtype = be16(msg, pos);
        const rclass = be16(msg, pos + 2);
        const rdlen = be16(msg, pos + 8);
        pos += 10;
        if (pos + rdlen > msg.len) return false;
        const rdata = pos;
        pos += rdlen;
        if (rclass != CLASS_IN) continue;
        if (rtype == TYPE_CNAME) {
            var target: [MAX_NAME + 1]u8 = undefined;
            const td = readName(msg, rdata, &target) orelse return false;
            const cur = out.canonName();
            if (eqlIgnoreCase(target[0..td.len], cur)) continue; // no progress (a CNAME to itself)
            if (out.nalias >= MAX_ALIASES) continue;
            // The current expected name becomes an alias; the target is the new expected name.
            const start: usize = out.ends[out.nalias];
            if (start + td.len > out.names.len) continue;
            @memcpy(out.names[start..][0..td.len], target[0..td.len]);
            out.nalias += 1;
            out.ends[out.nalias] = @intCast(start + td.len);
            continue;
        }
        if (rtype == TYPE_A and rdlen == 4 and eqlIgnoreCase(owner[0..od.len], out.canonName())) {
            if (out.naddr < MAX_ADDRS) {
                @memcpy(&out.addrs[out.naddr], msg[rdata..][0..4]);
                out.naddr += 1;
            }
        }
    }
    return out.naddr > 0;
}

/// Read a reply to a PTR query for `qname` (an in-addr.arpa or ip6.arpa name), as glibc's getanswer_ptr does (glibc 2.44, measured):
/// a CNAME for the expected name moves it on (RFC 2317 classless delegation), and the first PTR record whose owner is the expected
/// name gives the host name, without a trailing dot, its case kept. Other records, other owners and further PTRs are skipped. The
/// name lands in out.canonName(); true when one was found.
pub fn parsePtr(msg: []const u8, qname: []const u8, out: *Answer) bool {
    out.* = .{};
    if (msg.len < 12 or qname.len == 0 or qname.len > MAX_NAME) return false;
    const qdcount = be16(msg, 4);
    const ancount = be16(msg, 6);
    var pos: usize = 12;
    var scratch: [MAX_NAME + 1]u8 = undefined;
    for (0..qdcount) |_| {
        const d = readName(msg, pos, &scratch) orelse return false;
        pos = d.next + 4;
        if (pos > msg.len) return false;
    }
    var expected: [MAX_NAME + 1]u8 = undefined;
    @memcpy(expected[0..qname.len], qname);
    var exp_len = qname.len;
    for (0..ancount) |_| {
        var owner: [MAX_NAME + 1]u8 = undefined;
        const od = readName(msg, pos, &owner) orelse return false;
        pos = od.next;
        if (pos + 10 > msg.len) return false;
        const rtype = be16(msg, pos);
        const rclass = be16(msg, pos + 2);
        const rdlen = be16(msg, pos + 8);
        pos += 10;
        if (pos + rdlen > msg.len) return false;
        const rdata = pos;
        pos += rdlen;
        if (rclass != CLASS_IN or !eqlIgnoreCase(owner[0..od.len], expected[0..exp_len])) continue;
        var target: [MAX_NAME + 1]u8 = undefined;
        if (rtype == TYPE_CNAME) {
            const td = readName(msg, rdata, &target) orelse return false;
            @memcpy(expected[0..td.len], target[0..td.len]);
            exp_len = td.len;
            continue;
        }
        if (rtype == TYPE_PTR) {
            const td = readName(msg, rdata, &target) orelse return false;
            if (td.len == 0) continue;
            @memcpy(out.names[0..td.len], target[0..td.len]);
            out.ends[0] = @intCast(td.len);
            return true;
        }
    }
    return false;
}

const hex = "0123456789abcdef";

/// "d.c.b.a.in-addr.arpa" for a.b.c.d, into `buf`.
pub fn reverseName4(ip: [4]u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        var v = ip[i];
        var digits: [3]u8 = undefined;
        var k: usize = 0;
        while (true) {
            digits[k] = '0' + v % 10;
            k += 1;
            v /= 10;
            if (v == 0) break;
        }
        while (k > 0) {
            k -= 1;
            buf[n] = digits[k];
            n += 1;
        }
        buf[n] = '.';
        n += 1;
    }
    const tail = "in-addr.arpa";
    @memcpy(buf[n..][0..tail.len], tail);
    return buf[0 .. n + tail.len];
}

/// The 32 nibbles of `ip` from the last, dot-separated, then "ip6.arpa" (RFC 3596), into `buf` (at least 73 bytes).
pub fn reverseName6(ip: [16]u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[n] = hex[ip[i] & 0xF];
        buf[n + 1] = '.';
        buf[n + 2] = hex[ip[i] >> 4];
        buf[n + 3] = '.';
        n += 4;
    }
    const tail = "ip6.arpa";
    @memcpy(buf[n..][0..tail.len], tail);
    return buf[0 .. n + tail.len];
}

/// An answer of one address under `name` (a literal or a static name, answered without a query).
pub fn single(out: *Answer, name: []const u8, ip: [4]u8) void {
    out.* = .{};
    const n = @min(name.len, MAX_NAME);
    @memcpy(out.names[0..n], name[0..n]);
    out.ends[0] = @intCast(n);
    out.addrs[0] = ip;
    out.naddr = 1;
}

/// The answer as dns_query (507) hands it to user space: the address count, the alias count, the addresses (4 bytes each), then
/// the canonical name and each alias in order, NUL-terminated. null when `dst` is too small.
pub fn encode(a: *const Answer, dst: []u8) ?usize {
    var need: usize = 2 + @as(usize, a.naddr) * 4 + a.canonName().len + 1;
    for (0..a.nalias) |i| need += a.alias(i).len + 1;
    if (dst.len < need) return null;
    dst[0] = a.naddr;
    dst[1] = a.nalias;
    var p: usize = 2;
    for (a.addrs[0..a.naddr]) |ad| {
        @memcpy(dst[p..][0..4], &ad);
        p += 4;
    }
    const c = a.canonName();
    @memcpy(dst[p..][0..c.len], c);
    p += c.len;
    dst[p] = 0;
    p += 1;
    for (0..a.nalias) |i| {
        const s = a.alias(i);
        @memcpy(dst[p..][0..s.len], s);
        p += s.len;
        dst[p] = 0;
        p += 1;
    }
    return p;
}
