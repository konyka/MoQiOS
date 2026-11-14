/// File leases (fcntl F_SETLEASE / F_GETLEASE), the bookkeeping without the kernel around it (file_lock.zig owns the instance).
///
/// A lease belongs to an open file description (`owner`) of one file (`key`) and names the process (`tgid`) to send SIGIO to.
/// Linux fs/locks.c:
///   - taking one (check_conflicting_open, generic_add_lease): a read lease needs the file not open for writing; a write lease
///     needs no open but the caller's own (its write count and read-only count must be the caller's own share), and no other
///     lease; no new lease while another one waits to be given up; the description's own lease just changes type;
///   - breaking (__break_lease): a write open conflicts with every lease, a read open only with a write lease. Each conflicting
///     lease is marked once, "unlock pending" for a write open and "downgrade pending" for a read open, with a deadline, and its
///     holder is told; the opener then waits while a lease of a conflicting type remains;
///   - lease_modify: changing the type to F_RDLCK clears a pending downgrade, F_UNLCK removes the lease;
///   - time_out_leases: past its deadline a pending downgrade turns the lease into a read lease and a pending unlock removes it;
///   - target_leasetype: F_GETLEASE reports the type the lease is on its way to.
pub const RDLCK: u64 = 0;
pub const WRLCK: u64 = 1;
pub const UNLCK: u64 = 2;

const EAGAIN: i64 = -11;
const EINVAL: i64 = -22;
const ENOLCK: i64 = -37;

/// /proc/sys/fs/lease-break-time: how long a holder has to give a lease up.
pub const BREAK_NS: u64 = 45 * 1_000_000_000;

pub const Lease = struct {
    used: bool = false,
    key: u64 = 0,
    owner: u64 = 0,
    tgid: u32 = 0,
    write: bool = false,
    unlock_pending: bool = false,
    downgrade_pending: bool = false,
    break_deadline: u64 = 0,
    downgrade_deadline: u64 = 0,
};

/// The open file descriptions of the file: those open for writing, those open read-only, and whether the caller's is writable.
pub const Opens = struct { writers: u32, readers: u32, self_writable: bool };

/// The processes a break must signal, each once.
pub const Notify = struct {
    tgids: [8]u32 = @splat(0),
    n: usize = 0,

    fn add(self: *Notify, tgid: u32) void {
        for (self.tgids[0..self.n]) |g| if (g == tgid) return;
        if (self.n < self.tgids.len) {
            self.tgids[self.n] = tgid;
            self.n += 1;
        }
    }
};

/// The type F_GETLEASE reports for a lease.
pub fn targetType(l: *const Lease) u64 {
    if (l.unlock_pending) return UNLCK;
    if (l.downgrade_pending) return RDLCK;
    return if (l.write) WRLCK else RDLCK;
}

fn conflictsWith(l: *const Lease, write: bool) bool {
    return l.write or write;
}

pub fn Table(comptime N: usize) type {
    return struct {
        const Self = @This();
        leases: [N]Lease = @splat(.{}),

        fn find(self: *Self, key: u64, owner: u64) ?*Lease {
            for (&self.leases) |*l| if (l.used and l.key == key and l.owner == owner) return l;
            return null;
        }

        /// Apply every deadline that has passed.
        pub fn expire(self: *Self, now: u64) void {
            for (&self.leases) |*l| {
                if (!l.used) continue;
                if (l.downgrade_pending and now >= l.downgrade_deadline) {
                    l.write = false;
                    l.downgrade_pending = false;
                }
                if (l.unlock_pending and now >= l.break_deadline) l.* = .{};
            }
        }

        /// F_SETLEASE F_RDLCK / F_WRLCK through `owner`.
        pub fn set(self: *Self, key: u64, owner: u64, tgid: u32, lease_type: u64, opens: Opens, now: u64) i64 {
            if (lease_type != RDLCK and lease_type != WRLCK) return EINVAL;
            self.expire(now);
            const write = lease_type == WRLCK;
            if (!write) {
                if (opens.writers != 0) return EAGAIN;
            } else {
                const self_w: u32 = @intFromBool(opens.self_writable);
                if (opens.writers != self_w or opens.readers != 1 - self_w) return EAGAIN;
            }
            var mine: ?*Lease = null;
            for (&self.leases) |*l| {
                if (!l.used or l.key != key) continue;
                if (l.owner == owner) {
                    mine = l;
                    continue;
                }
                if (write or l.unlock_pending) return EAGAIN;
            }
            if (mine) |m| {
                m.write = write;
                if (!write) m.downgrade_pending = false;
                return 0;
            }
            for (&self.leases) |*l| if (!l.used) {
                l.* = .{ .used = true, .key = key, .owner = owner, .tgid = tgid, .write = write };
                return 0;
            };
            return ENOLCK;
        }

        /// F_SETLEASE F_UNLCK: EAGAIN when the description holds no lease.
        pub fn unlock(self: *Self, key: u64, owner: u64, now: u64) i64 {
            self.expire(now);
            const l = self.find(key, owner) orelse return EAGAIN;
            l.* = .{};
            return 0;
        }

        /// F_GETLEASE through `owner`.
        pub fn get(self: *Self, key: u64, owner: u64, now: u64) u64 {
            self.expire(now);
            const l = self.find(key, owner) orelse return UNLCK;
            return targetType(l);
        }

        /// An open (`write`: for writing, or a truncate) of file `key` starts: mark each conflicting lease not yet marked and
        /// collect its holder in `notify`. True when a conflicting lease exists.
        pub fn breakFor(self: *Self, key: u64, write: bool, now: u64, notify: *Notify) bool {
            self.expire(now);
            var any = false;
            for (&self.leases) |*l| {
                if (!l.used or l.key != key or !conflictsWith(l, write)) continue;
                any = true;
                if (write) {
                    if (l.unlock_pending) continue;
                    l.unlock_pending = true;
                    l.break_deadline = now +| BREAK_NS;
                } else {
                    if (l.unlock_pending or l.downgrade_pending) continue;
                    l.downgrade_pending = true;
                    l.downgrade_deadline = now +| BREAK_NS;
                }
                notify.add(l.tgid);
            }
            return any;
        }

        /// Does a lease that conflicts with the open still exist (the blocked opener looks again)?
        pub fn conflicts(self: *Self, key: u64, write: bool, now: u64) bool {
            self.expire(now);
            for (&self.leases) |*l| if (l.used and l.key == key and conflictsWith(l, write)) return true;
            return false;
        }

        /// The open file description `owner` is gone: drop its leases. True when one was dropped.
        pub fn dropOwner(self: *Self, owner: u64) bool {
            var dropped = false;
            for (&self.leases) |*l| if (l.used and l.owner == owner) {
                l.* = .{};
                dropped = true;
            };
            return dropped;
        }
    };
}
