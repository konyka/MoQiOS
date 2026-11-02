//! Hostname rules for dns_resolve (RFC 1035 / RFC 1123), free of kernel state so the host tests can run them.

/// Longest hostname in presentation form (a DNS name is at most 255 octets on the wire, 253 as text).
pub const MAX_NAME: usize = 253;
/// Longest label.
pub const MAX_LABEL: usize = 63;

pub const Verdict = enum { ok, empty, too_long, invalid };

fn labelChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

/// Whether `name` is a syntactically valid hostname: non-empty labels of letters, digits, hyphen (and
/// underscore, which real zones use) separated by single dots, no label starting or ending with a hyphen,
/// each label at most 63 bytes and the whole name at most 253. One trailing dot (a fully qualified name)
/// is allowed.
pub fn check(name: []const u8) Verdict {
    if (name.len == 0) return .empty;
    var s = name;
    if (s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    if (s.len == 0) return .invalid; // just "."
    if (s.len > MAX_NAME) return .too_long;
    var label_len: usize = 0;
    var prev: u8 = '.';
    for (s) |c| {
        if (c == '.') {
            if (label_len == 0) return .invalid; // empty label
            if (prev == '-') return .invalid; // a label may not end with a hyphen
            label_len = 0;
        } else {
            if (!labelChar(c)) return .invalid;
            if (label_len == 0 and c == '-') return .invalid;
            label_len += 1;
            if (label_len > MAX_LABEL) return .invalid;
        }
        prev = c;
    }
    // The name must end inside a label: "a.b.." (one dot stripped above leaves "a.b.") ends after a dot.
    if (label_len == 0 or prev == '-') return .invalid;
    return .ok;
}

/// The name without a single trailing dot, which the resolver tables do not carry.
pub fn stripTrailingDot(name: []const u8) []const u8 {
    if (name.len > 1 and name[name.len - 1] == '.') return name[0 .. name.len - 1];
    return name;
}
