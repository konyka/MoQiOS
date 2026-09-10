//! Pure join/normalize for chdir's cwd update (kernel/fs/chdir.zig).
//!
//! Task.cwd is a fixed [256]u8 buffer holding a NUL-terminated path, so the
//! normalized path is capped at 255 bytes; anything longer is rejected with
//! ENAMETOOLONG instead of being silently truncated or overflowing.

pub const CWD_BUF_LEN: usize = 256;

pub const ResolveError = error{NameTooLong};

/// Join `path` onto `cwd` (when relative), then normalize "." / ".." /
/// duplicate-slash / trailing-slash components into `out` (no NUL appended).
/// Returns the result length, always <= CWD_BUF_LEN - 1 so the caller's NUL
/// terminator lands inside the buffer.
pub fn resolve(cwd: []const u8, path: []const u8, out: *[CWD_BUF_LEN]u8) ResolveError!usize {
    var resolved: [CWD_BUF_LEN]u8 = undefined;
    var resolved_len: usize = 0;

    if (path.len > 0 and path[0] == '/') {
        if (path.len > CWD_BUF_LEN) return error.NameTooLong;
        @memcpy(resolved[0..path.len], path);
        resolved_len = path.len;
    } else {
        if (cwd.len > 0) {
            if (cwd.len > CWD_BUF_LEN) return error.NameTooLong;
            @memcpy(resolved[0..cwd.len], cwd);
            resolved_len = cwd.len;
        }
        if (resolved_len > 0 and resolved[resolved_len - 1] != '/') {
            if (resolved_len >= CWD_BUF_LEN) return error.NameTooLong;
            resolved[resolved_len] = '/';
            resolved_len += 1;
        }
        if (path.len > CWD_BUF_LEN - resolved_len) return error.NameTooLong;
        @memcpy(resolved[resolved_len .. resolved_len + path.len], path);
        resolved_len += path.len;
    }

    // Normalize: remove trailing slash (except root)
    while (resolved_len > 1 and resolved[resolved_len - 1] == '/') {
        resolved_len -= 1;
    }

    // Handle "." and ".." components
    var pos: usize = 0;
    var write_pos: usize = 0;
    while (pos < resolved_len) {
        while (pos < resolved_len and resolved[pos] == '/') : (pos += 1) {}
        if (pos >= resolved_len) break;
        const start = pos;
        while (pos < resolved_len and resolved[pos] != '/') : (pos += 1) {}
        const component = resolved[start..pos];

        if (component.len == 1 and component[0] == '.') {
            continue;
        } else if (component.len == 2 and component[0] == '.' and component[1] == '.') {
            if (write_pos > 1) {
                write_pos -= 1;
                while (write_pos > 0 and out[write_pos - 1] != '/') : (write_pos -= 1) {}
            }
        } else {
            const sep: usize = if (write_pos == 0 or out[write_pos - 1] != '/') 1 else 0;
            // Leave room for the caller's NUL terminator.
            if (write_pos + sep + component.len > CWD_BUF_LEN - 1) return error.NameTooLong;
            if (sep == 1) {
                out[write_pos] = '/';
                write_pos += 1;
            }
            @memcpy(out[write_pos .. write_pos + component.len], component);
            write_pos += component.len;
        }
    }

    if (write_pos == 0) {
        out[0] = '/';
        write_pos = 1;
    }
    return write_pos;
}
