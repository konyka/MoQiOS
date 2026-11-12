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
const policy = @import("getdents_policy.zig");

/// getdents64(fd, buf_ptr, buf_size) → bytes written, 0 on EOF, or -errno
pub fn getdents64(fd: u32, buf_ptr: u64, buf_size: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000 or buf_size < 24) return -14;

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (fd >= vfs_mod.MAX_FDS) return -9;
    const desc = &cur.fd_table.fds[fd];
    if (desc.fd_type == .none) return -9;

    // A directory cursor is part of the open file description: dup()/fork() share it.
    vfs_mod.syncOffsetIn(desc);
    defer vfs_mod.syncOffsetOut(desc);

    // ext2 directory
    if (desc.fd_type == .ext2_file) {
        return getdents64Ext2(desc, buf_ptr, buf_size);
    }

    // ext4 / NTFS directory
    if (desc.fd_type == .rofs_file) {
        return getdents64Rofs(desc, buf_ptr, buf_size);
    }

    // tmpfs directory
    if (desc.fd_type == .tmpfs_file) {
        return getdents64Tmpfs(desc, buf_ptr, buf_size, cur.euid, cur.egid, cur.effective_caps);
    }

    // procfs directories (/proc and /proc/<pid>) and the synthetic directories above mount points
    if (desc.fd_type == .proc_file) {
        if (!@import("procfs.zig").isDir(desc.proc_file_type)) return -20; // ENOTDIR
        if (desc.proc_file_type == .mount_dir) return getdents64MountDir(desc, buf_ptr, buf_size);
        if (desc.proc_file_type == .fd_dir) return getdents64FdDir(desc, buf_ptr, buf_size);
        return getdents64Proc(desc, buf_ptr, buf_size);
    }

    // devfs directory (/dev)
    if (desc.fd_type == .devfs) {
        const devfs = @import("devfs.zig");
        if (desc.devfs_idx == devfs.DIR_IDX) return getdents64Devfs(desc, buf_ptr, buf_size);
        return -20; // ENOTDIR — a device node is not a directory
    }

    return -20; // ENOTDIR
}

/// List /proc/<pid>/fd: "." and "..", then the number of each open descriptor of the process, in order. The descriptor table is read live,
/// so a descriptor opened or closed between two calls shifts the positions after it.
fn getdents64FdDir(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    const start: u32 = policy.clampOffset(desc.offset);
    var pos: u32 = start;
    var exhausted = false;
    // The target process's descriptor table (a thread shares its process's table).
    var target: ?*task_mod.Task = null;
    var ti: u32 = 0;
    while (ti < task_mod.MAX_TASKS) : (ti += 1) {
        if (task_mod.getTask(ti)) |t| {
            if (t.tid == desc.proc_pid and !t.is_thread) {
                target = t;
                break;
            }
        }
    }
    while (true) : (pos += 1) {
        var num_buf: [12]u8 = undefined;
        var name: []const u8 = undefined;
        if (pos == 0) {
            name = ".";
        } else if (pos == 1) {
            name = "..";
        } else {
            // The (pos - 2)-th open descriptor.
            var want: u32 = pos - 2;
            var found: ?u32 = null;
            if (target) |t| {
                var fdn: u32 = 0;
                while (fdn < vfs_mod.MAX_FDS) : (fdn += 1) {
                    if (t.fd_table.fds[fdn].fd_type == .none) continue;
                    if (want == 0) {
                        found = fdn;
                        break;
                    }
                    want -= 1;
                }
            }
            const fdn = found orelse {
                exhausted = true;
                break;
            };
            var digits: [12]u8 = undefined;
            var n: usize = 0;
            var v: u32 = fdn;
            if (v == 0) {
                digits[0] = '0';
                n = 1;
            }
            while (v > 0) : (v /= 10) {
                digits[n] = '0' + @as(u8, @intCast(v % 10));
                n += 1;
            }
            for (0..n) |k| num_buf[k] = digits[n - 1 - k];
            name = num_buf[0..n];
        }
        const reclen: u16 = @intCast(19 + name.len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        bo.writeU64Le(kbuf[base .. base + 8], 0x7FFB_0000 + pos);
        bo.writeU64Le(kbuf[base + 8 .. base + 16], @as(u64, pos) + 1);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = if (pos < 2) 4 else 10; // DT_DIR for the dot entries, DT_LNK for a descriptor (they are symlinks on Linux)
        @memcpy(kbuf[base + 19 .. base + 19 + name.len], name);
        kbuf[base + 19 + name.len] = 0;
        var pad = base + 19 + name.len + 1;
        while (pad < base + padded_reclen) : (pad += 1) kbuf[pad] = 0;
        written += padded_reclen;
        emitted += 1;
    }
    if (emitted == 0) return if (exhausted) 0 else -22;
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = policy.nextOffset(start, emitted);
    return @intCast(written);
}

/// List a directory that exists only above mount points: "." and "..", then the one-level-down name of each mount below it.
fn getdents64MountDir(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    const dir = desc.mount_dir_path[0..desc.mount_dir_len];
    const start: u32 = policy.clampOffset(desc.offset);
    var pos: u32 = start;
    var exhausted = false;
    while (true) : (pos += 1) {
        var name_buf: [64]u8 = undefined;
        var name: []const u8 = undefined;
        if (pos == 0) {
            name = ".";
        } else if (pos == 1) {
            name = "..";
        } else {
            name = vfs_mod.mountChildAt(dir, pos - 2, &name_buf) orelse {
                exhausted = true;
                break;
            };
        }
        const reclen: u16 = @intCast(19 + name.len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        bo.writeU64Le(kbuf[base .. base + 8], 0x7FFD_0000 + pos);
        bo.writeU64Le(kbuf[base + 8 .. base + 16], @as(u64, pos) + 1);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = 4; // DT_DIR
        @memcpy(kbuf[base + 19 .. base + 19 + name.len], name);
        kbuf[base + 19 + name.len] = 0;
        var pad = base + 19 + name.len + 1;
        while (pad < base + padded_reclen) : (pad += 1) kbuf[pad] = 0;
        written += padded_reclen;
        emitted += 1;
    }
    if (emitted == 0) return if (exhausted) 0 else -22;
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = policy.nextOffset(start, emitted);
    return @intCast(written);
}

/// List /proc or /proc/<pid>. The descriptor offset is the position in the listing (the entries are produced on demand from the live task
/// table, so a process that starts or exits between two calls can shift later positions).
fn getdents64Proc(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    const procfs = @import("procfs.zig");
    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    const start: u32 = policy.clampOffset(desc.offset);
    var pos: u32 = start;
    var exhausted = false;
    while (true) : (pos += 1) {
        const e = (if (desc.proc_file_type == .root_dir) procfs.rootEntryAt(pos) else procfs.pidEntryAt(pos)) orelse {
            exhausted = true;
            break;
        };
        const name_len: usize = e.len;
        const reclen: u16 = @intCast(19 + name_len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        bo.writeU64Le(kbuf[base .. base + 8], 1);
        bo.writeU64Le(kbuf[base + 8 .. base + 16], @as(u64, pos) + 1);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = e.dtype;
        @memcpy(kbuf[base + 19 .. base + 19 + name_len], e.name[0..name_len]);
        kbuf[base + 19 + name_len] = 0;
        var pad = base + 19 + name_len + 1;
        while (pad < base + padded_reclen) : (pad += 1) kbuf[pad] = 0;
        written += padded_reclen;
        emitted += 1;
    }
    if (emitted == 0) return if (exhausted) 0 else -22; // end of directory, or a buffer too small for even one entry
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = policy.nextOffset(start, emitted);
    return @intCast(written);
}

/// Enumerate registered devfs nodes. The descriptor offset is simply the
/// next node slot index — the table is append-only after init, so slots
/// are dense and stable. Tombstoned slots (userspace node owner death,
/// devfs.unregister) are skipped; the cursor still advances past them.
fn getdents64Devfs(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    const devfs = @import("devfs.zig");
    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    const start: u32 = @intCast(@min(desc.offset, 0xFFFFFFFF));
    var idx: u32 = start;
    var cursor: u32 = start;
    while (idx < devfs.nodeCount()) : (idx += 1) {
        const name = devfs.nameAt(idx) orelse {
            cursor = idx + 1; // tombstone: skip, but advance the cursor
            continue;
        };
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
        cursor = idx + 1;
    }
    if (emitted == 0) {
        // Nothing emitted is end of directory only when the scan reached
        // the end of the table (tombstones included); otherwise the
        // buffer was too small for the next live entry.
        return if (cursor >= devfs.nodeCount()) 0 else -22;
    }
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = cursor;
    return @intCast(written);
}

/// Directory listing of a mounted ext4/NTFS volume. desc.offset is the opaque
/// resume cookie rofs.dirNext hands out (it counts "." and ".." too).
fn getdents64Rofs(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    const rofs = @import("rofs.zig");
    const fsr = @import("fs_reader.zig");
    if (!desc.rofs_is_dir) return -20; // ENOTDIR
    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    var pos: u64 = desc.offset;
    const limit = @min(buf_size, 4096);
    while (true) {
        var e: fsr.DirEntry = undefined;
        var next: u64 = 0;
        const r = rofs.dirNext(desc.rofs_mount, desc.rofs_gen, desc.rofs_ref, @intFromPtr(desc), pos, &e, &next);
        if (r < 0) {
            if (emitted > 0) break; // hand over what we have; the error returns next call
            return r;
        }
        if (r == 0) break;
        const nlen: usize = e.name_len;
        const reclen: u16 = @intCast(19 + nlen + 1);
        const padded: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded > limit) break;
        const base: usize = @intCast(written);
        bo.writeU64Le(kbuf[base .. base + 8], e.ino);
        bo.writeU64Le(kbuf[base + 8 .. base + 16], next);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded);
        kbuf[base + 18] = fsr.dType(e.kind);
        @memcpy(kbuf[base + 19 .. base + 19 + nlen], e.name[0..nlen]);
        @memset(kbuf[base + 19 + nlen .. base + padded], 0);
        written += padded;
        emitted += 1;
        pos = next;
    }
    if (emitted == 0) {
        // Nothing fit: a too-small buffer is EINVAL, a finished directory is 0.
        var e: fsr.DirEntry = undefined;
        var next: u64 = 0;
        const probe = rofs.dirNext(desc.rofs_mount, desc.rofs_gen, desc.rofs_ref, @intFromPtr(desc), pos, &e, &next);
        return if (probe > 0) -22 else probe;
    }
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = pos;
    return @intCast(written);
}

/// Cursor values from here up index the root's virtual entries; ext2 directory offsets are byte positions below the directory size.
const ROOT_VIRTUAL_BASE: u64 = 0x4000_0000;
/// The mount points that hang off "/" and are not entries of the ext2 root. An ext2 entry with the same name would be listed twice.
const root_virtual_names = [_][]const u8{ "tmp", "dev", "proc" };

/// The tail of the root listing: tmp, dev and proc as directories, then the FAT32 volume's root entries (bare file names live there).
fn getdents64RootVirtual(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64) i64 {
    const fat32 = @import("fat32.zig");
    var kbuf: [4096]u8 = undefined;
    var written: u64 = 0;
    var emitted: u32 = 0;
    var k: u64 = desc.offset - ROOT_VIRTUAL_BASE;
    var exhausted = false;
    // How many FAT32 entries the root has, counted once for this call (it changes as files come and go).
    var fat_total: u32 = 0;
    if (fat32.isActive()) {
        while (fat32.rootEntryAt(fat_total) != null) fat_total += 1;
    }
    while (true) : (k += 1) {
        var name_buf: [256]u8 = undefined;
        var name: []const u8 = undefined;
        var dtype: u8 = 4; // DT_DIR
        var ino: u64 = 0x7FFF_0000 + k;
        if (k < root_virtual_names.len) {
            name = root_virtual_names[@intCast(k)];
        } else {
            const fat_index: u32 = @intCast(k - root_virtual_names.len);
            if (fat32.isActive() and fat32.rootEntryAt(fat_index) != null) {
                const fe = fat32.rootEntryAt(fat_index).?;
                @memcpy(name_buf[0..fe.len], fe.name[0..fe.len]);
                name = name_buf[0..fe.len];
                dtype = if (fe.is_dir) 4 else 8; // DT_DIR or DT_REG
                ino = 0x7FFE_0000 + k;
            } else {
                // After the FAT32 entries come the directories that exist only because a volume is mounted below them ("mnt" for
                // /mnt/e).
                const mount_index: u32 = @intCast(k - root_virtual_names.len - fat_total);
                const mc = vfs_mod.mountChildAt("/", mount_index, &name_buf) orelse {
                    exhausted = true;
                    break;
                };
                name = mc;
                ino = 0x7FFC_0000 + k;
            }
        }
        const reclen: u16 = @intCast(19 + name.len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        bo.writeU64Le(kbuf[base .. base + 8], ino);
        bo.writeU64Le(kbuf[base + 8 .. base + 16], ROOT_VIRTUAL_BASE + k + 1);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = dtype;
        @memcpy(kbuf[base + 19 .. base + 19 + name.len], name);
        kbuf[base + 19 + name.len] = 0;
        var pad = base + 19 + name.len + 1;
        while (pad < base + padded_reclen) : (pad += 1) kbuf[pad] = 0;
        written += padded_reclen;
        emitted += 1;
    }
    if (emitted == 0) return if (exhausted) 0 else -22; // end of directory, or a buffer too small for one entry
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = ROOT_VIRTUAL_BASE + k;
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
    // The root of the tree lists the directories that hang off it besides its own entries (tmp, dev, proc), after the ext2 entries. They
    // use their own cursor range, far above any ext2 byte offset.
    // A removed directory lists nothing and is ENOENT (Linux, measured), even though its own "." and ".." records are still on disk.
    if (ext2.openPathDeleted(desc.ext2_file_idx)) return -2;
    const is_root = ext2.getInodeNum(desc.ext2_file_idx) == 2;
    if (is_root and desc.offset >= ROOT_VIRTUAL_BASE) return getdents64RootVirtual(desc, buf_ptr, buf_size);
    const off32: u32 = @intCast(@min(desc.offset, 0xFFFFFFFF));
    const result = ext2.readDirEntries(desc.ext2_file_idx, off32, names, &name_lens, &inodes_arr, &ftypes, &next_offs, 64);
    if (result.count == 0) {
        if (!is_root) return 0;
        desc.offset = ROOT_VIRTUAL_BASE;
        return getdents64RootVirtual(desc, buf_ptr, buf_size);
    }

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

fn getdents64Tmpfs(desc: *vfs_mod.FileDescriptor, buf_ptr: u64, buf_size: u64, euid: u32, egid: u32, effective_caps: @import("../proc/capability_profile.zig").SysCap) i64 {
    if (!tmpfs.tmpfsCanListDir(@intCast(desc.tmpfs_idx), euid, egid, effective_caps)) return -13;

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
    // The listing is "." and ".." followed by the children, and the cursor counts entries from its start. The children are fetched
    // from the cursor's position on (skip), at most one table-sized batch per call, so a directory is not capped at one batch.
    const start: u32 = policy.clampOffset(desc.offset);
    const child_skip: u32 = if (start > 2) start - 2 else 0;
    const entries = tmpfs.tmpfsListDir(@intCast(desc.tmpfs_idx), child_skip, &entries_buf, names_buf, 4096);
    const available: u32 = (if (start < 2) 2 - start else 0) + entries.count;
    var step: u32 = 0;
    while (step < available) : (step += 1) {
        const pos: u32 = start + step;
        var name: []const u8 = undefined;
        var is_dir = true;
        if (pos == 0) {
            name = ".";
        } else if (pos == 1) {
            name = "..";
        } else {
            const e = entries.entries[pos - 2 - child_skip];
            name = e.name;
            is_dir = e.is_dir;
        }
        const name_len = name.len;
        const reclen: u16 = @intCast(19 + name_len + 1);
        const padded_reclen: u16 = (reclen + 7) & ~@as(u16, 7);
        if (written + padded_reclen > @min(buf_size, 4096)) break;
        const base = @as(usize, @intCast(written));
        const ino: u64 = 1;
        bo.writeU64Le(kbuf[base .. base + 8], ino);
        const doff: u64 = @as(u64, pos) + 1;
        bo.writeU64Le(kbuf[base + 8 .. base + 16], doff);
        bo.writeU16Le(kbuf[base + 16 .. base + 18], padded_reclen);
        kbuf[base + 18] = if (is_dir) @as(u8, 4) else @as(u8, 8);
        @memcpy(kbuf[base + 19 .. base + 19 + name_len], name.ptr[0..name_len]);
        kbuf[base + 19 + name_len] = 0;
        written += padded_reclen;
        emitted += 1;
    }
    if (emitted == 0) {
        // Nothing emitted is end of directory only if there was nothing left to
        // emit; otherwise the buffer was too small for the next entry.
        return if (available == 0) 0 else -22;
    }
    const n: usize = @intCast(written);
    if (copy.copyToUser(@ptrFromInt(buf_ptr), kbuf[0..n], n) != n) return -14;
    desc.offset = policy.nextOffset(start, emitted);
    return @intCast(written);
}
