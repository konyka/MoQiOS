//! Pure rules for utimensat(2): the two timespecs, UTIME_NOW / UTIME_OMIT,
//! and who may change timestamps. Timestamps on disk are 32-bit seconds, so
//! an explicit time outside 0..u32 max is EOVERFLOW rather than a silent wrap.

pub const UTIME_NOW: i64 = (1 << 30) - 1;
pub const UTIME_OMIT: i64 = (1 << 30) - 2;

pub const Timespec = struct { sec: i64, nsec: i64 };

pub const Spec = union(enum) {
    keep,
    now,
    set: u32,
};

pub fn parse(times: ?[2]Timespec) union(enum) { ok: [2]Spec, err: i64 } {
    const t = times orelse return .{ .ok = .{ .now, .now } };
    var out: [2]Spec = undefined;
    for (t, 0..) |ts, i| {
        if (ts.nsec == UTIME_OMIT) {
            out[i] = .keep;
        } else if (ts.nsec == UTIME_NOW) {
            out[i] = .now;
        } else if (ts.nsec < 0 or ts.nsec >= 1_000_000_000) {
            return .{ .err = -22 }; // EINVAL
        } else if (ts.sec < 0 or ts.sec > 0xFFFF_FFFF) {
            return .{ .err = -75 }; // EOVERFLOW
        } else {
            out[i] = .{ .set = @intCast(ts.sec) };
        }
    }
    return .{ .ok = out };
}

pub fn nothingToDo(s: [2]Spec) bool {
    return s[0] == .keep and s[1] == .keep;
}

/// Setting an explicit time needs ownership (or CAP_FOWNER); setting "now"
/// also accepts write access to the file.
pub fn authorize(s: [2]Spec, is_owner: bool, cap_fowner: bool, can_write: bool) i64 {
    if (is_owner or cap_fowner) return 0;
    for (s) |x| if (x == .set) return -1; // EPERM
    return if (can_write) 0 else -13; // EACCES
}
