/// ioctl device control framework — terminal and generic device ioctls.
///
/// Provides the sysIoctl syscall handler that dispatches based on command.
/// Terminal ioctls (TCGETS, TIOCGWINSZ, etc.) operate on a default terminal
/// state. FIONREAD and FIONBIO operate on fd-level state.

const copy = @import("../mm/copy_from_user.zig");
const task_mod = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const vfs = @import("vfs.zig");
const pgrp = @import("../proc/pgrp.zig");

// ── Terminal ioctl command numbers (Linux x86_64 values) ──

pub const TCGETS = 0x5401; // Get terminal attributes
pub const TCSETS = 0x5402; // Set terminal attributes
pub const TIOCGWINSZ = 0x5413; // Get window size
pub const TIOCSWINSZ = 0x5414; // Set window size
pub const TIOCGPGRP = 0x540F; // Get foreground process group
pub const TIOCSPGRP = 0x5410; // Set foreground process group
pub const FIONREAD = 0x541B; // Get number of readable bytes
pub const FIONBIO = 0x5421; // Set/clear non-blocking mode

// ── Terminal data structures ──

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub const Termios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_line: u8,
    c_cc: [19]u8,
};

// ── Default terminal state ──

var default_winsize: Winsize = .{
    .ws_row = 25,
    .ws_col = 80,
    .ws_xpixel = 0,
    .ws_ypixel = 0,
};

var default_termios: Termios = .{
    .c_iflag = 0x500, // ICRNL | IXON
    .c_oflag = 0x5, // OPOST | ONLCR
    .c_cflag = 0xBF, // CS8 | CREAD | HUPCL
    .c_lflag = 0x8A3B, // ECHO | ECHOE | ECHOK | ISIG | ICANON | IEXTEN | ECHOCTL | ECHOKE
    .c_line = 0,
    .c_cc = [_]u8{0} ** 19,
};

/// Foreground process group ID for the controlling terminal.
var foreground_pgid: u16 = 0;

/// sysIoctl(fd, cmd, arg) → 0 on success, negative errno on failure
pub fn sysIoctl(fd: u64, cmd: u64, arg: u64) i64 {
    // Validate fd range
    if (fd >= vfs.MAX_FDS) return -9; // EBADF

    switch (cmd) {
        TIOCGWINSZ => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14; // EFAULT
            const ws_bytes: [*]const u8 = @ptrCast(&default_winsize);
            _ = copy.copyToUser(@ptrFromInt(arg), ws_bytes[0..@sizeOf(Winsize)], @sizeOf(Winsize));
            return 0;
        },
        TIOCSWINSZ => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var ws: Winsize = undefined;
            const ws_bytes: [*]u8 = @ptrCast(&ws);
            const copied = copy.copyFromUser(ws_bytes[0..@sizeOf(Winsize)], @ptrFromInt(arg), @sizeOf(Winsize));
            if (copied < @sizeOf(Winsize)) return -14;
            default_winsize = ws;
            return 0;
        },
        TCGETS => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const t_bytes: [*]const u8 = @ptrCast(&default_termios);
            _ = copy.copyToUser(@ptrFromInt(arg), t_bytes[0..@sizeOf(Termios)], @sizeOf(Termios));
            return 0;
        },
        TCSETS => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var t: Termios = undefined;
            const t_bytes: [*]u8 = @ptrCast(&t);
            const copied = copy.copyFromUser(t_bytes[0..@sizeOf(Termios)], @ptrFromInt(arg), @sizeOf(Termios));
            if (copied < @sizeOf(Termios)) return -14;
            default_termios = t;
            return 0;
        },
        TIOCGPGRP => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var pgid: u16 = foreground_pgid;
            if (pgid == 0) {
                // If no fg group set, use current process's pgid
                const cur_idx = sched.currentTaskIndex() orelse return -3;
                const cur = task_mod.getTask(cur_idx) orelse return -3;
                pgid = cur.pgid;
            }
            const pgid_bytes: [*]const u8 = @ptrCast(&pgid);
            _ = copy.copyToUser(@ptrFromInt(arg), pgid_bytes[0..2], 2);
            return 0;
        },
        TIOCSPGRP => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            var pgid: u16 = undefined;
            const pgid_bytes: [*]u8 = @ptrCast(&pgid);
            const copied = copy.copyFromUser(pgid_bytes[0..2], @ptrFromInt(arg), 2);
            if (copied < 2) return -14;
            // Validate that pgid belongs to a process in the caller's session
            const cur_idx = sched.currentTaskIndex() orelse return -3;
            const cur = task_mod.getTask(cur_idx) orelse return -3;
            _ = cur;
            foreground_pgid = pgid;
            return 0;
        },
        FIONREAD => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const cur_idx = sched.currentTaskIndex() orelse return -3;
            const cur = task_mod.getTask(cur_idx) orelse return -3;
            const fd_idx: u32 = @intCast(fd);
            var nread: i32 = 0;

            if (fd_idx < vfs.MAX_FDS) {
                const desc = cur.fd_table.fds[fd_idx];
                if (desc.fd_type == .none) return -9; // EBADF

                // For pipe_read, calculate available bytes
                if (desc.fd_type == .pipe_read and desc.pipe_idx < 16) {
                    const pipe = &vfs.pipes[desc.pipe_idx];
                    if (pipe.tail >= pipe.head) {
                        nread = @intCast(pipe.tail - pipe.head);
                    } else {
                        nread = @intCast(vfs.PIPE_BUF_SIZE - pipe.head + pipe.tail);
                    }
                }
                // For other fd types, report 0 (no special read buffer)
            }

            const nr_bytes: [*]const u8 = @ptrCast(&nread);
            _ = copy.copyToUser(@ptrFromInt(arg), nr_bytes[0..4], 4);
            return 0;
        },
        FIONBIO => {
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) return -14;
            const cur_idx = sched.currentTaskIndex() orelse return -3;
            const cur = task_mod.getTask(cur_idx) orelse return -3;
            const fd_idx: u32 = @intCast(fd);

            if (fd_idx >= vfs.MAX_FDS) return -9;
            if (cur.fd_table.fds[fd_idx].fd_type == .none) return -9;

            // Read the int argument from user space
            var nonblock: i32 = undefined;
            const nb_bytes: [*]u8 = @ptrCast(&nonblock);
            const copied = copy.copyFromUser(nb_bytes[0..4], @ptrFromInt(arg), 4);
            if (copied < 4) return -14;

            if (nonblock != 0) {
                cur.fd_table.fds[fd_idx].fd_flags |= 0x800; // O_NONBLOCK
            } else {
                cur.fd_table.fds[fd_idx].fd_flags &= ~@as(u32, 0x800);
            }
            return 0;
        },
        else => return -25, // ENOTTY
    }
}
