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
const readahead = @import("readahead.zig");
const str = @import("../lib/str.zig");
const writeback = @import("writeback.zig");
const page_cache = @import("page_cache.zig");

pub const MAX_FDS: u32 = 64;
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
    ext2_file = 6,
    tcp_socket = 7,
    epoll = 8,
    eventfd = 9,
    unix_socket = 10,
    timerfd = 11,
    random = 12,
    tmpfs_file = 13,
    proc_file = 14,
    udp_socket = 15,
    inotify = 16,
    raw_socket = 17,
};

pub const PIPE_BUF_SIZE: u32 = 4096;

pub const PipeBuffer = struct {
    buf: [PIPE_BUF_SIZE]u8,
    head: u32,
    tail: u32,
    ref_count: u32,
};

pub var pipes: [16]PipeBuffer = @splat(.{
    .buf = @splat(0),
    .head = 0,
    .tail = 0,
    .ref_count = 0,
});
var pipe_count: u32 = 0;

pub fn allocPipe() ?u32 {
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
    if (n > 0) {
        const epoll_r = @import("../net/epoll.zig");
        epoll_r.epollNotify(.pipe_write, pipe_idx, epoll_r.EPOLLOUT);
    }
    return @intCast(n);
}

pub fn pipeWrite(pipe_idx: u32, buf: [*]const u8, count: usize) i64 {
    if (pipe_idx >= 16) return -1;
    const pipe = &pipes[pipe_idx];
    var n: usize = 0;
    while (n < count) {
        const next = (pipe.tail + 1) % PIPE_BUF_SIZE;
        if (next == pipe.head) break;
        pipe.buf[pipe.tail] = buf[n];
        pipe.tail = next;
        n += 1;
    }
    if (n > 0) {
        const epoll_w = @import("../net/epoll.zig");
        epoll_w.epollNotify(.pipe_read, pipe_idx, epoll_w.EPOLLIN);
    }
    return if (n == 0) -1 else @intCast(n);
}

pub fn pipeClose(pipe_idx: u32) void {
    if (pipe_idx >= 16) return;
    pipes[pipe_idx].ref_count -|= 1;
    const epoll_c = @import("../net/epoll.zig");
    epoll_c.epollNotify(.pipe_read, pipe_idx, epoll_c.EPOLLHUP);
    epoll_c.epollNotify(.pipe_write, pipe_idx, epoll_c.EPOLLERR);
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
    ext2_file_idx: u32 = 0,
    pipe_idx: u32 = 0,
    tcb_idx: u32 = 0,
    epoll_idx: u32 = 0,
    eventfd_idx: u32 = 0,
    unix_sock_idx: u32 = 0,
    timerfd_idx: u32 = 0,
    inotify_idx: u32 = 0,
    tmpfs_idx: u32 = 0,
    udp_port: u16 = 0,
    udp_connected: bool = false,
    udp_dst_ip: [4]u8 = .{ 0, 0, 0, 0 },
    udp_dst_port: u16 = 0,
    writable: bool = false,
    fd_flags: u32 = 0,
    status_flags: u32 = 0,
    readahead_state: readahead.ReadaheadState = .{},
    // inode identifier for file locking (unique per underlying file)
    inode_id: u64 = 0,
    // procfs fields
    proc_file_type: @import("procfs.zig").ProcFile = .meminfo,
    proc_pid: u16 = 0,
};

/// Per-process FD table.
pub const FdTable = struct {
    fds: [MAX_FDS]FileDescriptor,

    /// Comptime-computed default table (stdin/stdout/stderr wired to the
    /// special console). Living in .rodata means init() is just a copy and
    /// does NOT need a ~57KB stack local — important because FdTable is large
    /// and an on-stack temporary here overflowed the kernel stack at boot.
    const default_table: FdTable = blk: {
        var table: FdTable = .{ .fds = @splat(.{}) };
        table.fds[FD_STDIN] = .{ .fd_type = .special };
        table.fds[FD_STDOUT] = .{ .fd_type = .special };
        table.fds[FD_STDERR] = .{ .fd_type = .special };
        break :blk table;
    };

    pub fn init() FdTable {
        return default_table;
    }

    /// Allocate a free fd slot. Returns the slot index or null if none available.
    pub fn allocFd(self: *FdTable) ?u32 {
        var slot: u32 = 3;
        while (slot < MAX_FDS) : (slot += 1) {
            if (self.fds[slot].fd_type == .none) return slot;
        }
        return null;
    }

    /// Open a file by name. Returns fd index or -1 on failure.
    pub fn open(self: *FdTable, name: []const u8, flags: u32) i64 {
        const slot = self.allocFd() orelse return -1;

        const is_writable = (flags & 0x03) != 0;
        const o_creat = (flags & 0x40) != 0;

        // /dev/urandom and /dev/random
        if (name.len >= 12 and name[0] == '/' and name[1] == 'd' and name[2] == 'e' and name[3] == 'v' and name[4] == '/') {
            const dev_name = name[5..];
            if ((dev_name.len == 7 and dev_name[0] == 'u' and dev_name[1] == 'r' and dev_name[2] == 'a' and dev_name[3] == 'n' and dev_name[4] == 'd' and dev_name[5] == 'o' and dev_name[6] == 'm') or
                (dev_name.len == 6 and dev_name[0] == 'r' and dev_name[1] == 'a' and dev_name[2] == 'n' and dev_name[3] == 'd' and dev_name[4] == 'o' and dev_name[5] == 'm'))
            {
                self.fds[slot] = .{
                    .fd_type = .random,
                    .writable = false,
                };
                return @intCast(slot);
            }
        }

        // tmpfs: paths starting with /tmp/
        if (name.len >= 4 and name[0] == '/' and name[1] == 't' and name[2] == 'm' and name[3] == 'p') {
            const tmpfs = @import("tmpfs.zig");
            const is_dir = o_creat and (flags & 0o100000) != 0; // O_DIRECTORY
            const result = tmpfs.tmpfsOpen(name, o_creat, is_dir);
            if (result >= 0) {
                const idx: u32 = @intCast(result);
                self.fds[slot] = .{
                    .fd_type = .tmpfs_file,
                    .offset = 0,
                    .file_size = tmpfs.tmpfsGetSize(@intCast(idx)),
                    .tmpfs_idx = idx,
                    .writable = is_writable,
                };
                return @intCast(slot);
            }
            return -1;
        }

        // ---- procfs paths ----
        if (name.len > 6 and name[0] == '/' and name[1] == 'p' and name[2] == 'r' and
            name[3] == 'o' and name[4] == 'c' and name[5] == '/')
        {
            const rest = name[6..];
            const procfs = @import("procfs.zig");
            var pfile: procfs.ProcFile = undefined;
            var pid: u16 = 0;

            if (rest.len == 7 and str.eql(rest, "meminfo")) {
                pfile = .meminfo;
            } else if (rest.len == 7 and str.eql(rest, "cpuinfo")) {
                pfile = .cpuinfo;
            } else if (rest.len == 6 and str.eql(rest, "uptime")) {
                pfile = .uptime;
            } else if (rest.len == 7 and str.eql(rest, "version")) {
                pfile = .version;
            } else if (rest.len == 7 and str.eql(rest, "loadavg")) {
                pfile = .loadavg;
            } else if (rest.len == 11 and str.eql(rest, "filesystems")) {
                pfile = .filesystems;
            } else if (rest.len == 4 and str.eql(rest, "stat")) {
                pfile = .stat;
            } else if (rest.len == 11 and str.eql(rest, "sched_stats")) {
                pfile = .sched_stats;
            } else if (rest.len > 0) {
                // /proc/[pid]/status or /proc/[pid]/maps
                var digit_end: usize = 0;
                while (digit_end < rest.len and rest[digit_end] >= '0' and rest[digit_end] <= '9') {
                    digit_end += 1;
                }
                if (digit_end > 0 and digit_end < rest.len and rest[digit_end] == '/') {
                    pid = parseU16(rest[0..digit_end]);
                    const file_part = rest[digit_end + 1 ..];
                    if (str.eql(file_part, "status")) {
                        pfile = .pid_status;
                    } else if (str.eql(file_part, "maps")) {
                        pfile = .pid_maps;
                    } else if (str.eql(file_part, "stat")) {
                        pfile = .pid_stat;
                    } else if (str.eql(file_part, "cmdline")) {
                        pfile = .pid_cmdline;
                    } else {
                        return -1;
                    }
                } else {
                    return -1;
                }
            } else {
                return -1;
            }

            self.fds[slot] = .{
                .fd_type = .proc_file,
                .offset = 0,
                .inode_id = 0x4000_0000_0000_0000 + (@as(u64, pid) << 8) + @intFromEnum(pfile),
                .proc_file_type = pfile,
                .proc_pid = pid,
            };
            return @intCast(slot);
        }

        if (ramdisk.findFile(name)) |file| {
            const data_ptr = @intFromPtr(file.data);
            self.fds[slot] = .{
                .fd_type = .ramdisk_file,
                .offset = 0,
                .file_size = file.size,
                .file_data = data_ptr,
                .writable = is_writable,
                .inode_id = data_ptr,
            };
            return @intCast(slot);
        }

        const fat32 = @import("fat32.zig");
        if (fat32.isActive()) {
            var fi = fat32.openFile(name);
            if (fi >= 0) {
                const idx: u32 = @intCast(fi);
                self.fds[slot] = .{
                    .fd_type = .fat32_file,
                    .offset = 0,
                    .file_size = fat32.getFileSize(idx),
                    .fat32_file_idx = idx,
                    .writable = is_writable,
                    .inode_id = 0x2000_0000_0000_0000 + @as(u64, fat32.getFirstCluster(idx)),
                };
                readahead.initState(&self.fds[slot].readahead_state);
                return @intCast(slot);
            }

            if (o_creat) {
                fi = fat32.createFile(name);
                if (fi >= 0) {
                    const idx: u32 = @intCast(fi);
                    self.fds[slot] = .{
                        .fd_type = .fat32_file,
                        .offset = 0,
                        .file_size = 0,
                        .fat32_file_idx = idx,
                        .writable = true,
                        .inode_id = 0x2000_0000_0000_0000 + @as(u64, fat32.getFirstCluster(idx)),
                    };
                    readahead.initState(&self.fds[slot].readahead_state);
                    return @intCast(slot);
                }
            }
        }

        const ext2 = @import("ext2.zig");
        if (ext2.isActive()) {
            const fi = ext2.openFile(name);
            if (fi >= 0) {
                const idx: u32 = @intCast(fi);
                self.fds[slot] = .{
                    .fd_type = .ext2_file,
                    .offset = 0,
                    .file_size = ext2.getFileSize(idx),
                    .ext2_file_idx = idx,
                    .writable = is_writable,
                    .inode_id = 0x3000_0000_0000_0000 + @as(u64, ext2.getInodeNum(idx)),
                };
                readahead.initState(&self.fds[slot].readahead_state);
                return @intCast(slot);
            }

            // ext2 create file if O_CREAT
            if (o_creat) {
                const ci = ext2.createFile(name);
                if (ci >= 0) {
                    const idx: u32 = @intCast(ci);
                    self.fds[slot] = .{
                        .fd_type = .ext2_file,
                        .offset = 0,
                        .file_size = 0,
                        .ext2_file_idx = idx,
                        .writable = true,
                        .inode_id = 0x3000_0000_0000_0000 + @as(u64, ext2.getInodeNum(idx)),
                    };
                    readahead.initState(&self.fds[slot].readahead_state);
                    return @intCast(slot);
                }
            }
        }

        return -1;
    }

    // Parse a small decimal string into u16
    fn parseU16(s: []const u8) u16 {
        var v: u16 = 0;
        for (s) |c| {
            if (c < '0' or c > '9') break;
            v = v * 10 + (c - '0');
        }
        return v;
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
                // 1. Check writeback cache (read-after-write consistency)
                const n_cached = writeback.readBuffered(desc.fat32_file_idx, desc.offset, buf, @intCast(count), .fat32);
                if (n_cached > 0) {
                    desc.offset += @as(u64, n_cached);
                    return @intCast(n_cached);
                }
                // 2. Check readahead cache
                const block_num = desc.offset / 4096;
                const block_offset: u32 = @intCast(desc.offset % 4096);
                const cached = readahead.copyFromCache(&desc.readahead_state, block_num, block_offset, buf, @intCast(count));
                if (cached > 0) {
                    desc.offset += cached;
                    _ = page_cache.recordAccess(desc.inode_id, block_num);
                    return cached;
                }
                // 3. Fall back to FS readFile
                const fat32 = @import("fat32.zig");
                const n = fat32.readFile(desc.fat32_file_idx, @intCast(desc.offset), buf, @intCast(count));
                if (n > 0) {
                    desc.offset += @intCast(n);
                    // 4. Update readahead state and trigger prefetch
                    readahead.checkAndPrefetch(&desc.readahead_state, desc.offset, 4096, fat32ReadBlock);
                    // 5. Track access pattern for page cache hints
                    const cur_page = desc.offset / 4096;
                    _ = page_cache.recordAccess(desc.inode_id, cur_page);
                }
                return n;
            },
            .ext2_file => {
                if (desc.offset >= desc.file_size) return 0;
                // 1. Check writeback cache (read-after-write consistency)
                const n_cached = writeback.readBuffered(desc.ext2_file_idx, desc.offset, buf, @intCast(count), .ext2);
                if (n_cached > 0) {
                    desc.offset += @as(u64, n_cached);
                    return @intCast(n_cached);
                }
                // v53.32: Removed VFS-level readahead for ext2 — ext2ReadBlock was
                // missing DISK_LBA_OFFSET (read from disk start, not ext2 partition)
                // and bypassed ext2 block mapping (assumed contiguous layout).
                // ext2.readFile has its own page_cache prefetch (prefetchPages) that
                // correctly uses resolveBlock + readBlockUncached with LBA offset.
                // Also removed VFS-level recordAccess which used 4KB page numbers
                // conflicting with ext2's 1KB block numbers in the same tracker.
                const ext2 = @import("ext2.zig");
                const n = ext2.readFile(desc.ext2_file_idx, @intCast(desc.offset), buf, @intCast(count));
                if (n > 0) {
                    desc.offset += @intCast(n);
                }
                return n;
            },
            .pipe_read => {
                return pipeRead(desc.pipe_idx, buf, count);
            },
            .pipe_write => return -1, // can't read from write end
            .tcp_socket => return -1, // TCP sockets use sendto/recvfrom syscalls
            .udp_socket => return -1, // UDP sockets use sendto/recvfrom syscalls
            .epoll => return -1,
            .eventfd => return -1,
            .unix_socket => return -1,
            .timerfd => {
                const timerfd_mod = @import("../ipc/timerfd.zig");
                return timerfd_mod.timerfdRead(desc.timerfd_idx, buf, count);
            },
            .random => {
                const random_mod = @import("../drivers/random.zig");
                const to_read: u32 = @intCast(@min(count, 256));
                var kbuf: [256]u8 = undefined;
                random_mod.getRandomBytes(&kbuf, to_read);
                @memcpy(buf[0..to_read], kbuf[0..to_read]);
                return @intCast(to_read);
            },
            .tmpfs_file => {
                const tmpfs = @import("tmpfs.zig");
                if (desc.offset >= desc.file_size) return 0;
                const n = tmpfs.tmpfsRead(@intCast(desc.tmpfs_idx), desc.offset, buf, @intCast(count));
                if (n > 0) {
                    desc.offset += @intCast(n);
                }
                return n;
            },
            .proc_file => {
                const procfs = @import("procfs.zig");
                var scratch: [4096]u8 = undefined;
                const generated = procfs.procRead(desc.proc_file_type, desc.proc_pid, &scratch, 4096);
                if (desc.offset >= generated) return 0;
                const avail = generated - @as(u32, @intCast(desc.offset));
                const to_copy = @min(@as(u32, @intCast(count)), avail);
                @memcpy(buf[0..to_copy], scratch[@as(u32, @intCast(desc.offset)) .. @as(u32, @intCast(desc.offset)) + to_copy]);
                desc.offset += to_copy;
                return @intCast(to_copy);
            },
            .inotify => return -1, // inotify uses read via special syscall path
            .raw_socket => {
                // Raw socket: receive raw ethernet frame
                const e1000 = @import("../drivers/e1000.zig");
                if (!e1000.isActive()) return -1;
                const max: u32 = @intCast(@min(count, 2048));
                const n = e1000.receivePacket(buf, max);
                return @intCast(n);
            },
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
            .pipe_read => return -1,
            .fat32_file => {
                if (!desc.writable) return -1;
                // Use writeback for delayed write coalescing
                writeback.writeBuffered(desc.fat32_file_idx, desc.offset, buf, @intCast(count), .fat32);
                desc.offset += count;
                if (desc.offset > desc.file_size) desc.file_size = desc.offset;
                return @intCast(count);
            },
            .ramdisk_file => return -1,
            .ext2_file => {
                if (!desc.writable) return -1;
                // Use writeback for delayed write coalescing
                writeback.writeBuffered(desc.ext2_file_idx, desc.offset, buf, @intCast(count), .ext2);
                desc.offset += count;
                if (desc.offset > desc.file_size) desc.file_size = desc.offset;
                return @intCast(count);
            },
            .tcp_socket => return -1, // TCP sockets use sendto/recvfrom syscalls
            .udp_socket => return -1, // UDP sockets use sendto/recvfrom syscalls
            .epoll => return -1,
            .eventfd => return -1,
            .unix_socket => return -1,
            .timerfd => return -1, // timerfd is read-only
            .random => return -1, // random is read-only
            .tmpfs_file => {
                if (!desc.writable) return -1;
                const tmpfs = @import("tmpfs.zig");
                const n = tmpfs.tmpfsWrite(@intCast(desc.tmpfs_idx), desc.offset, buf, @intCast(count));
                if (n > 0) {
                    desc.offset += @intCast(n);
                    if (desc.offset > desc.file_size) {
                        desc.file_size = desc.offset;
                    }
                }
                return n;
            },
            .proc_file => return -1, // proc files are read-only
            .inotify => return -1, // inotify is read-only via special path
            .raw_socket => {
                // Raw socket: send raw ethernet frame
                const e1000 = @import("../drivers/e1000.zig");
                if (!e1000.isActive()) return -1;
                if (count > 2048) return -22; // EMSGSIZE
                const len: u32 = @intCast(count);
                if (e1000.sendPacket(buf, len)) {
                    return @intCast(count);
                }
                return -1;
            },
        }
    }

    /// v53.47: Check if another fd in this table shares the same underlying
    /// resource (via dup2). Used by close() to avoid freeing resources still
    /// referenced by a dup'd fd — prevents use-after-free.
    /// Pipes are excluded — they use a separate ref_count in the Pipe struct.
    fn hasSharedRef(self: *FdTable, fd: u32) bool {
        const desc = &self.fds[fd];
        for (0..MAX_FDS) |i| {
            if (i == fd) continue;
            const other = &self.fds[i];
            if (other.fd_type != desc.fd_type) continue;
            switch (desc.fd_type) {
                .ext2_file => if (other.ext2_file_idx == desc.ext2_file_idx) return true,
                .fat32_file => if (other.fat32_file_idx == desc.fat32_file_idx) return true,
                .tcp_socket => if (other.tcb_idx == desc.tcb_idx) return true,
                .epoll => if (other.epoll_idx == desc.epoll_idx) return true,
                .unix_socket => if (other.unix_sock_idx == desc.unix_sock_idx) return true,
                .timerfd => if (other.timerfd_idx == desc.timerfd_idx) return true,
                .tmpfs_file => if (other.tmpfs_idx == desc.tmpfs_idx) return true,
                .eventfd => if (other.eventfd_idx == desc.eventfd_idx) return true,
                .ramdisk_file => if (other.file_data == desc.file_data) return true,
                else => {},
            }
        }
        return false;
    }

    /// Close a file descriptor.
    pub fn close(self: *FdTable, fd: u32) i64 {
        if (fd >= MAX_FDS) return -1;
        if (fd <= FD_STDERR) return 0;
        const desc = &self.fds[fd];
        if (desc.fd_type == .none) return -1;
        // v53.47: If another fd shares the same underlying resource (via dup2),
        // skip resource cleanup — only clear this fd entry.
        if (desc.fd_type != .pipe_read and desc.fd_type != .pipe_write) {
            if (self.hasSharedRef(fd)) {
                desc.* = .{};
                return 0;
            }
        }
        if (desc.fd_type == .pipe_read or desc.fd_type == .pipe_write) {
            pipeClose(desc.pipe_idx);
        }
        if (desc.fd_type == .ext2_file) {
            writeback.invalidateFile(desc.ext2_file_idx, .ext2, ext2WriteFlush);
            const ext2 = @import("ext2.zig");
            ext2.closeFile(desc.ext2_file_idx);
        }
        if (desc.fd_type == .fat32_file) {
            writeback.invalidateFile(desc.fat32_file_idx, .fat32, fat32WriteFlush);
            readahead.invalidateCache(&desc.readahead_state);
        }
        if (desc.fd_type == .tcp_socket) {
            const tcp = @import("../net/tcp.zig");
            _ = tcp.tcpClose(desc.tcb_idx);
        }
        if (desc.fd_type == .epoll) {
            const epoll_mod = @import("../net/epoll.zig");
            epoll_mod.epollDestroy(desc.epoll_idx);
        }
        if (desc.fd_type == .eventfd) {
            // eventfd cleanup: no module yet
        }
        if (desc.fd_type == .unix_socket) {
            const unix_mod = @import("../net/unix_socket.zig");
            unix_mod.unixClose(desc.unix_sock_idx);
        }
        if (desc.fd_type == .timerfd) {
            const timerfd_mod = @import("../ipc/timerfd.zig");
            timerfd_mod.timerfdClose(desc.timerfd_idx);
        }
        if (desc.fd_type == .tmpfs_file) {
            const tmpfs = @import("tmpfs.zig");
            tmpfs.tmpfsClose(@intCast(desc.tmpfs_idx));
        }
        // proc_file needs no special cleanup
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

/// Block read callback for readahead — read a 4KB block from disk.
fn fat32ReadBlock(block_num: u64, buf: [*]u8) bool {
    const virtio_blk = @import("../drivers/virtio_blk.zig");
    const lba = block_num * 8; // 4KB/512=8 sectors
    const result = virtio_blk.readSectors(lba, 8, buf);
    return result > 0;
}

/// Write flush callbacks for writeback — flush dirty buffers via FS write.
fn ext2WriteFlush(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32) bool {
    const ext2 = @import("ext2.zig");
    const n = ext2.writeFile(file_idx, @intCast(byte_offset), data, len);
    return n > 0;
}

fn fat32WriteFlush(file_idx: u32, byte_offset: u64, data: [*]const u8, len: u32) bool {
    const fat32 = @import("fat32.zig");
    const n = fat32.writeFile(file_idx, @intCast(byte_offset), data, len);
    return n > 0;
}

/// v53.33: Register flush callbacks so writeback can flush dirty buffers
/// during eviction (prevents data loss when all 512 buffer slots are full).
pub fn initWritebackCallbacks() void {
    writeback.setFlushCallback(.ext2, ext2WriteFlush);
    writeback.setFlushCallback(.fat32, fat32WriteFlush);
}

/// Public API: Drive writeback timer from scheduler tick.
pub fn writebackTimerTick() bool {
    const expired = writeback.writebackTimerTick();
    if (expired) {
        writeback.flushExpiredByFs(.ext2, ext2WriteFlush);
        writeback.flushExpiredByFs(.fat32, fat32WriteFlush);
    }
    return expired;
}

/// Public API: Sync all dirty buffers to disk (fsync/sync).
pub fn syncAll() void {
    writeback.flushAllByType(.ext2, ext2WriteFlush);
    writeback.flushAllByType(.fat32, fat32WriteFlush);
}

/// Sync a specific file's dirty buffers to disk.
pub fn syncFile(file_idx: u32, fs_type: writeback.FsType) void {
    switch (fs_type) {
        .ext2 => writeback.flushFile(file_idx, .ext2, ext2WriteFlush),
        .fat32 => writeback.flushFile(file_idx, .fat32, fat32WriteFlush),
        .none => {},
    }
}

// ── Mount table (Phase 18) ──────────────────────────────────────

pub const MAX_MOUNTS: u32 = 16;

pub const MountPoint = struct {
    active: bool = false,
    /// Device/source path (e.g. "/dev/sda1", "tmpfs")
    source: [64]u8 = @splat(0),
    source_len: u32 = 0,
    /// Mount target path (e.g. "/mnt", "/tmp")
    target: [128]u8 = @splat(0),
    target_len: u32 = 0,
    /// Filesystem type string (e.g. "ext2", "tmpfs", "ramfs", "proc")
    fs_type: [16]u8 = @splat(0),
    fs_type_len: u32 = 0,
    /// Mount flags (MS_RDONLY=1, MS_NOSUID=2, etc.)
    flags: u64 = 0,
};

var mount_table: [MAX_MOUNTS]MountPoint = @splat(.{});

/// mount(source, target, fs_type, flags) -> 0 or -errno
pub fn mountFs(source: []const u8, target: []const u8, fs_type: []const u8, flags: u64) i64 {
    if (target.len == 0) return -22; // -EINVAL
    if (target.len > 128 or source.len > 64 or fs_type.len > 16) return -36; // -ENAMETOOLONG

    // Find free slot
    var slot: ?u32 = null;
    for (0..MAX_MOUNTS) |i| {
        if (!mount_table[i].active) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot == null) return -28; // -ENOSPC

    const idx = slot.?;
    var mp = &mount_table[idx];

    // Copy source
    @memset(&mp.source, 0);
    for (0..source.len) |j| mp.source[j] = source[j];
    mp.source_len = @intCast(source.len);

    // Copy target
    @memset(&mp.target, 0);
    for (0..target.len) |j| mp.target[j] = target[j];
    mp.target_len = @intCast(target.len);

    // Copy fs_type
    @memset(&mp.fs_type, 0);
    for (0..fs_type.len) |j| mp.fs_type[j] = fs_type[j];
    mp.fs_type_len = @intCast(fs_type.len);

    mp.flags = flags;
    mp.active = true;

    // Initialize filesystem based on type
    if (eqlStr(fs_type, "tmpfs")) {
        const tmpfs = @import("tmpfs.zig");
        tmpfs.init();
    } else if (eqlStr(fs_type, "ext2")) {
        const ext2 = @import("ext2.zig");
        ext2.init();
    } else if (eqlStr(fs_type, "vfat") or eqlStr(fs_type, "fat32")) {
        const fat32 = @import("fat32.zig");
        fat32.init();
    } else if (eqlStr(fs_type, "proc")) {
        // procfs is always available, no init needed
    } else if (eqlStr(fs_type, "ramfs") or eqlStr(fs_type, "rootfs")) {
        // ramfs uses ramdisk, already initialized
    }
    // Unknown types are still recorded (user may just want bind mount)

    serial.writeString("[vfs] mount: ");
    serial.writeString(source);
    serial.writeString(" -> ");
    serial.writeString(target);
    serial.writeString(" (");
    serial.writeString(fs_type);
    serial.writeString(")\n");

    return 0;
}

/// umount(target, flags) -> 0 or -errno
pub fn umountFs(target: []const u8, mflags: u32) i64 {
    _ = mflags;
    if (target.len == 0) return -22; // -EINVAL

    for (&mount_table) |*mp| {
        if (!mp.active) continue;
        const t = mp.target[0..mp.target_len];
        if (eqlStr(t, target)) {
            serial.writeString("[vfs] umount: ");
            serial.writeString(target);
            serial.writeString("\n");
            mp.* = .{};
            return 0;
        }
    }
    return -22; // -EINVAL (not mounted)
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}
