//! Who may open which /proc/<pid>/ file. Linux, measured (hello253, hello329): the memory map needs ptrace read access with the fs
//! credentials (fs/proc/task_mmu.c proc_maps_open -> mm_access(PTRACE_MODE_READ_FSCREDS), kernel/ptrace.c __ptrace_may_access): the
//! same thread group, or a caller whose fsuid equals the target's real, effective and saved uid and whose fsgid equals all three of
//! its gids, or CAP_SYS_PTRACE. The descriptor directory is mode 0500 owned by the target's effective uid (fs/proc/base.c
//! task_dump_owner, fs/proc/fd.c proc_fd_permission): a caller whose fsuid is that uid, or one holding CAP_DAC_OVERRIDE, or the same
//! thread group. status, stat, cmdline and the other files open for everyone. MoQiOS has no dumpable flag, so a target is never made
//! root-owned the way a non-dumpable Linux process is.
const std = @import("std");

pub const Verdict = enum { allow, deny };

pub const File = enum { maps, fd_dir, other };

/// The opener: its thread group (getpid), fs ids and effective capabilities.
pub const Caller = struct {
    tgid: u32,
    fsuid: u32,
    fsgid: u32,
    cap_sys_ptrace: bool = false,
    cap_dac_override: bool = false,
};

/// The process the path names.
pub const Target = struct {
    tgid: u32,
    uid: u32,
    euid: u32,
    suid: u32,
    gid: u32,
    egid: u32,
    sgid: u32,
};

/// `target` is null when no task has that pid; then only the capability that would reach any process lets the open through.
pub fn pidFile(file: File, caller: Caller, target: ?Target) Verdict {
    switch (file) {
        .other => return .allow,
        .maps => {
            if (caller.cap_sys_ptrace) return .allow;
            const t = target orelse return .deny;
            if (t.tgid == caller.tgid) return .allow;
            const ids_match = caller.fsuid == t.uid and caller.fsuid == t.euid and caller.fsuid == t.suid and
                caller.fsgid == t.gid and caller.fsgid == t.egid and caller.fsgid == t.sgid;
            return if (ids_match) .allow else .deny;
        },
        .fd_dir => {
            if (caller.cap_dac_override) return .allow;
            const t = target orelse return .deny;
            if (t.tgid == caller.tgid or caller.fsuid == t.euid) return .allow;
            return .deny;
        },
    }
}

const user: Target = .{ .tgid = 7, .uid = 1000, .euid = 1000, .suid = 1000, .gid = 0, .egid = 0, .sgid = 0 };

test "procfs policy: files other than maps and fd open for everyone" {
    try std.testing.expectEqual(Verdict.allow, pidFile(.other, .{ .tgid = 1, .fsuid = 5, .fsgid = 5 }, user));
}

test "procfs policy: maps needs the fs ids to match all three target uids and gids, or CAP_SYS_PTRACE (hello329 A-E, H)" {
    try std.testing.expectEqual(Verdict.allow, pidFile(.maps, .{ .tgid = 1, .fsuid = 1000, .fsgid = 0 }, user));
    var t = user;
    t.suid = 0;
    try std.testing.expectEqual(Verdict.deny, pidFile(.maps, .{ .tgid = 1, .fsuid = 1000, .fsgid = 0 }, t));
    t = user;
    t.uid = 0;
    try std.testing.expectEqual(Verdict.deny, pidFile(.maps, .{ .tgid = 1, .fsuid = 1000, .fsgid = 0 }, t));
    t = user;
    t.egid = 2000;
    try std.testing.expectEqual(Verdict.deny, pidFile(.maps, .{ .tgid = 1, .fsuid = 1000, .fsgid = 0 }, t));
    try std.testing.expectEqual(Verdict.deny, pidFile(.maps, .{ .tgid = 1, .fsuid = 0, .fsgid = 0, .cap_dac_override = true }, user));
    try std.testing.expectEqual(Verdict.allow, pidFile(.maps, .{ .tgid = 1, .fsuid = 0, .fsgid = 0, .cap_sys_ptrace = true }, user));
}

test "procfs policy: the fd directory belongs to the target's effective uid; CAP_DAC_OVERRIDE reaches it, CAP_SYS_PTRACE does not (hello329 B, H, I)" {
    var t = user;
    t.suid = 0;
    try std.testing.expectEqual(Verdict.allow, pidFile(.fd_dir, .{ .tgid = 1, .fsuid = 1000, .fsgid = 9 }, t));
    try std.testing.expectEqual(Verdict.deny, pidFile(.fd_dir, .{ .tgid = 1, .fsuid = 0, .fsgid = 0, .cap_sys_ptrace = true }, user));
    try std.testing.expectEqual(Verdict.allow, pidFile(.fd_dir, .{ .tgid = 1, .fsuid = 0, .fsgid = 0, .cap_dac_override = true }, user));
}

test "procfs policy: a process always reaches its own maps and fd (hello329 K)" {
    const self: Target = .{ .tgid = 1, .uid = 0, .euid = 0, .suid = 0, .gid = 0, .egid = 0, .sgid = 0 };
    try std.testing.expectEqual(Verdict.allow, pidFile(.maps, .{ .tgid = 1, .fsuid = 1000, .fsgid = 0 }, self));
    try std.testing.expectEqual(Verdict.allow, pidFile(.fd_dir, .{ .tgid = 1, .fsuid = 1000, .fsgid = 0 }, self));
}

test "procfs policy: a pid with no task is refused unless the capability that reaches every process is held" {
    try std.testing.expectEqual(Verdict.deny, pidFile(.maps, .{ .tgid = 1, .fsuid = 0, .fsgid = 0 }, null));
    try std.testing.expectEqual(Verdict.allow, pidFile(.maps, .{ .tgid = 1, .fsuid = 0, .fsgid = 0, .cap_sys_ptrace = true }, null));
    try std.testing.expectEqual(Verdict.deny, pidFile(.fd_dir, .{ .tgid = 1, .fsuid = 0, .fsgid = 0 }, null));
}
