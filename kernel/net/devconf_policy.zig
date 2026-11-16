//! net.ipv4.conf.<dev>.proxy_arp: the per-device proxy ARP switch (net/ipv4/devinet.c, /proc/sys/net/ipv4/conf/{all,default,lo,
//! eth0}/proxy_arp; arp_req_set_proxy sets it from SIOCSARP / SIOCDARP with ATF_PUBL and netmask 0). Each of the four is its own int:
//! lo and the NIC carry addresses, so on Linux their values no longer follow default (ipv4_devconf_setall), and all is separate too.
//! The files read and write like proc_dointvec with one value (kernel/sysctl.c do_proc_dointvec, proc_get_long), measured in hello383.
const std = @import("std");

pub const EINVAL: i64 = -22;

pub const Dev = enum(u8) { all = 0, default = 1, lo = 2, eth = 3 };

/// What a path below /proc names inside sys/net/ipv4/conf: the conf directory, a device's directory, or its proxy_arp file.
pub const Path = union(enum) {
    conf_dir,
    dev_dir: Dev,
    proxy_arp: Dev,
};

/// The device a conf directory name stands for; eth0 only while the NIC is up (Linux lists the devices that exist).
pub fn devByName(name: []const u8, nic_active: bool) ?Dev {
    if (std.mem.eql(u8, name, "all")) return .all;
    if (std.mem.eql(u8, name, "default")) return .default;
    if (std.mem.eql(u8, name, "lo")) return .lo;
    if (nic_active and std.mem.eql(u8, name, "eth0")) return .eth;
    return null;
}

/// The directory name of a device.
pub fn devName(dev: Dev) []const u8 {
    return switch (dev) {
        .all => "all",
        .default => "default",
        .lo => "lo",
        .eth => "eth0",
    };
}

/// `rest` is the path after "/proc/" ("sys/net/ipv4/conf/eth0/proxy_arp"); a directory may end in "/". Null for anything else,
/// an unknown device or an unknown file included (ENOENT).
pub fn lookup(rest: []const u8, nic_active: bool) ?Path {
    const prefix = "sys/net/ipv4/conf";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    var tail = rest[prefix.len..];
    if (tail.len == 0 or std.mem.eql(u8, tail, "/")) return .conf_dir;
    if (tail[0] != '/') return null;
    tail = tail[1..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse {
        return .{ .dev_dir = devByName(tail, nic_active) orelse return null };
    };
    const dev = devByName(tail[0..slash], nic_active) orelse return null;
    const file = tail[slash + 1 ..];
    if (file.len == 0) return .{ .dev_dir = dev };
    if (std.mem.eql(u8, file, "proxy_arp")) return .{ .proxy_arp = dev };
    return null;
}

/// One write of `text` at offset 0: the bytes the write returns and, when it parsed, the new value.
pub const IntWrite = struct { ret: i64, value: ?i32 = null };

/// proc_dointvec with one int: leading blanks, an optional '-', a base-0 number (0x hex, 0 octal) of at most 20 characters that
/// fits an int, then a blank, a tab, a newline or the end; trailing blanks are consumed and anything after them is left unread. An
/// empty write returns 0; only blanks, a bad number or a bad character after it are EINVAL. At most 4095 bytes are looked at.
pub fn writeInt(text: []const u8) IntWrite {
    if (text.len == 0) return .{ .ret = 0 };
    const p = text[0..@min(text.len, 4095)];
    var i: usize = 0;
    while (i < p.len and isSpace(p[i])) i += 1;
    if (i >= p.len) return .{ .ret = EINVAL };
    const left = p.len - i;
    const window = p[i .. i + @min(left, 21)];
    var j: usize = 0;
    var neg = false;
    if (window[0] == '-' and left > 1) {
        neg = true;
        j = 1;
    }
    if (j >= window.len or !std.ascii.isDigit(window[j])) return .{ .ret = EINVAL };
    const u = parseUlong(window, &j) orelse return .{ .ret = EINVAL };
    if (j == 21) return .{ .ret = EINVAL };
    // j < 21 here, so when input is left over the window still holds the character after the number.
    if (j < left and !isSep(window[j])) return .{ .ret = EINVAL };
    const max: u64 = std.math.maxInt(i32);
    const value: i32 = if (neg) blk: {
        if (u > max + 1) return .{ .ret = EINVAL };
        break :blk @intCast(-@as(i64, @intCast(u)));
    } else blk: {
        if (u > max) return .{ .ret = EINVAL };
        break :blk @intCast(u);
    };
    i += j;
    while (i < p.len and isSpace(p[i])) i += 1;
    return .{ .ret = @intCast(text.len - (p.len - i)), .value = value };
}

/// The text a proxy_arp file reads: the value and a newline. Returns the bytes written.
pub fn formatInt(out: []u8, v: i32) usize {
    const s = std.fmt.bufPrint(out, "{d}\n", .{v}) catch return 0;
    return s.len;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn isSep(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// strtoul with base 0 (_parse_integer_fixup_radix): "0x" and a hex digit is hex, another leading 0 octal, else decimal. Stops at
/// the first character that is no digit of the base; null on 64-bit overflow.
fn parseUlong(text: []const u8, pos: *usize) ?u64 {
    var i = pos.*;
    var base: u64 = 10;
    if (i < text.len and text[i] == '0') {
        if (i + 2 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X') and std.ascii.isHex(text[i + 2])) {
            base = 16;
            i += 2;
        } else base = 8;
    }
    var v: u64 = 0;
    while (i < text.len) : (i += 1) {
        const d: u64 = std.fmt.charToDigit(text[i], 16) catch break;
        if (d >= base) break;
        v = std.math.mul(u64, v, base) catch return null;
        v = std.math.add(u64, v, d) catch return null;
    }
    pos.* = i;
    return v;
}
