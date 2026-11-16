//! ARP decisions kept free of device and lock state: the frames that wait for a neighbour's MAC (Linux __neigh_event_send queues
//! them on the neighbour and arp_solicit asks for it; neigh_update sends them once the reply comes, a neighbour that never answers
//! goes NUD_FAILED and its queue is dropped), and the arpreq of the SIOCGARP / SIOCDARP ioctls (net/ipv4/arp.c arp_ioctl).

const std = @import("std");

/// Frames waiting for a MAC, all neighbours together.
pub const MAX_PENDING: usize = 8;
/// arp_solicit is repeated every retrans_time (1 s) and the neighbour fails after mcast_solicit (3) probes.
pub const PROBE_INTERVAL_NS: u64 = 1_000_000_000;
pub const PROBES: u64 = 3;
pub const HOLD_NS: u64 = PROBE_INTERVAL_NS * PROBES;

pub const Slot = struct {
    used: bool = false,
    hop: [4]u8 = .{ 0, 0, 0, 0 },
    /// When the frame was queued (it is dropped HOLD_NS later) and when its neighbour is asked again.
    queued_ns: u64 = 0,
    next_probe_ns: u64 = 0,
};

/// A frame waiting for an IPv6 next hop's MAC. Neighbor Discovery itself repeats the solicitations (ndp.timerTick), so only the
/// hold time applies.
pub const Slot6 = struct {
    used: bool = false,
    hop: [16]u8 = @splat(0),
    queued_ns: u64 = 0,
};

/// The slot a new frame takes: a free or expired one, else the oldest (__neigh_event_send drops the oldest queued frame when the
/// queue is over its limit).
/// `slots` is an array or slice of Slot or Slot6.
pub fn pickSlot(slots: anytype, now: u64) usize {
    var oldest: usize = 0;
    for (slots, 0..) |s, i| {
        if (!s.used or expired(s, now)) return i;
        if (s.queued_ns < slots[oldest].queued_ns) oldest = i;
    }
    return oldest;
}

pub fn expired(s: anytype, now: u64) bool {
    return s.used and now -| s.queued_ns >= HOLD_NS;
}

/// Whether the neighbour of a frame queued for `hop` has to be asked now: no other frame for it is queued yet (that one already
/// asked and keeps asking).
pub fn firstForHop(slots: []const Slot, hop: [4]u8, now: u64) bool {
    for (slots) |s| {
        if (s.used and !expired(s, now) and @as(u32, @bitCast(s.hop)) == @as(u32, @bitCast(hop))) return false;
    }
    return true;
}

/// Whether the timer has to ask `s`'s neighbour again.
pub fn probeDue(s: Slot, now: u64) bool {
    return s.used and !expired(s, now) and now >= s.next_probe_ns;
}

// ── SIOCGARP / SIOCDARP ──

pub const SIOCDARP: u64 = 0x8953;
pub const SIOCGARP: u64 = 0x8954;
pub const SIOCSARP: u64 = 0x8955;
pub const ATF_COM: u32 = 0x02;
pub const ATF_PERM: u32 = 0x04;
pub const ATF_PUBL: u32 = 0x08;
pub const ATF_NETMASK: u32 = 0x20;
pub const ATF_DONTPUB: u32 = 0x40;
pub const ARPHRD_ETHER: u16 = 1;
pub const ARPHRD_LOOPBACK: u16 = 772;
/// struct arpreq: arp_pa (sockaddr) @0, arp_ha @16, arp_flags @32, arp_netmask @36, arp_dev[16] @52.
pub const ARPREQ_SIZE: usize = 68;

const EPERM: i64 = -1;
const ENXIO: i64 = -6;
const EINVAL: i64 = -22;
const ENODEV: i64 = -19;
const EPFNOSUPPORT: i64 = -96;
const EOPNOTSUPP: i64 = -95;
const ENETUNREACH: i64 = -101;

pub const Device = enum { none, lo, eth };

pub const Request = struct { ip: [4]u8, dev: Device };

/// arp_ioctl's checks before the table is looked at: CAP_NET_ADMIN for SIOCDARP, an AF_INET protocol address, no netmask or
/// "don't publish" flag without ATF_PUBL, a netmask (when given) of /32, and a device that exists (arp_req_dev_by_name; SIOCGARP
/// needs one named, SIOCDARP without a name means the NIC, the only interface an off-host address routes through). Proxy entries
/// (ATF_PUBL) are not kept, so asking about one is ENXIO.
pub fn parseRequest(cmd: u64, req: *const [ARPREQ_SIZE]u8, net_admin: bool, nic_active: bool) union(enum) { ok: Request, err: i64 } {
    if (cmd == SIOCDARP and !net_admin) return .{ .err = EPERM };
    if (readU16(req, 0) != 2) return .{ .err = EPFNOSUPPORT };
    const flags = readU32(req, 32);
    if ((flags & ATF_PUBL) == 0 and (flags & (ATF_NETMASK | ATF_DONTPUB)) != 0) return .{ .err = EINVAL };
    if ((flags & ATF_NETMASK) != 0) {
        const mask = readU32(req, 40);
        if (mask != 0 and mask != 0xffff_ffff) return .{ .err = EINVAL };
    }
    const named = req[52] != 0;
    if (cmd == SIOCGARP and !named) return .{ .err = ENODEV };
    const dev: Device = if (named) deviceByName(req[52..68], nic_active) else if (nic_active) .eth else .none;
    if (dev == .none) return .{ .err = ENODEV };
    if ((flags & ATF_PUBL) != 0) return .{ .err = ENXIO };
    return .{ .ok = .{ .ip = req[4..8].*, .dev = dev } };
}

/// Where an address without a device name routes (arp_req_dev: ip_route_output with RT_SCOPE_LINK): this host's own addresses to
/// lo, on-link ones to the NIC; anything else has no link route.
pub const Route = enum { lo, link, unreachable_ };

pub const SetRequest = struct {
    ip: [4]u8,
    dev: Device,
    /// The MAC to install; null without ATF_COM (the entry keeps the MAC it has, and a new one cannot be made).
    mac: ?[6]u8,
    /// ATF_PERM: NUD_PERMANENT, which received ARP no longer changes.
    perm: bool,
};

/// SIOCSARP (arp_ioctl, arp_req_dev, arp_req_set): CAP_NET_ADMIN, an AF_INET address and the netmask rules shared with the other
/// requests; the device is the named one (ENODEV when unknown; hardware family 0 then means the device's own type, and with ATF_COM
/// another family is EINVAL) or, unnamed, the one the address routes through (ENETUNREACH off-link). Proxy entries (ATF_PUBL) are
/// not kept (EOPNOTSUPP). The hardware family has to be the device type: ARPHRD_ETHER on the NIC, ARPHRD_LOOPBACK on lo.
pub fn parseSet(req: *const [ARPREQ_SIZE]u8, net_admin: bool, nic_active: bool, route: Route) union(enum) { ok: SetRequest, err: i64 } {
    if (!net_admin) return .{ .err = EPERM };
    if (readU16(req, 0) != 2) return .{ .err = EPFNOSUPPORT };
    var flags = readU32(req, 32);
    if ((flags & ATF_PUBL) == 0 and (flags & (ATF_NETMASK | ATF_DONTPUB)) != 0) return .{ .err = EINVAL };
    if ((flags & ATF_NETMASK) != 0) {
        const mask = readU32(req, 40);
        if (mask != 0 and mask != 0xffff_ffff) return .{ .err = EINVAL };
    }
    var family = readU16(req, 16);
    var dev: Device = .none;
    if (req[52] != 0) {
        dev = deviceByName(req[52..68], nic_active);
        if (dev == .none) return .{ .err = ENODEV };
        if (family == 0) family = devType(dev);
        if ((flags & ATF_COM) != 0 and family != devType(dev)) return .{ .err = EINVAL };
    } else if ((flags & ATF_PUBL) == 0) {
        dev = switch (route) {
            .lo => .lo,
            .link => if (nic_active) .eth else return .{ .err = ENETUNREACH },
            .unreachable_ => return .{ .err = ENETUNREACH },
        };
    }
    if ((flags & ATF_PUBL) != 0) return .{ .err = EOPNOTSUPP };
    if (family != devType(dev)) return .{ .err = EINVAL };
    if ((flags & ATF_PERM) != 0) flags |= ATF_COM;
    return .{ .ok = .{
        .ip = req[4..8].*,
        .dev = dev,
        .mac = if ((flags & ATF_COM) != 0) req[18..24].* else null,
        .perm = (flags & ATF_PERM) != 0,
    } };
}

fn devType(dev: Device) u16 {
    return if (dev == .lo) ARPHRD_LOOPBACK else ARPHRD_ETHER;
}

fn deviceByName(name: []const u8, nic_active: bool) Device {
    const n = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
    if (std.mem.eql(u8, name[0..n], "lo")) return .lo;
    if (nic_active and std.mem.eql(u8, name[0..n], "eth0")) return .eth;
    return .none;
}

/// The SIOCGARP answer for an entry with MAC `mac` on `dev`: the hardware address (family ARPHRD_ETHER) and ATF_COM, with ATF_PERM
/// too for a permanent entry (arp_state_to_flags); the request's device name stays. lo keeps no entries (NUD_NOARP), so nothing is
/// found there.
pub fn answerGet(req: *[ARPREQ_SIZE]u8, mac: [6]u8, perm: bool) void {
    @memset(req[16..32], 0);
    req[16] = @truncate(ARPHRD_ETHER);
    req[17] = 0;
    @memcpy(req[18..24], &mac);
    req[32] = @truncate(if (perm) ATF_COM | ATF_PERM else ATF_COM);
    req[33] = 0;
    req[34] = 0;
    req[35] = 0;
}

/// The errno of a SIOCGARP / SIOCDARP that found no entry (arp_req_get / arp_invalidate).
pub fn notFound() i64 {
    return ENXIO;
}

fn readU16(b: []const u8, at: usize) u16 {
    return @as(u16, b[at]) | (@as(u16, b[at + 1]) << 8);
}

fn readU32(b: []const u8, at: usize) u32 {
    return @as(u32, b[at]) | (@as(u32, b[at + 1]) << 8) | (@as(u32, b[at + 2]) << 16) | (@as(u32, b[at + 3]) << 24);
}

// ── /proc/net/arp ──

/// arp_seq_show's header line.
pub const PROC_HEADER = "IP address       HW type     Flags       HW address            Mask     Device\n";

/// One /proc/net/arp line, as arp_format_neigh_entry prints it: "%-16s 0x%-10x0x%-10x%-17s     *        %s\n" (address, hardware
/// type, the SIOCGARP flags, MAC, device). Returns the bytes written to `out`, 0 when it does not fit.
pub fn formatProcLine(out: []u8, ip: [4]u8, mac: [6]u8, perm: bool, dev: []const u8) usize {
    var tmp: [128]u8 = undefined;
    var addr: [16]u8 = undefined;
    const a = std.fmt.bufPrint(&addr, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return 0;
    var hw: [17]u8 = undefined;
    const h = std.fmt.bufPrint(&hw, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch return 0;
    const flags: u32 = if (perm) ATF_COM | ATF_PERM else ATF_COM;
    var ty: [12]u8 = undefined;
    const t = std.fmt.bufPrint(&ty, "{x}", .{ARPHRD_ETHER}) catch return 0;
    var fl: [12]u8 = undefined;
    const f = std.fmt.bufPrint(&fl, "{x}", .{flags}) catch return 0;
    const line = std.fmt.bufPrint(&tmp, "{s: <16} 0x{s: <10}0x{s: <10}{s: <17}     *        {s}\n", .{ a, t, f, h, dev }) catch return 0;
    if (line.len > out.len) return 0;
    @memcpy(out[0..line.len], line);
    return line.len;
}
