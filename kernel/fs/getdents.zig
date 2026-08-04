// kernel/fs/getdents.zig — Directory entry reading (getdents64)
//
// Implements the getdents64() syscall: read directory entries in linux_dirent64
// format from ext2 and tmpfs filesystems.

const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const vfs_mod = @import("vfs.zig");
const ext2 = @import("ext2.zig");
const tmpfs = @import("tmpfs.zig");
const copy = @import("../mm/copy_from_user.zig");
const bo = @import("../lib/byte_order.zig");

/// getdents64(fd, buf_ptr, buf_size) → bytes written, 0 on EOF, or -errno
pub fn getdents64(fd: u32, buf_ptr: u64, buf_size: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or buf_size < 24) return -14;

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9;
    const desc = &cur.fd_table.fds[fd];
    if (desc.fd_type == .none) return -9;

    // ext2 directory
    if (desc.fd_type == .ext2_file) {
        return getdents64Ext2(desc, buf_ptr, buf_size);
    }

    // tmpfs directory
    if (desc.fd_type == .tmpfs_file) {
        return getdents64Tmpfs(desc, buf_ptr, buf_size);
    }

    // devfs directory (/dev)
    if (desc.fd_type == .devfs) {
        const devfs = @import("devfs.zig");
        if (desc.devfs_idx == devfs.DIR_IDX) return getdents64Devfs(desc, buf_ptr, buf_size);
        return -20; // ENOTDIR — a device node is not a directory
    }

    return -20; // ENOTDIR
}

/// Enumerate registered devfs nodes. The descriptor offset is simply the
/// next node slot index — the table is append-only after init, so slots
/// are dense and stable.
fn getdents64Devfs(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    const devfs = @import("devfs.zig");
    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    const start: u32 = @intCast(@min(desc.offset, 0xFFFFFFFF));
    var idx: u32 = start;
    while (idx < devfs.nodeCount()) : (idx += 1) {
        const name = devfs.nameAt(idx) orelse break;
        const reclen: u16 = @intCast(19 + name.len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        const ino: u64 = idx + 1;
        bo.writeU64Le(kbuf[base .. base + 8], ino);
        const doff: u64 = idx + 1;
        bo.writeU64Le(kbuf[base + 8 .. base + 16], doff);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = 2; // DT_CHR — all devfs nodes are char devices
        @memcpy(kbuf[base + 19 .. base + 19 + name.len], name);
        kbuf[base + 19 + name.len] = 0;
        written += padded_reclen;
        emitted += 1;
    }
    if (emitted == 0) {
        // Nothing emitted is end of directory only if there was nothing
        // left to emit; otherwise the buffer was too small.
        return if (start >= devfs.nodeCount()) 0 else -22;
    }
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = start + emitted;
    return @intCast(written);
}

fn getdents64Ext2(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    // v53.4: dynamically allocate names array to avoid 16KB stack usage
    // 64 entries × 256 bytes = 16384 bytes = 4 pages
    const pmm = @import("../mm/pmm.zig");
    const hhdm = @import("../mm/hhdm.zig");
    const names_pages = pmm.allocContiguous(4) orelse return -12; // ENOMEM
    defer {
        for (0..4) |p| pmm.freePage(names_pages + p * 4096);
    }
    const names: [*][256]u8 = @ptrFromInt(hhdm.physToVirt(names_pages));
    var name_lens: [64]u32 = undefined;
    var inodes_arr: [64]u32 = undefined;
    var ftypes: [64]u8 = undefined;
    var next_offs: [64]u32 = undefined;
    const off32: u32 = @intCast(@min(desc.offset, 0xFFFFFFFF));
    const result = ext2.readDirEntries(desc.ext2_file_idx, off32, names, &name_lens, &inodes_arr, &ftypes, &next_offs, 64);
    if (result.count == 0) return 0;

    var written: u64 = 0;
    var emitted: u32 = 0;
    var kbuf: [4096]u8 = undefined;
    for (0..result.count) |i| {
        const name_len = name_lens[i];
        const reclen: u16 = @intCast(19 + name_len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        const ino: u64 = inodes_arr[i];
        bo.writeU64Le(kbuf[base .. base + 8], ino);
        const doff: u64 = next_offs[i];
        bo.writeU64Le(kbuf[base + 8 .. base + 16], doff);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = ftypes[i];
        const nlen: usize = @intCast(name_len);
        @memcpy(kbuf[base + 19 .. base + 19 + nlen], names[i][0..nlen]);
        kbuf[base + 19 + nlen] = 0;
        var pad = base + 19 + nlen + 1;
        while (pad < base + padded_reclen) : (pad += 1) {
            kbuf[pad] = 0;
        }
        written += padded_reclen;
        emitted += 1;
    }

    // A buffer too small for even the first entry is EINVAL, not end of
    // directory: reporting 0 would tell the caller the directory ended here.
    if (emitted == 0) return -22;

    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;

    // Resume from the entry after the last one actually handed to the user.
    // Using the last entry `readDirEntries` produced would skip everything the
    // buffer had no room for.
    desc.offset = next_offs[emitted - 1];
    return @intCast(written);
}

fn getdents64Tmpfs(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    // v53.51: tmpfsListDir copies entries+names into caller-owned buffers
    // under tmpfs_lock — one page holds all names (64 entries x 60 bytes).
    const pmm = @import("../mm/pmm.zig");
    const hhdm = @import("../mm/hhdm.zig");
    const names_phys = pmm.allocPage() orelse return -12; // ENOMEM
    defer pmm.freePage(names_phys);
    const names_buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(names_phys));
    var entries_buf: [64]tmpfs.TmpfsDirEntry = undefined;

    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    const entries = tmpfs.tmpfsListDir(@intCast(desc.tmpfs_idx), &entries_buf, names_buf, 4096);
    const start: u32 = @intCast(desc.offset);
    var idx: u32 = start;
    while (idx < entries.count) : (idx += 1) {
        const e = entries.entries[idx];
        const name_len = e.name.len;
        const reclen: u16 = @intCast(19 + name_len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        const ino: u64 = 1;
        bo.writeU64Le(kbuf[base .. base + 8], ino);
        const doff: u64 = idx + 1;
        bo.writeU64Le(kbuf[base + 8 .. base + 16], doff);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = if (e.is_dir) @as(u8, 4) else @as(u8, 8);
        @memcpy(kbuf[base + 19 .. base + 19 + name_len], e.name.ptr[0..name_len]);
        kbuf[base + 19 + name_len] = 0;
        written += padded_reclen;
        emitted += 1;
    }
    if (emitted == 0) {
        // Nothing emitted is end of directory only if there was nothing left to
        // emit; otherwise the buffer was too small for the next entry.
        return if (start >= entries.count) 0 else -22;
    }
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = start + emitted;
    return @intCast(written);
}
