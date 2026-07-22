//! Pure ext2 on-disk parsing + geometry / inode addressing — no I/O, no globals.
//!
//! ext2 structures are little-endian. All supported targets (x86_64 / riscv64 /
//! aarch64) are little-endian, so `@memcpy` of a byte buffer into an
//! `extern struct` reads on-disk fields directly. Keeping this logic free of
//! block-driver / allocator dependencies lets it be unit-probed on non-x86 and
//! shared unchanged by the x86 ext2 driver.

pub const EXT2_MAGIC: u16 = 0xEF53;
pub const EXT2_INODE_DIRECT: u32 = 12;
pub const S_IFMT: u16 = 0xF000;
pub const S_IFREG: u16 = 0x8000;
pub const S_IFDIR: u16 = 0x4000;
pub const S_IFLNK: u16 = 0xA000;

// ─── On-disk structures ────────────────────────────────────────────────────

pub const Ext2Superblock = extern struct {
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

pub const Ext2GroupDesc = extern struct {
    bg_block_bitmap: u32,
    bg_inode_bitmap: u32,
    bg_inode_table: u32,
    bg_free_blocks_count: u16,
    bg_free_inodes_count: u16,
    bg_used_dirs_count: u16,
};

pub const Ext2Inode = extern struct {
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

pub const Ext2DirEntry = extern struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
};

// ─── Mode predicates ───────────────────────────────────────────────────────

pub fn isDirectory(mode: u16) bool {
    return mode & S_IFMT == S_IFDIR;
}
pub fn isSymlink(mode: u16) bool {
    return mode & S_IFMT == S_IFLNK;
}
pub fn isRegular(mode: u16) bool {
    return mode & S_IFMT == S_IFREG;
}

// ─── Superblock / geometry ─────────────────────────────────────────────────

pub const Geometry = struct {
    block_size: u32,
    groups_count: u32,
    inodes_per_group: u32,
    inode_size: u32,
    first_data_block: u32,
};

/// Parse a superblock from the leading bytes of the 1024-byte SB region.
/// Returns null if the magic is wrong.
pub fn parseSuperblock(buf: [*]const u8) ?Ext2Superblock {
    var sb: Ext2Superblock = undefined;
    @memcpy(@as([*]u8, @ptrCast(&sb))[0..@sizeOf(Ext2Superblock)], buf[0..@sizeOf(Ext2Superblock)]);
    if (sb.magic != EXT2_MAGIC) return null;
    return sb;
}

/// Derive runtime geometry from a validated superblock. Returns null on
/// impossible geometry (zero group size / unsupported block size).
pub fn deriveGeometry(sb: *const Ext2Superblock) ?Geometry {
    if (sb.magic != EXT2_MAGIC) return null;
    if (sb.blocks_per_group == 0 or sb.inodes_per_group == 0) return null;
    if (sb.log_block_size > 2) return null; // 1024 << n, n>2 → >4KiB
    const block_size: u32 = @as(u32, 1024) << @intCast(sb.log_block_size);
    var inode_sz: u32 = if (sb.rev_level >= 1) sb.inode_size else 128;
    if (inode_sz == 0) inode_sz = 128;
    const groups_count = (sb.blocks_count + sb.blocks_per_group - 1) / sb.blocks_per_group;
    if (groups_count == 0) return null;
    return .{
        .block_size = block_size,
        .groups_count = groups_count,
        .inodes_per_group = sb.inodes_per_group,
        .inode_size = inode_sz,
        .first_data_block = sb.first_data_block,
    };
}

/// Block-group descriptor table starts at `first_data_block + 1`.
pub fn bgdtBlock(first_data_block: u32) u32 {
    return first_data_block + 1;
}

pub fn ptrsPerBlock(block_size: u32) u32 {
    return block_size / 4;
}

// ─── Inode table addressing ────────────────────────────────────────────────

pub const InodeLoc = struct {
    group: u32,
    index: u32,
    byte_offset: u32,
    block_offset: u32,
    offset_in_block: u32,
    target_block: u32,
    /// Bytes to copy into the in-memory base inode (clamped to struct size).
    copy_len: u32,
};

/// Locate inode `inode_num` (1-based) inside its group's inode table.
pub fn inodeLocation(
    inode_num: u32,
    inodes_per_group: u32,
    inode_size: u32,
    block_size: u32,
    bg_inode_table: u32,
) InodeLoc {
    const group = (inode_num - 1) / inodes_per_group;
    const index = (inode_num - 1) % inodes_per_group;
    const byte_offset = index * inode_size;
    const block_offset = byte_offset / block_size;
    const offset_in_block = byte_offset % block_size;
    return .{
        .group = group,
        .index = index,
        .byte_offset = byte_offset,
        .block_offset = block_offset,
        .offset_in_block = offset_in_block,
        .target_block = bg_inode_table + block_offset,
        .copy_len = @min(inode_size, @as(u32, @sizeOf(Ext2Inode))),
    };
}

// ─── Logical block classification ──────────────────────────────────────────

pub const BlockAddr = union(enum) {
    direct: u32,
    single: u32,
    double: struct { idx1: u32, idx2: u32 },
    triple: struct { idx1: u32, idx2: u32, idx3: u32 },
    out_of_range,
};

/// Inode `i_block[]` slot holding the root of an indirect tree for `addr`.
/// Direct / out-of-range return null (no indirect root).
pub fn indirectRootSlot(addr: BlockAddr) ?u32 {
    return switch (addr) {
        .direct, .out_of_range => null,
        .single => 12,
        .double => 13,
        .triple => 14,
    };
}

/// Classify a file-relative logical block into the inode block-map path.
pub fn classifyLogicalBlock(logical_block: u32, ptrs_per_block: u32) BlockAddr {
    if (logical_block < EXT2_INODE_DIRECT) return .{ .direct = logical_block };

    const indirect_base = EXT2_INODE_DIRECT;
    if (logical_block < indirect_base + ptrs_per_block) {
        return .{ .single = logical_block - indirect_base };
    }

    const dbl_base = indirect_base + ptrs_per_block;
    const dbl_span = ptrs_per_block * ptrs_per_block;
    if (logical_block < dbl_base + dbl_span) {
        const rel = logical_block - dbl_base;
        return .{ .double = .{
            .idx1 = rel / ptrs_per_block,
            .idx2 = rel % ptrs_per_block,
        } };
    }

    const tri_base = dbl_base + dbl_span;
    const tri_span = dbl_span * ptrs_per_block;
    if (logical_block < tri_base + tri_span) {
        const rel = logical_block - tri_base;
        const idx1 = rel / dbl_span;
        const rem1 = rel % dbl_span;
        return .{ .triple = .{
            .idx1 = idx1,
            .idx2 = rem1 / ptrs_per_block,
            .idx3 = rem1 % ptrs_per_block,
        } };
    }
    return .out_of_range;
}

/// Directory entry name starts immediately after the 8-byte header.
pub fn dirEntryNameSlice(entry_bytes: [*]const u8, name_len: u8) []const u8 {
    return entry_bytes[@sizeOf(Ext2DirEntry) .. @sizeOf(Ext2DirEntry) + name_len];
}

pub fn namesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |c, i| {
        if (c != b[i]) return false;
    }
    return true;
}

// ─── Pure logical-block resolve (for probes / driver composition) ──────────

/// One in-memory pointer block used by `resolveLogicalPure`.
pub const PtrTable = struct {
    block: u32,
    ptrs: [*]const u32,
    len: u32,
};

fn lookupPtr(tables: []const PtrTable, block: u32, index: u32) u32 {
    if (block == 0) return 0;
    for (tables) |t| {
        if (t.block != block) continue;
        if (index >= t.len) return 0;
        return t.ptrs[index];
    }
    return 0;
}

/// Resolve a logical file block against `i_block[0..15]` and an explicit set of
/// pointer tables. Same addressing rules as the driver's `resolveBlock`, but
/// with no I/O — used by SK-64 probes and as the reference composition for the
/// classify → walk path.
pub fn resolveLogicalPure(
    i_block: *const [15]u32,
    logical_block: u32,
    ptrs_per_block: u32,
    tables: []const PtrTable,
) u32 {
    switch (classifyLogicalBlock(logical_block, ptrs_per_block)) {
        .direct => |i| return i_block[i],
        .single => |i| return lookupPtr(tables, i_block[12], i),
        .double => |d| {
            const si = lookupPtr(tables, i_block[13], d.idx1);
            return lookupPtr(tables, si, d.idx2);
        },
        .triple => |t| {
            const di = lookupPtr(tables, i_block[14], t.idx1);
            const si = lookupPtr(tables, di, t.idx2);
            return lookupPtr(tables, si, t.idx3);
        },
        .out_of_range => return 0,
    }
}
