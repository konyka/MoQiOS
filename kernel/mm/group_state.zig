//! State shared by every thread of one thread group, kept in one page owned by the Mm: signal dispositions, resource
//! limits and the file-system context (current directory, umask). Every pthread is created with CLONE_VM | CLONE_SIGHAND, and Linux keeps both in objects the threads share
//! (sighand_struct, signal_struct), so one thread's sigaction()/setrlimit() is every thread's.
//!
//! A fork child (new Mm) starts with a copy of both; exec resets caught signals to default and carries the limits over.
//! Entries are plain words written by the thread that calls sigaction/setrlimit and read by others without a lock.

const rlimit = @import("../proc/rlimit.zig");

pub const Limit = rlimit.Limit;
pub const RLIM_INFINITY = rlimit.RLIM_INFINITY;

pub const SigActions = struct {
    /// Handler addresses. 0 = default, 1 = ignore. Index 0 = signal 1 (SIGHUP) ... index 63 = signal 64 (SIGRTMAX).
    handlers: [64]u64,
    /// Per-signal sa_mask: added to the task mask while that handler runs (the signal frame saves it, sigreturn restores it).
    masks: [64]u64,
    /// Per-signal sa_flags (SA_NODEFER, SA_RESETHAND, SA_ONSTACK honoured at delivery).
    flags: [64]u64,
};

/// RLIMIT_NOFILE default: the descriptor table size (vfs.MAX_FDS; task.zig asserts they agree).
pub const DEFAULT_NOFILE: u64 = if (@import("builtin").cpu.arch == .x86_64) 64 else 8;
pub const DEFAULT_STACK: u64 = 8 * 1024 * 1024;

pub const Limits = struct {
    nofile: Limit,
    stack: Limit,
    as: Limit,
    data: Limit,
    nproc: Limit,
    fsize: Limit,
    /// Limits without an enforcement point (CORE, RSS, CPU, ...): recorded so get/set/prlimit64 round-trip.
    recorded: rlimit.RecordedLimits,
};

/// The file-system context (Linux fs_struct, CLONE_FS): current directory and umask.
pub const FsContext = struct {
    /// NUL-terminated absolute path; cwd_len excludes the NUL.
    cwd: [256]u8,
    cwd_len: u32,
    umask: u32,
};

pub const DEFAULT_UMASK: u32 = 0o022; // same value as proc/creation_metadata.DEFAULT_UMASK (asserted by a host test)

pub const GroupState = struct {
    sig: SigActions,
    lim: Limits,
    fs: FsContext,

    pub fn initial(max_fds: u64) GroupState {
        const inf: Limit = .{ .cur = RLIM_INFINITY, .max = RLIM_INFINITY };
        return .{
            .sig = .{ .handlers = @splat(0), .masks = @splat(0), .flags = @splat(0) },
            .lim = .{
                .nofile = .{ .cur = max_fds, .max = max_fds },
                .stack = .{ .cur = DEFAULT_STACK, .max = DEFAULT_STACK },
                .as = inf,
                .data = inf,
                .nproc = inf,
                .fsize = inf,
                .recorded = .{},
            },
            .fs = .{ .cwd = [_]u8{'/'} ++ [_]u8{0} ** 255, .cwd_len = 1, .umask = DEFAULT_UMASK },
        };
    }
};
