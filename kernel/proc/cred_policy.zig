// kernel/proc/cred_policy.zig — pure identity-change rules (setuid(2) family,
// capabilities(7) "effect of user ID changes on capabilities").
//
// Authorization: a caller holding CAP_SETUID (CAP_SETGID for group IDs) may
// set any ID; without it each new ID must equal one of the caller's current
// real/effective/saved IDs. euid 0 alone grants nothing — the capability does
// (root normally holds it).

pub const KEEP: u32 = 0xFFFF_FFFF;

pub const Ids = struct {
    r: u32,
    e: u32,
    s: u32,
};

pub const Caps = struct {
    effective: u32,
    permitted: u32,
};

fn isCurrent(cur: Ids, v: u32) bool {
    return v == cur.r or v == cur.e or v == cur.s;
}

/// setresuid/setresgid: each non-KEEP value must be one of the current IDs
/// unless `privileged`.
pub fn setres(cur: Ids, r: u32, e: u32, s: u32, privileged: bool) ?Ids {
    if (!privileged) {
        for ([_]u32{ r, e, s }) |v| {
            if (v != KEEP and !isCurrent(cur, v)) return null;
        }
    }
    return .{
        .r = if (r != KEEP) r else cur.r,
        .e = if (e != KEEP) e else cur.e,
        .s = if (s != KEEP) s else cur.s,
    };
}

/// setreuid/setregid: unprivileged real may become the current real or
/// effective ID; effective may become real, effective or saved. The saved ID
/// follows the new effective ID when real is set, or effective is set to
/// something other than the old real ID (setreuid(2)).
pub fn setre(cur: Ids, r: u32, e: u32, privileged: bool) ?Ids {
    if (!privileged) {
        if (r != KEEP and r != cur.r and r != cur.e) return null;
        if (e != KEEP and !isCurrent(cur, e)) return null;
    }
    var out = cur;
    if (r != KEEP) out.r = r;
    if (e != KEEP) out.e = e;
    if (r != KEEP or (e != KEEP and e != cur.r)) out.s = out.e;
    return out;
}

/// setuid/setgid: privileged sets all three; otherwise only the effective ID,
/// and only to the real or saved ID.
pub fn setOne(cur: Ids, v: u32, privileged: bool) ?Ids {
    if (v == KEEP) return null;
    if (privileged) return .{ .r = v, .e = v, .s = v };
    if (v != cur.r and v != cur.s) return null;
    return .{ .r = cur.r, .e = v, .s = cur.s };
}

/// Capabilities after a user-ID change (capabilities(7), no SECBIT_* flags):
/// - one of r/e/s was 0 and now none is: permitted and effective are cleared;
/// - effective 0 -> non-zero: effective is cleared;
/// - effective non-zero -> 0: effective becomes permitted.
pub fn capsAfterUidChange(old: Ids, new: Ids, caps: Caps) Caps {
    var out = caps;
    const had_root = old.r == 0 or old.e == 0 or old.s == 0;
    const has_root = new.r == 0 or new.e == 0 or new.s == 0;
    if (had_root and !has_root) {
        out.permitted = 0;
        out.effective = 0;
        return out;
    }
    if (old.e == 0 and new.e != 0) out.effective = 0;
    if (old.e != 0 and new.e == 0) out.effective = out.permitted;
    return out;
}
