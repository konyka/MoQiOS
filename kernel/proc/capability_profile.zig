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
    if (std.mem.eql(u8, name, "hello179")) {
        return .{ .uid = 0, .gid = 0, .caps = .{ .cap_net_admin = true, .cap_setuid = true }, .initial_init = false };
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
