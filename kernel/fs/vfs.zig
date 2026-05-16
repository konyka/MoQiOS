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
};

/// Open file descriptor.
pub const FileDescriptor = struct {
    fd_type: FdType = .none,
    offset: u64 = 0,
    file_size: u64 = 0,
    file_data: u64 = 0,
    fat32_file_idx: u32 = 0,
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
        }
    }

    /// Close a file descriptor.
    pub fn close(self: *FdTable, fd: u32) i64 {
        if (fd >= MAX_FDS) return -1;
        if (fd <= FD_STDERR) return 0; // Can't close stdio
        if (self.fds[fd].fd_type == .none) return -1;
        self.fds[fd] = .{};
        return 0;
    }
};
