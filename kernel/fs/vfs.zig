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
    special = 2, // stdin/stdout/stderr — redirects to serial
};

/// Open file descriptor.
pub const FileDescriptor = struct {
    fd_type: FdType = .none,
    /// For ramdisk_file: offset into the file data for sequential reads.
    offset: u64 = 0,
    /// For ramdisk_file: total file size.
    file_size: u64 = 0,
    /// For ramdisk_file: pointer to the file data (kernel HHDM address).
    file_data: u64 = 0,
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
        // Find a free FD (skip 0,1,2 reserved for stdio)
        var slot: u32 = 3;
        while (slot < MAX_FDS) : (slot += 1) {
            if (self.fds[slot].fd_type == .none) break;
        }
        if (slot >= MAX_FDS) return -1; // EMFILE

        // Look up in ramdisk
        const file = ramdisk.findFile(name) orelse return -1; // ENOENT

        self.fds[slot] = .{
            .fd_type = .ramdisk_file,
            .offset = 0,
            .file_size = file.size,
            .file_data = @intFromPtr(file.data),
        };
        return @intCast(slot);
    }

    /// Read from a file descriptor into a kernel buffer.
    /// Returns number of bytes read, 0 on EOF, -1 on error.
    pub fn read(self: *FdTable, fd: u32, buf: [*]u8, count: usize) i64 {
        if (fd >= MAX_FDS) return -1;
        const desc = &self.fds[fd];

        switch (desc.fd_type) {
            .none => return -1, // EBADF
            .special => return 0, // stdin: no input for now
            .ramdisk_file => {
                const remaining = desc.file_size - desc.offset;
                if (remaining == 0) return 0; // EOF
                const to_read = if (@as(u64, count) > remaining) @as(usize, @intCast(remaining)) else count;
                const src: [*]const u8 = @ptrFromInt(desc.file_data + desc.offset);
                @memcpy(buf[0..to_read], src[0..to_read]);
                desc.offset += to_read;
                return @intCast(to_read);
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
