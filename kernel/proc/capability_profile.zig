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
    _pad: u15 = 0,
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

    if (std.mem.eql(u8, name, "hello14")) return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_net_raw = true }, .initial_init = false };
    if (std.mem.eql(u8, name, "hello51") or std.mem.eql(u8, name, "hello52")) {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_sys_rawio = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello54")) {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_sys_rawio = true, .cap_kill = true }, .initial_init = false };
    }
    if (std.mem.eql(u8, name, "hello13") or std.mem.eql(u8, name, "hello58")) {
        return .{ .uid = DEFAULT_UID, .gid = DEFAULT_GID, .caps = .{ .cap_kill = true }, .initial_init = false };
    }
    return default_user_profile;
}

pub fn permitsRawNetwork(caps: SysCap) bool {
    return caps.cap_net_raw;
}

const std = @import("std");
