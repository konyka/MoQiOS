/// setenv — set process environment variable.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");

/// setenv(kvp_ptr) -> 0 or -errno.
/// Custom syscall: sets KEY=VALUE in current process environment.
pub fn setenv(kvp_ptr: u64) i64 {
    if (kvp_ptr == 0 or kvp_ptr >= 0x0000_8000_0000_0000) return -22;

    var kvp_buf: [128]u8 = undefined;
    const copied = copy.copyFromUser(kvp_buf[0..], @ptrFromInt(kvp_ptr), 127);
    if (copied == 0) return -1;
    kvp_buf[if (copied < 127) copied else 127] = 0;

    var has_eq = false;
    for (kvp_buf[0..copied]) |c| {
        if (c == '=') { has_eq = true; break; }
    }
    if (!has_eq) return -22;

    const current = sched_mod.currentTask() orelse return -1;

    var key_len: usize = 0;
    while (key_len < copied and kvp_buf[key_len] != '=') : (key_len += 1) {}

    var found: ?usize = null;
    for (0..current.env_count) |i| {
        const entry = current.env_vars[i][0..];
        var j: usize = 0;
        while (j < key_len and j < 127 and entry[j] != 0 and entry[j] != '=') : (j += 1) {
            if (entry[j] != kvp_buf[j]) break;
        }
        if (j == key_len and entry[j] == '=') {
            found = i;
            break;
        }
    }

    const slot = found orelse blk: {
        if (current.env_count >= 32) return -12; // -ENOMEM
        const s = current.env_count;
        current.env_count += 1;
        break :blk s;
    };

    @memset(current.env_vars[slot][0..128], 0);
    var total_len: usize = 0;
    while (total_len < 127 and kvp_buf[total_len] != 0) : (total_len += 1) {}
    @memcpy(current.env_vars[slot][0..total_len], kvp_buf[0..total_len]);

    return 0;
}
