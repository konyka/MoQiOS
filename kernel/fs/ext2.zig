/// ext2 filesystem driver (read-only).
///
/// Supports:
///   - Superblock parsing
///   - Block group descriptor table
///   - Inode reading (direct blocks only for simplicity)
///   - Directory entry parsing
///   - File read via block indirection (direct + single indirect)
///
/// Designed for ext2 with 1024-byte blocks (revision 0 / "good old ext2").
/// Read-only — no write support.

const serial = @import("../arch/x86_64/serial.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");

const SECTOR_SIZE: u32 = 512;
const MAX_OPEN_FILES: u32 = 16;
const MAX_FILENAME: u32 = 256;

// ─── ext2 on-disk structures ──────────────────────────────────────────────

const Ext2Superblock = extern struct {
    inodes_count: u32,
    blocks_count: u32,
    r_blocks_count: u32,
    free_blocks_count: u32,
    free_inodes_count: u32,
    first_data_block: u32,
    log_block_size: u32,
    log_frag_size: u32,
    blocks_per_group: u32,
    frags_per_group: u32,
    inodes_per_group: u32,
    mtime: u32,
    wtime: u32,
    mnt_count: u16,
    max_mnt_count: u16,
    magic: u16,
    state: u16,
    errors: u16,
    minor_rev_level: u16,
    lastcheck: u32,
    checkinterval: u32,
    creator_os: u32,
    rev_level: u32,
    def_resuid: u16,
    def_resgid: u16,
    first_ino: u32,
    inode_size: u16,
    block_group_nr: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    uuid: [16]u8,
    volume_name: [16]u8,
};

const Ext2GroupDesc = extern struct {
    bg_block_bitmap: u32,
    bg_inode_bitmap: u32,
    bg_inode_table: u32,
    bg_free_blocks_count: u16,
    bg_free_inodes_count: u16,
    bg_used_dirs_count: u16,
};

const EXT2_INODE_DIRECT = 12;

const Ext2Inode = extern struct {
    mode: u16,
    uid: u16,
    size: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid: u16,
    links_count: u16,
    blocks: u32,
    flags: u32,
    osd1: u32,
    block: [15]u32,
    generation: u32,
    file_acl: u32,
    dir_acl: u32,
    faddr: u32,
    osd2: [12]u8,
};

const Ext2DirEntry = extern struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
};

// ─── Driver state ─────────────────────────────────────────────────────────

var active: bool = false;

var sb: Ext2Superblock = undefined;
var block_size: u32 = 0;
var groups_count: u32 = 0;
var inodes_per_group: u32 = 0;
var inode_size: u32 = 0;
var first_data_block: u32 = 0;

const DISK_LBA_OFFSET: u64 = 32768;

var group_descs_phys: u64 = 0;
var group_descs_virt: u64 = 0;

var sector_buf_phys: u64 = 0;
var sector_buf_virt: u64 = 0;

pub const Ext2File = struct {
    inode_num: u32,
    inode: Ext2Inode,
    offset: u32,
};

var open_files: [MAX_OPEN_FILES]Ext2File = undefined;
var open_count: u32 = 0;

// ─── Initialization ───────────────────────────────────────────────────────

pub fn init() void {
    sector_buf_phys = pmm.allocPage() orelse return;
    sector_buf_virt = hhdm.physToVirt(sector_buf_phys);

    // Read superblock (at byte offset 1024 = sector 2)
    const sb_sector: u64 = 1024 / SECTOR_SIZE;
    if (!readSectors(sb_sector, 2)) return;

    const sb_ptr: [*]const u8 = @ptrFromInt(sector_buf_virt);
    @memcpy(@as([*]u8, @ptrCast(&sb))[0..@sizeOf(Ext2Superblock)], sb_ptr[0..@sizeOf(Ext2Superblock)]);

    if (sb.magic != 0xEF53) {
        serial.writeString("[ext2] bad magic\n");
        return;
    }

    block_size = @as(u32, 1024) << @intCast(sb.log_block_size);
    groups_count = (sb.blocks_count + sb.blocks_per_group - 1) / sb.blocks_per_group;
    inodes_per_group = sb.inodes_per_group;
    inode_size = if (sb.rev_level >= 1) sb.inode_size else 128;
    if (inode_size == 0) inode_size = 128;
    first_data_block = sb.first_data_block;

    // Read block group descriptor table (at block first_data_block + 1)
    const bgdt_block = first_data_block + 1;
    const bgdt_size = groups_count * @sizeOf(Ext2GroupDesc);
    const bgdt_blocks = (bgdt_size + block_size - 1) / block_size;
    const bgdt_sectors = bgdt_blocks * (block_size / SECTOR_SIZE);
    const bgdt_sector = bgdt_block * (block_size / SECTOR_SIZE);

    group_descs_phys = pmm.allocPage() orelse return;
    group_descs_virt = hhdm.physToVirt(group_descs_phys);

    const gd_buf: [*]u8 = @ptrFromInt(group_descs_virt);
    if (!readSectorsToBuf(bgdt_sector, bgdt_sectors, gd_buf)) return;

    active = true;

    serial.writeString("[ext2] mounted\n");
}

pub fn isActive() bool {
    return active;
}

// ─── Sector I/O ───────────────────────────────────────────────────────────

fn readSectors(lba: u64, count: u32) bool {
    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    const n = virtio_blk.readSectors(DISK_LBA_OFFSET + lba, count, buf);
    return n > 0;
}

fn readSectorsToBuf(lba: u64, count: u32, dest: [*]u8) bool {
    const n = virtio_blk.readSectors(DISK_LBA_OFFSET + lba, count, dest);
    return n > 0;
}

// ─── Block I/O ─────────────────────────────────────────────────────────────

fn readBlock(block_num: u32, buf: [*]u8) bool {
    const lba = @as(u64, block_num) * (block_size / SECTOR_SIZE);
    return readSectorsToBuf(lba, block_size / SECTOR_SIZE, buf);
}

// ─── Inode operations ─────────────────────────────────────────────────────

fn readInode(inode_num: u32, out: *Ext2Inode) bool {
    const group = (inode_num - 1) / inodes_per_group;
    const index = (inode_num - 1) % inodes_per_group;

    const gds: [*]const Ext2GroupDesc = @ptrFromInt(group_descs_virt);
    const gd = gds[group];

    const inode_table_block = gd.bg_inode_table;
    const byte_offset = index * inode_size;
    const block_offset = byte_offset / block_size;
    const offset_in_block = byte_offset % block_size;

    const target_block = inode_table_block + block_offset;

    const buf: [*]u8 = @ptrFromInt(sector_buf_virt);
    if (!readBlock(target_block, buf)) return false;

    if (offset_in_block + inode_size > block_size) {
        // Inode spans two blocks — read second block too
        const buf2_phys = pmm.allocPage() orelse return false;
        defer pmm.freePage(buf2_phys);
        const buf2: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf2_phys));
        if (!readBlock(target_block + 1, buf2)) return false;

        const first_part = block_size - offset_in_block;
        var inode_buf: [256]u8 = undefined;
        @memcpy(inode_buf[0..first_part], buf[offset_in_block .. offset_in_block + first_part]);
        @memcpy(inode_buf[first_part .. first_part + inode_size - first_part], buf2[0 .. inode_size - first_part]);
        @memcpy(@as([*]u8, @ptrCast(out))[0..inode_size], inode_buf[0..inode_size]);
    } else {
        @memcpy(@as([*]u8, @ptrCast(out))[0..inode_size], buf[offset_in_block .. offset_in_block + inode_size]);
    }
    return true;
}

// ─── Directory operations ─────────────────────────────────────────────────

pub fn openFile(name: []const u8) i64 {
    if (!active) return -1;

    // Start from root inode (2)
    return walkPath(2, name);
}

fn walkPath(start_inode: u32, path: []const u8) i64 {
    var current_inode = start_inode;
    var pos: u32 = 0;

    while (pos < path.len) {
        // Skip leading slashes
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos >= path.len) break;

        // Find end of component
        const start = pos;
        while (pos < path.len and path[pos] != '/') pos += 1;
        const component = path[start..pos];

        // Read inode
        var inode: Ext2Inode = undefined;
        if (!readInode(current_inode, &inode)) return -1;

        // Must be a directory
        if (inode.mode & 0xF000 != 0x4000) return -1;

        // Search directory entries for component
        const found = findDirEntry(&inode, component) orelse return -1;
        current_inode = found;
    }

    // Open the file
    if (current_inode == start_inode) return -1; // path was just "/"

    var inode: Ext2Inode = undefined;
    if (!readInode(current_inode, &inode)) return -1;

    // Allocate slot
    for (0..MAX_OPEN_FILES) |i| {
        if (i >= open_count or open_files[i].inode_num == 0) {
            open_files[i] = .{
                .inode_num = current_inode,
                .inode = inode,
                .offset = 0,
            };
            if (i >= open_count) open_count = @intCast(i + 1);
            return @intCast(i);
        }
    }
    return -1;
}

fn findDirEntry(inode: *const Ext2Inode, name: []const u8) ?u32 {
    const dir_size = inode.size;
    var offset: u32 = 0;

    const buf_phys = pmm.allocPage() orelse return null;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    while (offset < dir_size) {
        const block_num = offset / block_size;
        const block_offset = offset % block_size;

        if (!readBlock(resolveBlock(inode, block_num), buf)) return null;

        var pos = block_offset;
        while (pos < block_size and offset + pos - block_offset < dir_size) {
            const entry: *const Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len == name.len) {
                const entry_name = buf[pos + @sizeOf(Ext2DirEntry) .. pos + @sizeOf(Ext2DirEntry) + name.len];
                var match = true;
                for (name, 0..) |c, j| {
                    if (entry_name[j] != c) { match = false; break; }
                }
                if (match) return entry.inode;
            }

            pos += entry.rec_len;
        }
        offset += block_size;
    }
    return null;
}

// ─── Block resolution (direct + single indirect) ──────────────────────────

fn resolveBlock(inode: *const Ext2Inode, logical_block: u32) u32 {
    if (logical_block < EXT2_INODE_DIRECT) {
        return inode.block[logical_block];
    }

    // Single indirect (block[12])
    const indirect_base = EXT2_INODE_DIRECT;
    const ptrs_per_block = block_size / 4;

    if (logical_block < indirect_base + ptrs_per_block) {
        const indirect_block = inode.block[12];
        if (indirect_block == 0) return 0;

        const buf_phys = pmm.allocPage() orelse return 0;
        defer pmm.freePage(buf_phys);
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
        if (!readBlock(indirect_block, buf)) return 0;

        const index = logical_block - indirect_base;
        const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
        return ptrs[index];
    }

    // Double indirect (block[13])
    const dbl_base = indirect_base + ptrs_per_block;
    if (logical_block < dbl_base + ptrs_per_block * ptrs_per_block) {
        const dbl_block = inode.block[13];
        if (dbl_block == 0) return 0;

        const buf_phys = pmm.allocPage() orelse return 0;
        const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

        const rel = logical_block - dbl_base;
        const idx1 = rel / ptrs_per_block;
        const idx2 = rel % ptrs_per_block;

        if (!readBlock(dbl_block, buf)) { pmm.freePage(buf_phys); return 0; }
        const ptrs: [*]const u32 = @ptrCast(@alignCast(buf));
        const single_indirect = ptrs[idx1];
        if (single_indirect == 0) { pmm.freePage(buf_phys); return 0; }

        const buf2_phys = pmm.allocPage() orelse { pmm.freePage(buf_phys); return 0; };
        const buf2: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf2_phys));
        if (!readBlock(single_indirect, buf2)) { pmm.freePage(buf2_phys); pmm.freePage(buf_phys); return 0; }
        const ptrs2: [*]const u32 = @ptrCast(@alignCast(buf2));
        const result = ptrs2[idx2];
        pmm.freePage(buf2_phys);
        pmm.freePage(buf_phys);
        return result;
    }

    return 0;
}

// ─── File read ─────────────────────────────────────────────────────────────

pub fn readFile(file_idx: u32, offset: u32, buf: [*]u8, count: u32) i64 {
    if (file_idx >= open_count) return -1;
    const f = &open_files[file_idx];
    if (f.inode_num == 0) return -1;

    const file_size = f.inode.size;
    if (offset >= file_size) return 0;

    const remaining = file_size - offset;
    const to_read = if (count > remaining) remaining else count;
    if (to_read == 0) return 0;

    var read_total: u32 = 0;
    var current_offset = offset;
    const tmp_phys = pmm.allocPage() orelse return -1;
    defer pmm.freePage(tmp_phys);
    const tmp: [*]u8 = @ptrFromInt(hhdm.physToVirt(tmp_phys));

    while (read_total < to_read) {
        const logical_block = current_offset / block_size;
        const block_offset = current_offset % block_size;
        const chunk = @min(to_read - read_total, block_size - block_offset);

        const phys_block = resolveBlock(&f.inode, logical_block);
        if (phys_block == 0) break;

        if (!readBlock(phys_block, tmp)) break;

        @memcpy(buf[read_total .. read_total + chunk], tmp[block_offset .. block_offset + chunk]);
        read_total += chunk;
        current_offset += chunk;
    }

    return if (read_total == 0) -1 else @intCast(read_total);
}

pub fn getFileSize(file_idx: u32) u64 {
    if (file_idx >= open_count) return 0;
    return open_files[file_idx].inode.size;
}

pub fn closeFile(file_idx: u32) void {
    if (file_idx >= open_count) return;
    open_files[file_idx].inode_num = 0;
}

// ─── Directory listing ─────────────────────────────────────────────────────

pub fn listDir(path: []const u8, callback: *const fn ([*]const u8, u32) void) void {
    if (!active) return;

    const inode_num = if (path.len == 0 or (path.len == 1 and path[0] == '/'))
        @as(u32, 2)
    else
        blk: {
            const r = walkPath(2, path);
            break :blk if (r >= 0) open_files[@intCast(r)].inode_num else {
                if (r >= 0) closeFile(@intCast(r));
                return;
            };
        };

    var inode: Ext2Inode = undefined;
    if (!readInode(inode_num, &inode)) return;
    if (inode.mode & 0xF000 != 0x4000) return;

    const dir_size = inode.size;
    var offset: u32 = 0;

    const buf_phys = pmm.allocPage() orelse return;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));

    while (offset < dir_size) {
        const block_num = offset / block_size;

        if (!readBlock(resolveBlock(&inode, block_num), buf)) break;

        var pos: u32 = 0;
        while (pos < block_size) {
            const entry: *const Ext2DirEntry = @ptrCast(@alignCast(buf + pos));
            if (entry.rec_len == 0) break;

            if (entry.inode != 0 and entry.name_len > 0) {
                const name_ptr = buf + pos + @sizeOf(Ext2DirEntry);
                callback(name_ptr, entry.name_len);
            }

            pos += entry.rec_len;
            if (pos >= block_size) break;
        }
        offset += block_size;
    }
}

pub fn getFileName(file_idx: u32) ?[]const u8 {
    _ = file_idx;
    return null; // ext2 doesn't store name in inode
}
