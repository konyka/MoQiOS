//! Pure syslog(2) rules (klogctl). Actions follow Linux's SYSLOG_ACTION_*.

pub const Action = enum {
    close, // 0
    open, // 1
    read_unread, // 2: SYSLOG_ACTION_READ — consume from the shared unread cursor
    read_all, // 3: SYSLOG_ACTION_READ_ALL — everything since the last clear
    read_clear, // 4: READ_ALL, then clear
    clear, // 5
    console_off, // 6
    console_on, // 7
    console_level, // 8
    size_unread, // 9
    size_buffer, // 10
};

pub const Error = enum { eperm, einval };

/// Map the raw `type` argument to an action (authorization is `check`'s job).
pub fn decode(log_type: i64) ?Action {
    if (log_type < 0 or log_type > 10) return null;
    return @enumFromInt(@as(u4, @intCast(log_type)));
}

/// Linux: every action except SIZE_BUFFER needs CAP_SYSLOG (here
/// CAP_SYS_ADMIN, which Linux also accepts). Reads need len >= 0; the
/// console level must be 1..8. Null when the call may proceed.
pub fn check(log_type: i64, len: i64, privileged: bool) ?Error {
    const a = decode(log_type) orelse return .einval;
    switch (a) {
        .read_unread, .read_all, .read_clear => if (len < 0) return .einval,
        .console_level => if (len < 1 or len > 8) return .einval,
        else => {},
    }
    if (a != .size_buffer and !privileged) return .eperm;
    return null;
}

/// Kernel-wide cursors on the kmsg byte stream (absolute positions).
pub const State = struct {
    /// SYSLOG_ACTION_CLEAR: READ_ALL starts here.
    clear_pos: u64 = 0,
    /// SYSLOG_ACTION_READ consumes from here.
    unread_pos: u64 = 0,

    pub fn startFor(self: *const State, a: Action, oldest: u64) u64 {
        const p = if (a == .read_unread) self.unread_pos else self.clear_pos;
        return @max(p, oldest);
    }

    pub fn clear(self: *State, newest: u64) void {
        self.clear_pos = newest;
    }

    pub fn consumed(self: *State, upto: u64) void {
        if (upto > self.unread_pos) self.unread_pos = upto;
    }
};
