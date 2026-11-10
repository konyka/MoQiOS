//! Pure rlimit policy: RLIMIT_NOFILE descriptor bounds and RLIMIT_STACK
//! growth-floor semantics. Other resource limits remain syscall stubs.

pub const Limit = struct {
    cur: u64,
    max: u64,
};

pub const RLIM_INFINITY: u64 = 0xFFFF_FFFF_FFFF_FFFF;

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

    /// Lowest free descriptor in [min_fd, min(soft_limit, max_fds)), reading `free_words` (bit set = free, 64 descriptors per word).
    pub fn allocationCandidateWords(free_words: []const u64, min_fd: u64, soft_limit: u64, max_fds: u32) ?u32 {
        const upper = @min(@min(soft_limit, @as(u64, max_fds)), @as(u64, free_words.len) * 64);
        if (min_fd >= upper) return null;
        var w: usize = @intCast(min_fd / 64);
        while (@as(u64, w) * 64 < upper) : (w += 1) {
            var bits = free_words[w];
            const base: u64 = @as(u64, w) * 64;
            if (min_fd > base) bits &= ~((@as(u64, 1) << @intCast(min_fd - base)) - 1);
            if (upper < base + 64) bits &= (@as(u64, 1) << @intCast(upper - base)) - 1;
            if (bits != 0) return @intCast(base + @ctz(bits));
        }
        return null;
    }

    pub fn allocationCandidate(free_bm: u64, min_fd: u64, soft_limit: u64, max_fds: u32) ?u32 {
        return allocationCandidateWords(&[_]u64{free_bm}, min_fd, soft_limit, max_fds);
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

    /// dup2/dup3 failure as an errno: an unopened source or a target beyond
    /// RLIMIT_NOFILE is EBADF (the source case used to leak out as a bare -1).
    pub fn dupExplicitErrno(r: DupExplicit) i64 {
        return switch (r) {
            .bad_old, .bad_target => -9, // EBADF
            .no_op, .replace => 0,
        };
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

    // ── RLIMIT_STACK ─────────────────────────────────────────────────

    /// Stack growth floor: the lowest address the main stack may claim.
    /// `cur == RLIM_INFINITY` (or any value past the region) clamps to
    /// `stack_bottom`, so enforcement never exceeds the architecture region.
    pub fn stackFloor(stack_top: u64, stack_bottom: u64, cur: u64) u64 {
        const region = stack_top - stack_bottom;
        return stack_top - @min(cur, region);
    }

    /// Initial/reset growth watermark for a fresh image: the historical
    /// 256 KiB head start, clamped so a tighter limit is honoured from the
    /// very first fault.
    pub fn initialStackLimit(stack_top: u64, stack_bottom: u64, cur: u64) u64 {
        const floor = stackFloor(stack_top, stack_bottom, cur);
        const head_start = stack_top - 64 * 4096;
        return @max(head_start, floor);
    }

    /// setrlimit/prlimit64 validation for byte-denominated limits
    /// (RLIMIT_STACK, RLIMIT_AS). Same privilege rules as NOFILE but no
    /// table-size ceiling: any value up to RLIM_INFINITY is structurally
    /// valid, only `cur > max` is rejected.
    pub fn applyBytes(current: Limit, next: Limit, privileged: bool) Error!Limit {
        if (next.cur > next.max) return error.InvalidLimit;
        if ((next.cur > current.max or next.max > current.max) and !privileged) {
            return error.WouldLowerHardLimit;
        }
        return next;
    }

    // ── RLIMIT_AS ────────────────────────────────────────────────────

    /// RLIMIT_AS charge check: true when `add` more bytes fit under the soft
    /// limit. `used` may already exceed `cur` after a limit lowering — that
    /// only blocks further charges, never underflows.
    pub fn asChargeOk(used: u64, add: u64, cur: u64) bool {
        if (cur == RLIM_INFINITY) return true;
        return used <= cur and add <= cur - used;
    }

    /// RLIMIT_DATA charge check — same byte-denominated rule as RLIMIT_AS,
    /// over the independent `data_used` ledger (brk + writable-private mmap).
    pub fn dataChargeOk(used: u64, add: u64, cur: u64) bool {
        return asChargeOk(used, add, cur);
    }

    /// RLIMIT_FSIZE: number of bytes permitted from a write beginning at
    /// `pos`. A finite limit truncates the request to the remaining prefix;
    /// infinity leaves it unchanged. Overflowing positions are refused.
    pub fn fsizeWriteBytes(pos: u64, count: u64, soft_limit: u64) u64 {
        if (pos == 0xFFFF_FFFF_FFFF_FFFF and count != 0) return 0;
        if (count > 0xFFFF_FFFF_FFFF_FFFF - pos) return 0;
        if (soft_limit == RLIM_INFINITY) return count;
        if (pos >= soft_limit) return 0;
        const remaining = soft_limit - pos;
        return @min(count, remaining);
    }

    /// Whether writing `add` bytes starting at file offset `pos` stays within
    /// the soft byte limit. A write ending exactly at the limit is allowed.
    pub fn fsizeAllowed(pos: u64, add: u64, soft_limit: u64) bool {
        if (soft_limit == RLIM_INFINITY) return true;
        const end, const overflow = @addWithOverflow(pos, add);
        if (overflow != 0) return false;
        return end <= soft_limit;
    }

    // ── RLIMIT_NPROC ────────────────────────────────────────────────

    /// RLIMIT_NPROC gate: true when a new task for `uid` may be created.
    /// `uid_count` is the current number of live (including zombie) tasks
    /// for that real UID; `cur` is the caller's soft limit. Linux semantics:
    /// the check counts processes by real UID and refuses creation with
    /// EAGAIN once the count reaches the soft limit. `RLIM_INFINITY` never
    /// refuses. A UID with no live tasks always passes (uid_count == 0).
    pub fn nprocAllowed(uid_count: u32, cur: u64) bool {
        if (cur == RLIM_INFINITY) return true;
        return @as(u64, uid_count) < cur;
    }
};

// ── Resources without an enforcement point ────────────────────────────
//
// Linux defines RLIM_NLIMITS = 16 resources. NOFILE/STACK/AS/DATA/NPROC/
// FSIZE are enforced and keep dedicated Task fields. The others (CPU, CORE,
// RSS, MEMLOCK, LOCKS, SIGPENDING, MSGQUEUE, NICE, RTPRIO, RTTIME) are
// recorded per task so get/set/prlimit64 round-trip with the usual
// cur <= max and hard-limit rules, but the kernel does not act on them:
// there are no core dumps, CPU-time signals, resident-set or lock limits.
// Resource numbers outside 0..15 are EINVAL, as on Linux.

pub const RLIM_NLIMITS: u32 = 16;

const enforced = [_]u32{ 1, 2, 3, 6, 7, 9 }; // FSIZE DATA STACK NPROC NOFILE AS

pub fn resourceValid(resource: u32) bool {
    return resource < RLIM_NLIMITS;
}

pub const RECORDED_COUNT: u32 = RLIM_NLIMITS - enforced.len;

/// Index into RecordedLimits for a resource without its own Task field.
pub fn recordedSlot(resource: u32) ?u32 {
    if (!resourceValid(resource)) return null;
    for (enforced) |e| if (e == resource) return null;
    var slot: u32 = 0;
    var r: u32 = 0;
    while (r < resource) : (r += 1) {
        var is_enf = false;
        for (enforced) |e| if (e == r) {
            is_enf = true;
        };
        if (!is_enf) slot += 1;
    }
    return slot;
}

pub const RecordedLimits = struct {
    v: [RECORDED_COUNT]Limit = @splat(.{ .cur = RLIM_INFINITY, .max = RLIM_INFINITY }),

    pub fn get(self: *const RecordedLimits, slot: u32) Limit {
        return self.v[slot];
    }

    pub fn set(self: *RecordedLimits, slot: u32, next: Limit, privileged: bool) Policy.Error!void {
        self.v[slot] = try Policy.applyBytes(self.v[slot], next, privileged);
    }
};
