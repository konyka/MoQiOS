/// Virtual File System — minimal implementation for ramdisk-backed files.
///
/// Provides:
///   - Per-process file descriptor table (max 16 open files)
///   - open/read/close operations backed by ramdisk
///   - stdin (fd 0), stdout (fd 1), stderr (fd 2) as special FDs
///
/// Limitations:
///   - Read-only (no write to files yet)
///   - No directory support
///   - No seeking (sequential read only)
///   - Single-process focused (FD table per task)

const ramdisk = @import("ramdisk.zig");
const serial = @import("../arch/x86_64/serial.zig");

pub const MAX_FDS: u32 = 16;
pub const FD_STDIN: u32 = 0;
pub const FD_STDOUT: u32 = 1;
pub const FD_STDERR: u32 = 2;

/// File descriptor type.
pub const FdType = enum(u8) {
    none = 0,
    ramdisk_file = 1,
    special = 2,
    fat32_file = 3,
    pipe_read = 4,
    pipe_write = 5,
};

pub const PIPE_BUF_SIZE: u32 = 4096;

pub const PipeBuffer = struct {
    buf: [PIPE_BUF_SIZE]u8,
    head: u32,
    tail: u32,
    ref_count: u32,
};

var pipes: [16]PipeBuffer = @splat(.{
    .buf = @splat(0),
    .head = 0,
    .tail = 0,
    .ref_count = 0,
});
var pipe_count: u32 = 0;

fn allocPipe() ?u32 {
    for (0..16) |i| {
        if (pipes[i].ref_count == 0) {
            pipes[i] = .{ .buf = @splat(0), .head = 0, .tail = 0, .ref_count = 2 };
            pipe_count += 1;
            return @intCast(i);
        }
    }
    return null;
}

pub fn pipeRead(pipe_idx: u32, buf: [*]u8, count: usize) i64 {
    if (pipe_idx >= 16) return -1;
    const pipe = &pipes[pipe_idx];
    var n: usize = 0;
    while (n < count and pipe.head != pipe.tail) {
        buf[n] = pipe.buf[pipe.head];
        pipe.head = (pipe.head + 1) % PIPE_BUF_SIZE;
        n += 1;
    }
    return @intCast(n);
}

pub fn pipeWrite(pipe_idx: u32, buf: [*]const u8, count: usize) i64 {
    if (pipe_idx >= 16) return -1;
    const pipe = &pipes[pipe_idx];
    var n: usize = 0;
    while (n < count) {
        const next = (pipe.tail + 1) % PIPE_BUF_SIZE;
        if (next == pipe.head) break; // full
        pipe.buf[pipe.tail] = buf[n];
        pipe.tail = next;
        n += 1;
    }
    return if (n == 0) -1 else @intCast(n);
}

pub fn pipeClose(pipe_idx: u32) void {
    if (pipe_idx >= 16) return;
    pipes[pipe_idx].ref_count -|= 1;
    if (pipes[pipe_idx].ref_count == 0) {
        pipes[pipe_idx] = .{ .buf = @splat(0), .head = 0, .tail = 0, .ref_count = 0 };
        pipe_count -|= 1;
    }
}

/// Open file descriptor.
pub const FileDescriptor = struct {
    fd_type: FdType = .none,
    offset: u64 = 0,
    file_size: u64 = 0,
    file_data: u64 = 0,
    fat32_file_idx: u32 = 0,
    pipe_idx: u32 = 0,
};

/// Per-process FD table.
pub const FdTable = struct {
    fds: [MAX_FDS]FileDescriptor,

    pub fn init() FdTable {
        var table: FdTable = .{
            .fds = @splat(.{}),
        };
        // Set up standard FDs
        table.fds[FD_STDIN] = .{ .fd_type = .special };
        table.fds[FD_STDOUT] = .{ .fd_type = .special };
        table.fds[FD_STDERR] = .{ .fd_type = .special };
        return table;
    }

    /// Open a file by name. Returns fd index or -1 on failure.
    pub fn open(self: *FdTable, name: []const u8) i64 {
        var slot: u32 = 3;
        while (slot < MAX_FDS) : (slot += 1) {
            if (self.fds[slot].fd_type == .none) break;
        }
        if (slot >= MAX_FDS) return -1;

        // Try ramdisk first
        if (ramdisk.findFile(name)) |file| {
            self.fds[slot] = .{
                .fd_type = .ramdisk_file,
                .offset = 0,
                .file_size = file.size,
                .file_data = @intFromPtr(file.data),
            };
            return @intCast(slot);
        }

        // Try FAT32 filesystem
        const fat32 = @import("fat32.zig");
        if (fat32.isActive()) {
            const fi = fat32.openFile(name);
            if (fi >= 0) {
                const idx: u32 = @intCast(fi);
                self.fds[slot] = .{
                    .fd_type = .fat32_file,
                    .offset = 0,
                    .file_size = fat32.getFileSize(idx),
                    .fat32_file_idx = idx,
                };
                return @intCast(slot);
            }
        }

        return -1;
    }

    /// Read from a file descriptor into a kernel buffer.
    /// Returns number of bytes read, 0 on EOF, -1 on error.
    pub fn read(self: *FdTable, fd: u32, buf: [*]u8, count: usize) i64 {
        if (fd >= MAX_FDS) return -1;
        const desc = &self.fds[fd];

        switch (desc.fd_type) {
            .none => return -1, // EBADF
            .special => {
                // stdin (fd 0): read from keyboard buffer
                if (fd == FD_STDIN) {
                    const keyboard = @import("../drivers/keyboard.zig");
                    const n = keyboard.read(buf[0..count]);
                    return @intCast(n);
                }
                // stdout/stderr: write-only
                return -1;
            },
            .ramdisk_file => {
                const remaining = desc.file_size - desc.offset;
                if (remaining == 0) return 0;
                const to_read = if (@as(u64, count) > remaining) @as(usize, @intCast(remaining)) else count;
                const src: [*]const u8 = @ptrFromInt(desc.file_data + desc.offset);
                @memcpy(buf[0..to_read], src[0..to_read]);
                desc.offset += to_read;
                return @intCast(to_read);
            },
            .fat32_file => {
                if (desc.offset >= desc.file_size) return 0;
                const fat32 = @import("fat32.zig");
                const n = fat32.readFile(desc.fat32_file_idx, @intCast(desc.offset), buf, @intCast(count));
                if (n > 0) desc.offset += @intCast(n);
                return n;
            },
            .pipe_read => {
                return pipeRead(desc.pipe_idx, buf, count);
            },
            .pipe_write => return -1, // can't read from write end
        }
    }

    /// Write to a file descriptor from a kernel buffer.
    /// Returns number of bytes written, -1 on error.
    pub fn write(self: *FdTable, fd: u32, buf: [*]const u8, count: usize) i64 {
        if (fd >= MAX_FDS) return -1;
        const desc = &self.fds[fd];

        switch (desc.fd_type) {
            .none => return -1,
            .special => {
                // stdout/stderr: write to serial
                serial.writeString(buf[0..count]);
                return @intCast(count);
            },
            .pipe_write => {
                return pipeWrite(desc.pipe_idx, buf, count);
            },
            .pipe_read => return -1, // can't write to read end
            .ramdisk_file, .fat32_file => return -1, // no file write yet
        }
    }

    /// Close a file descriptor.
    pub fn close(self: *FdTable, fd: u32) i64 {
        if (fd >= MAX_FDS) return -1;
        if (fd <= FD_STDERR) return 0;
        const desc = &self.fds[fd];
        if (desc.fd_type == .none) return -1;
        if (desc.fd_type == .pipe_read or desc.fd_type == .pipe_write) {
            pipeClose(desc.pipe_idx);
        }
        desc.* = .{};
        return 0;
    }

    /// Create a pipe. Returns read_fd in low 16 bits, write_fd in high 16 bits, or -1 on error.
    pub fn createPipe(self: *FdTable) i64 {
        const pipe_idx = allocPipe() orelse return -1;

        // Find two free fds
        var read_fd: u32 = MAX_FDS;
        var write_fd: u32 = MAX_FDS;
        var slot: u32 = 3;
        while (slot < MAX_FDS) : (slot += 1) {
            if (self.fds[slot].fd_type == .none) {
                if (read_fd == MAX_FDS) {
                    read_fd = slot;
                } else {
                    write_fd = slot;
                    break;
                }
            }
        }
        if (write_fd == MAX_FDS) {
            pipeClose(pipe_idx);
            return -1;
        }

        self.fds[read_fd] = .{ .fd_type = .pipe_read, .pipe_idx = pipe_idx };
        self.fds[write_fd] = .{ .fd_type = .pipe_write, .pipe_idx = pipe_idx };
        return @as(i64, read_fd) | (@as(i64, write_fd) << 16);
    }

    /// Duplicate fd: dup2(oldfd, newfd). Returns newfd on success, -1 on error.
    pub fn dup2(self: *FdTable, oldfd: u32, newfd: u32) i64 {
        if (oldfd >= MAX_FDS or newfd >= MAX_FDS) return -1;
        if (self.fds[oldfd].fd_type == .none) return -1;
        if (newfd == oldfd) return newfd;
        // Close newfd if open
        if (self.fds[newfd].fd_type != .none) {
            _ = self.close(newfd);
        }
        self.fds[newfd] = self.fds[oldfd];
        // Increment pipe ref count if it's a pipe
        if (self.fds[newfd].fd_type == .pipe_read or self.fds[newfd].fd_type == .pipe_write) {
            if (self.fds[newfd].pipe_idx < 16) {
                pipes[self.fds[newfd].pipe_idx].ref_count += 1;
            }
        }
        return newfd;
    }
};
