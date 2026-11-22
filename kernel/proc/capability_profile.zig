pub const SysCap = packed struct(u32) {
    cap_net_raw: bool = false,
    cap_net_bind: bool = false,
    cap_sys_admin: bool = false,
    cap_sys_ptrace: bool = false,
    cap_kill: bool = false,
    cap_setuid: bool = false,
    cap_setgid: bool = false,
    cap_chown: bool = false,
    cap_dac_override: bool = false,
    cap_fowner: bool = false,
    cap_mknod: bool = false,
    cap_sys_mount: bool = false,
    cap_sys_reboot: bool = false,
    cap_sys_resource: bool = false,
    cap_net_admin: bool = false,
    cap_ipc_lock: bool = false,
    cap_sys_rawio: bool = false,
    cap_sys_time: bool = false,
    /// Raise scheduling priority / renice another user's process.
    cap_sys_nice: bool = false,
    /// Take a file lease on a file the caller does not own (Linux CAP_LEASE, 28).
    cap_lease: bool = false,
    _pad: u12 = 0,
};

pub const ALL_CAPS: SysCap = .{
    .cap_net_raw = true,
    .cap_net_bind = true,
    .cap_sys_admin = true,
    .cap_sys_ptrace = true,
    .cap_kill = true,
    .cap_setuid = true,
    .cap_setgid = true,
    .cap_chown = true,
    .cap_dac_override = true,
    .cap_fowner = true,
    .cap_mknod = true,
    .cap_sys_mount = true,
    .cap_sys_reboot = true,
    .cap_sys_resource = true,
    .cap_net_admin = true,
    .cap_ipc_lock = true,
    .cap_sys_rawio = true,
    .cap_sys_time = true,
    .cap_sys_nice = true,
    .cap_lease = true,
};

pub const NO_CAPS: SysCap = .{};

pub const LaunchProfile = struct {
    uid: u32,
    gid: u32,
    caps: SysCap,
    initial_init: bool,
};

pub const DEFAULT_UID: u32 = 1000;
pub const DEFAULT_GID: u32 = 1000;

pub const initial_init_profile: LaunchProfile = .{
    .uid = 0,
    .gid = 0,
    .caps = ALL_CAPS,
    .initial_init = true,
};

pub const default_user_profile: LaunchProfile = .{
    .uid = DEFAULT_UID,
    .gid = DEFAULT_GID,
    .caps = NO_CAPS,
    .initial_init = false,
};

pub fn profileForLaunch(name: []const u8, initial_init_caller: bool, initial_init: bool) LaunchProfile {
    if (initial_init and std.mem.eql(u8, name, "init")) return initial_init_profile;
    if (!initial_init_caller) return default_user_profile;

    if (std.mem.eql(u8, name, "hello14") or std.mem.eql(u8, name, "hello15")) return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_raw = true }, .initial_init = false };
    if (std.mem.eql(u8, name, "hello51") or std.mem.eql(u8, name, "hello52")) {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_sys_rawio = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello54")) {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_sys_rawio = true, .cap_kill = true }, .initial_init = false };
    }
    // Legacy ext2 fixture programs write in the root-owned 0755 root directory.
    // They exercise filesystem mechanics, not DAC; keep their pre-DAC fixture
    // privileges explicit rather than weakening the filesystem checks.
    if (std.mem.eql(u8, name, "hello21") or std.mem.eql(u8, name, "hello23") or
        std.mem.eql(u8, name, "hello24") or std.mem.eql(u8, name, "hello25") or
        std.mem.eql(u8, name, "hello29") or std.mem.eql(u8, name, "hello77"))
    {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_dac_override = true, .cap_chown = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello13") or std.mem.eql(u8, name, "hello58")) {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_kill = true }, .initial_init = false };
    }
    // Realtime-scheduling acceptance tests switch themselves into SCHED_FIFO/RR.
    if (std.mem.eql(u8, name, "hello44") or std.mem.eql(u8, name, "hello104") or
        std.mem.eql(u8, name, "hello108"))
    {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_sys_nice = true }, .initial_init = false };
    }
    // Swap acceptance tests enable and drain swap devices (system-wide state).
    if (std.mem.eql(u8, name, "hello96") or std.mem.eql(u8, name, "hello98") or
        std.mem.eql(u8, name, "hello99") or std.mem.eql(u8, name, "hello100") or
        std.mem.eql(u8, name, "hello101") or std.mem.eql(u8, name, "hello138"))
    {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_sys_admin = true }, .initial_init = false };
    }
    // Identity-change test: starts as root holding only the two ID capabilities,
    // so dropping them is observable through capget.
    // hello119 (rename) uses it the same way: a root-owned /tmp file, then a
    // child dropping to uid 1000 meets the sticky-directory rule. hello123
    // (utimensat) drops to uid 1000 in a child to check who may set times; hello126
    // (access) splits real and effective ids in a child. hello253 (/proc/<pid>/maps) is root with a child that drops to uid 1000 to read root's map. hello259 (/proc/<pid>/status) sets supplementary groups in a child. hello260 (capget/capset) starts with exactly these two capabilities. hello281 (sticky directories) creates root-owned entries, then a child drops to uid 1000. hello282 (process_vm) has a child drop to uid 1000 and read the root parent.
    if (std.mem.eql(u8, name, "hello115") or std.mem.eql(u8, name, "hello119") or std.mem.eql(u8, name, "hello123") or std.mem.eql(u8, name, "hello126") or std.mem.eql(u8, name, "hello253") or std.mem.eql(u8, name, "hello259") or std.mem.eql(u8, name, "hello260") or std.mem.eql(u8, name, "hello281") or std.mem.eql(u8, name, "hello282")) {
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true, .cap_setgid = true }, .initial_init = false };
    }
    // Socket-option acceptance test: holds CAP_NET_ADMIN (SO_MARK, SO_PRIORITY > 6) as uid 0 so that
    // setuid() in a child drops it and the unprivileged refusals are observable.
    if (std.mem.eql(u8, name, "hello317")) {
        // adjtimex test: CAP_SYS_TIME for the TAI offset and ADJ_SETOFFSET, CAP_SETUID so a child's setuid() leaves it
        // unprivileged and the EPERM refusals are observable.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_sys_time = true, .cap_setuid = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello319")) {
        // Lease permission test: uid 1000 holding only CAP_LEASE, dropped with capset to see the EACCES refusals.
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_lease = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello183") or std.mem.eql(u8, name, "hello322")) {
        // Starts as root with CAP_SETUID only (no CAP_NET_BIND) so the child's setuid() leaves it unprivileged,
        // while the parent's own privileged-port expectations do not apply (it binds only high ports).
        // hello322 (SIGIO permission) has children take uid/euid/suid combinations with setresuid.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello328")) {
        // setfsuid/setfsgid test: root holding the id capabilities and the file-system ones (DAC override, fowner, chown), so moving
        // fsuid away from 0 visibly drops the latter from CapEff and an unprivileged child sees the setfsuid refusals.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true, .cap_setgid = true, .cap_dac_override = true, .cap_fowner = true, .cap_chown = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello330")) {
        // SO_REUSEPORT owner test: root holding CAP_SETUID, which also lets setfsuid move the fs id, so sockets can be created under one
        // uid and bound under another.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello329")) {
        // /proc/<pid>/maps and fd access test: root holding the id capabilities plus CAP_SYS_PTRACE and CAP_DAC_OVERRIDE, so observers
        // can keep exactly one of the latter two with capset.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true, .cap_setgid = true, .cap_sys_ptrace = true, .cap_dac_override = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello179")) {
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_admin = true, .cap_setuid = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello371") or std.mem.eql(u8, name, "hello372") or std.mem.eql(u8, name, "hello373") or std.mem.eql(u8, name, "hello374")) {
        // Ping socket tests (IPv4 and IPv6): root, which alone may write /proc/sys/net/ipv4/ping_group_range (mode 0644), holding CAP_SETUID and
        // CAP_SETGID so hello373's children take other uids, gids and supplementary groups, and CAP_NET_RAW for its raw socket.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true, .cap_setgid = true, .cap_net_raw = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello389") or std.mem.eql(u8, name, "hello390") or std.mem.eql(u8, name, "hello391") or std.mem.eql(u8, name, "hello392") or std.mem.eql(u8, name, "hello393") or std.mem.eql(u8, name, "hello394") or std.mem.eql(u8, name, "hello395") or std.mem.eql(u8, name, "hello396") or std.mem.eql(u8, name, "hello397") or std.mem.eql(u8, name, "hello398") or std.mem.eql(u8, name, "hello399") or std.mem.eql(u8, name, "hello400") or std.mem.eql(u8, name, "hello401") or std.mem.eql(u8, name, "hello402") or std.mem.eql(u8, name, "hello403") or std.mem.eql(u8, name, "hello404") or std.mem.eql(u8, name, "hello406") or std.mem.eql(u8, name, "hello407") or std.mem.eql(u8, name, "hello408") or std.mem.eql(u8, name, "hello410") or std.mem.eql(u8, name, "hello411") or std.mem.eql(u8, name, "hello413") or std.mem.eql(u8, name, "hello414") or std.mem.eql(u8, name, "hello418") or std.mem.eql(u8, name, "hello419") or std.mem.eql(u8, name, "hello420") or std.mem.eql(u8, name, "hello425") or std.mem.eql(u8, name, "hello426") or std.mem.eql(u8, name, "hello427") or std.mem.eql(u8, name, "hello428") or std.mem.eql(u8, name, "hello429") or std.mem.eql(u8, name, "hello430") or std.mem.eql(u8, name, "hello439") or std.mem.eql(u8, name, "hello451") or std.mem.eql(u8, name, "hello452") or std.mem.eql(u8, name, "hello453") or std.mem.eql(u8, name, "hello454") or std.mem.eql(u8, name, "hello455") or std.mem.eql(u8, name, "hello461") or std.mem.eql(u8, name, "hello462") or std.mem.eql(u8, name, "hello464") or std.mem.eql(u8, name, "hello466") or std.mem.eql(u8, name, "hello467") or std.mem.eql(u8, name, "hello471") or std.mem.eql(u8, name, "hello475")) {
        // Raw ICMP socket tests: socket(AF_INET[6], SOCK_RAW, IPPROTO_ICMP[V6]) wants CAP_NET_RAW (inet_create); root also lets hello390
        // write /proc/sys/net/ipv4/ping_group_range (mode 0644) for its ping sockets.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_raw = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello382")) {
        // Proxy ARP test: CAP_NET_ADMIN to set and remove proxy entries.
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello481")) {
        // fs.pipe-max-size: root opens the sysctl for writing (mode 0644), without CAP_SYS_RESOURCE so the limit applies to it.
        return .{ .uid = 0, .gid = 0, .caps = NO_CAPS, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello494")) {
        // The test keeps CAP_NET_ADMIN for the sysctl and drops CAP_NET_BIND_SERVICE before bind.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello493")) {
        // Root/CAP_NET_ADMIN writes ip_local_port_range; the UDP/TCP sockets need no extra capability.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello492")) {
        // Root/CAP_NET_ADMIN opens the two network sysctls for writing; UDP itself needs no extra capability.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello491")) {
        // TRANSPARENT and raw/ping sockets: CAP_NET_RAW; writing ping_group_range also needs CAP_NET_ADMIN.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_raw = true, .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello490")) {
        // Nonlocal bind on raw sockets: only CAP_NET_RAW is needed for their creation.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_raw = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello487")) {
        // SOL_IP / SOL_IPV6 option sweep: raw sockets (CAP_NET_RAW, the only capability, matching the host measurement).
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_raw = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello484")) {
        // IPV6_FLOWLABEL_MGR: root without CAP_NET_ADMIN (a linger past 150 s is EPERM); CAP_SETUID so a child takes uid 1000;
        // CAP_NET_RAW for the raw ICMPv6 socket of item L.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true, .cap_net_raw = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello482")) {
        // fs.pipe-user-pages-{soft,hard}: root writes the sysctls and keeps CAP_SYS_RESOURCE (not limited); a child's setresuid to
        // 4242 drops both capabilities, so its pipes meet the limits.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_setuid = true, .cap_sys_resource = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello476")) {
        // Raw sockets (CAP_NET_RAW), SO_MARK (CAP_NET_ADMIN) and root to open net.ipv4.ping_group_range for its ping socket.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_raw = true, .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello472")) {
        // SO_RCVMARK / SO_RCVPRIORITY: uid 1000 with CAP_NET_ADMIN sets SO_MARK and sends a SO_MARK control message (sk_setsockopt,
        // __sock_cmsg_send).
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello463")) {
        // net.ipv6.auto_flowlabels: uid 1000 with CAP_NET_ADMIN opens the sysctl for writing (net_ctl_permissions).
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello387")) {
        // net.ipv4.conf.<dev>.route_localnet: uid 1000 with CAP_NET_ADMIN writes the sysctls (net_ctl_permissions).
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello386")) {
        // A 127/8-bound socket cannot reach out through the NIC: root for ping_group_range, CAP_NET_RAW for the ping socket and
        // CAP_NET_BIND_SERVICE for the low ports the test binds (40386, 40387, 80).
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_raw = true, .cap_net_bind = true, .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello405")) {
        // ARP neighbour unreachability detection: uid 1000 with CAP_NET_ADMIN for SIOCSARP / SIOCGARP / SIOCDARP.
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello384")) {
        // Incomplete IPv4 neighbours: uid 1000 with CAP_NET_ADMIN for the ARP ioctls (SIOCSARP / SIOCGARP / SIOCDARP).
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello383")) {
        // net.ipv4.conf.<dev>.proxy_arp: uid 1000 with CAP_NET_ADMIN, which sets the switch with SIOCSARP and opens the sysctls for
        // writing (net_ctl_permissions); a child drops the capability with capset and gets EACCES.
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello380")) {
        // Full ARP cache test: CAP_NET_ADMIN to fill the cache with SIOCSARP and remove the entries again.
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello378")) {
        // /proc/net/arp test: CAP_NET_ADMIN to set and remove the entries it then looks for.
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello377")) {
        // SIOCSARP test: root holding CAP_NET_ADMIN to set entries, and CAP_SETUID so a child's setuid(1000) drops it and the EPERM
        // refusal is observable.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_admin = true, .cap_setuid = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello376")) {
        // IPv6 neighbour-queue test: root, to write ping_group_range for its IPv6 ping sockets.
        return .{ .uid = 0, .gid = 0, .caps = .{}, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello375")) {
        // Neighbour-table test: root, to write ping_group_range for its ping socket, holding CAP_NET_ADMIN for SIOCDARP.
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_admin = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello95") or std.mem.eql(u8, name, "hello114")) {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_sys_mount = true }, .initial_init = false };
    }
    return default_user_profile;
}

pub fn permitsRawNetwork(caps: SysCap) bool {
    return caps.cap_net_raw;
}

const std = @import("std");
