//! Pure RLIMIT_NOFILE policy. Other resource limits remain syscall stubs.

pub const Limit = struct {
    cur: u64,
    max: u64,
};

pub const Policy = struct {
    pub const Error = error{ InvalidLimit, WouldLowerHardLimit };

    pub const LinuxAlias = enum {
        setrlimit,
        prlimit64,
    };

    pub const DupExplicit = enum {
        bad_old,
        no_op,
        bad_target,
        replace,
    };

    pub fn default(max_fds: u32) Limit {
        return .{ .cur = max_fds, .max = max_fds };
    }

    pub fn validate(next: Limit, max_fds: u32) Error!void {
        if (next.cur > next.max or next.max > max_fds) return error.InvalidLimit;
    }

    pub fn fdAllowed(soft_limit: u64, fd: u64, max_fds: u32) bool {
        return fd < soft_limit and fd < max_fds;
    }

    pub fn allocationCandidate(free_bm: u64, min_fd: u64, soft_limit: u64, max_fds: u32) ?u32 {
        const upper = @min(soft_limit, @as(u64, max_fds));
        if (min_fd >= upper or min_fd >= 64) return null;

        const upper_mask: u64 = if (upper >= 64)
            ~@as(u64, 0)
        else if (upper == 0)
            0
        else
            (@as(u64, 1) << @intCast(upper)) - 1;
        const lower_mask = (@as(u64, 1) << @intCast(min_fd)) - 1;
        const available = free_bm & upper_mask & ~lower_mask;
        if (available == 0) return null;
        return @intCast(@ctz(available));
    }

    pub fn dupMinimumValid(soft_limit: u64, min_fd: u64, max_fds: u32) bool {
        return fdAllowed(soft_limit, min_fd, max_fds);
    }

    pub fn dupExplicit(old_valid: bool, old_fd: u64, new_fd: u64, soft_limit: u64, max_fds: u32) DupExplicit {
        if (!old_valid) return .bad_old;
        if (old_fd == new_fd) return .no_op;
        if (!fdAllowed(soft_limit, new_fd, max_fds)) return .bad_target;
        return .replace;
    }

    pub fn linuxAlias(is_linux: bool, syscall_nr: u64) ?LinuxAlias {
        if (!is_linux) return null;
        return switch (syscall_nr) {
            160 => .setrlimit,
            302 => .prlimit64,
            else => null,
        };
    }

    pub fn apply(current: Limit, next: Limit, max_fds: u32, privileged: bool) Error!Limit {
        try validate(next, max_fds);
        if (next.max > current.max and !privileged) return error.WouldLowerHardLimit;
        if ((next.cur > current.max or next.max > current.max) and !privileged) {
            return error.WouldLowerHardLimit;
        }
        return next;
    }
};
