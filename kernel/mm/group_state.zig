//! State shared by every thread of one thread group, kept in one page owned by the Mm: signal dispositions, resource
//! limits and the file-system context (current directory, umask). Every pthread is created with CLONE_VM | CLONE_SIGHAND, and Linux keeps both in objects the threads share
//! (sighand_struct, signal_struct), so one thread's sigaction()/setrlimit() is every thread's.
//!
//! A fork child (new Mm) starts with a copy of both; exec resets caught signals to default and carries the limits over.
//! Entries are plain words written by the thread that calls sigaction/setrlimit and read by others without a lock.

const rlimit = @import("../proc/rlimit.zig");
const Ticket = @import("../sync/ticket_lock.zig").Ticket;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

fn hostRelax() void {}

/// The kernel masks interrupts while it holds the lock (a timer interrupt must not preempt the holder on a CPU where another
/// thread of the process is spinning for it). The host unit tests cannot execute the privileged instructions that needs, so
/// they take the same ticket lock without the masking.
const HostLock = struct {
    ticket: Ticket = .{},
    pub fn acquire(self: *HostLock) u64 {
        self.ticket.lock(hostRelax);
        return 0;
    }
    pub fn release(self: *HostLock, _: u64) void {
        self.ticket.unlock();
    }
};
const FsLock = if (@import("builtin").is_test) HostLock else IrqSpinlock;

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
pub const DEFAULT_NOFILE: u64 = if (@import("builtin").cpu.arch == .x86_64) 128 else 8;
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
///
/// The directory is a 256-byte array that chdir() rewrites in several steps while other threads of the process may be reading
/// it (getcwd, every relative path lookup). Both sides go through `snapshot` and `set`, which hold `lock` for the copy, so a
/// reader sees one complete path, never half of the old one and half of the new one (Linux protects fs->pwd with fs->lock).
/// The lock covers only the copy: path resolution, permission checks and file-system access happen outside it.
pub const FsContext = struct {
    /// NUL-terminated absolute path; cwd_len excludes the NUL. Read and write only through snapshot()/set().
    cwd: [256]u8,
    cwd_len: u32,
    umask: u32,
    lock: FsLock = .{},

    pub const CWD_MAX = 255;

    /// A private copy of the current directory (no NUL needed: use `len`).
    pub const Snapshot = struct {
        buf: [256]u8,
        len: usize,

        pub fn slice(self: *const Snapshot) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub fn snapshot(self: *FsContext) Snapshot {
        var out: Snapshot = undefined;
        const f = self.lock.acquire();
        defer self.lock.release(f);
        out.len = self.cwd_len;
        @memcpy(out.buf[0..out.len], self.cwd[0..out.len]);
        return out;
    }

    /// Replace the current directory. `path` must be 1..CWD_MAX bytes (the caller checked); returns false if it is not.
    pub fn set(self: *FsContext, path: []const u8) bool {
        if (path.len == 0 or path.len > CWD_MAX) return false;
        const f = self.lock.acquire();
        defer self.lock.release(f);
        @memcpy(self.cwd[0..path.len], path);
        self.cwd[path.len] = 0;
        self.cwd_len = @intCast(path.len);
        return true;
    }
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
