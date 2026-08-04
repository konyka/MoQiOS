/// devfs — registration table backing /dev device nodes.
///
/// Pure core: no kernel imports, so lookup/enumerate (and the trivial
/// null/zero/full node ops) are host-tested via tests/main.zig (wired
/// through kernel/host_test.zig). The built-in node implementations that
/// touch kernel subsystems (random, kmsg, pci, tty) live in
/// devfs_nodes.zig and register themselves at kernel init.
///
/// Contract:
///   - The table is append-only. Nodes are registered once during kernel
///     init, BEFORE any user task can open /dev; after that the table is
///     read-only and needs no lock. `register` itself is single-threaded
///     init-time API — callers must not register concurrently with opens.
///   - Slot indices are dense (0..nodeCount()-1) and stable forever, so a
///     FileDescriptor can cache the index and getdents can use it directly
///     as the directory cursor.
///   - Ops run in the caller's syscall context (the opening/reading task),
///     with no devfs-internal lock held. They may block (kmsg's read does)
///     and may use interrupt-safe subsystem locks, but must never assume
///     IRQ context. `open`/`poll` must not block.
///
/// Ops signatures:
///   open:  fn () i64 — 0 on success, negative errno to fail the open
///          (e.g. /dev/pci's CAP_SYS_RAWIO check). null = always allowed.
///   read:  fn (ctx: *IoCtx, buf: [*]u8, count: usize) i64 — bytes read,
///          0 on EOF, negative errno. May advance ctx.offset (the vfs
///          writes it back to the descriptor on success).
///   write: fn (ctx: *IoCtx, buf: [*]const u8, count: usize) i64 — bytes
///          written or negative errno. null = writes fail.
///   poll:  fn (ctx: *const IoCtx) u32 — ready-event mask (POLL_IN |
///          POLL_OUT, values match epoll's EPOLLIN/EPOLLOUT). null = the
///          node never reports ready.
pub const MAX_NODES: u32 = 32;
pub const MAX_NAME_LEN: u32 = 24;

/// devfs_idx sentinel in vfs.FileDescriptor marking the /dev directory
/// itself (opened for getdents), as opposed to a registered node.
pub const DIR_IDX: u32 = 0xFFFF_FFFF;

/// Poll event bits — deliberately identical to epoll.zig's
/// EPOLLIN/EPOLLOUT so epoll can OR op results straight into revents.
pub const POLL_IN: u32 = 0x001;
pub const POLL_OUT: u32 = 0x004;

/// Per-call context handed to node ops. Mirrors the slice of
/// vfs.FileDescriptor state an op may legitimately touch, without
/// devfs depending on the vfs type (which would drag the arch closure
/// into host tests).
pub const IoCtx = struct {
    /// Absolute cursor (kmsg ring position, pci snapshot offset, ...).
    /// The vfs seeds it from desc.offset and writes it back on success;
    /// pread seeds it from the explicit offset and discards it.
    offset: u64 = 0,
    /// Open-time status flags (0x800 = O_NONBLOCK) copied from the fd.
    status_flags: u32 = 0,

    pub fn nonBlocking(self: *const IoCtx) bool {
        return (self.status_flags & 0x800) != 0;
    }
};

pub const Flags = packed struct {
    /// pread/pwrite with an explicit offset is meaningless for this node
    /// (pure streams like /dev/urandom) — the vfs answers -ESPIPE.
    no_pread: bool = false,
};

pub const NodeOps = struct {
    open: ?*const fn () i64 = null,
    read: ?*const fn (ctx: *IoCtx, buf: [*]u8, count: usize) i64 = null,
    write: ?*const fn (ctx: *IoCtx, buf: [*]const u8, count: usize) i64 = null,
    poll: ?*const fn (ctx: *const IoCtx) u32 = null,
    flags: Flags = .{},
};

const Entry = struct {
    used: bool = false,
    name_len: u8 = 0,
    name: [MAX_NAME_LEN]u8 = @splat(0),
    ops: NodeOps = .{},
};

var entries: [MAX_NODES]Entry = @splat(.{});
var count: u32 = 0;

fn nameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    for (name) |c| {
        if (c == '/' or c == 0) return false;
    }
    return true;
}

/// Register a device node. Returns the stable slot index, or null when
/// the name is invalid, already registered, or the table is full.
/// Init-time only (see the contract in the file header).
pub fn register(name: []const u8, ops: NodeOps) ?u32 {
    if (!nameValid(name)) return null;
    if (lookup(name) != null) return null;
    if (count >= MAX_NODES) return null;
    const idx = count;
    entries[idx] = .{
        .used = true,
        .name_len = @intCast(name.len),
        .ops = ops,
    };
    @memcpy(entries[idx].name[0..name.len], name);
    count += 1;
    return idx;
}

/// Look up a node by bare device name (no "/dev/" prefix).
pub fn lookup(name: []const u8) ?u32 {
    if (!nameValid(name)) return null;
    for (0..count) |i| {
        const e = &entries[i];
        if (e.name_len == name.len and
            stdEql(e.name[0..e.name_len], name))
        {
            return @intCast(i);
        }
    }
    return null;
}

/// Number of registered nodes; also the getdents enumeration bound.
pub fn nodeCount() u32 {
    return count;
}

/// Name of the node at slot `idx` (idx < nodeCount()), for getdents.
pub fn nameAt(idx: u32) ?[]const u8 {
    if (idx >= count) return null;
    return entries[idx].name[0..entries[idx].name_len];
}

/// Ops of the node at slot `idx`.
pub fn opsAt(idx: u32) ?*const NodeOps {
    if (idx >= count) return null;
    return &entries[idx].ops;
}

/// Test-only reset — host tests re-register from a clean table. Never
/// call after kernel init (open fds cache slot indices).
pub fn resetForTest() void {
    entries = @splat(.{});
    count = 0;
}

// Tiny local eql so this file stays import-free (host-testable).
fn stdEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Trivial self-contained nodes: null / zero / full. Pure logic, so they
// live here (host-tested) instead of devfs_nodes.zig.
// ---------------------------------------------------------------------------

fn nullRead(ctx: *IoCtx, buf: [*]u8, cnt: usize) i64 {
    _ = ctx;
    _ = buf;
    _ = cnt;
    return 0; // always EOF
}

fn nullWrite(ctx: *IoCtx, buf: [*]const u8, cnt: usize) i64 {
    _ = ctx;
    _ = buf;
    return @intCast(cnt); // discard everything, report success
}

fn zeroRead(ctx: *IoCtx, buf: [*]u8, cnt: usize) i64 {
    _ = ctx;
    @memset(buf[0..cnt], 0);
    return @intCast(cnt);
}

fn fullWrite(ctx: *IoCtx, buf: [*]const u8, cnt: usize) i64 {
    _ = ctx;
    _ = buf;
    if (cnt == 0) return 0;
    return -28; // ENOSPC
}

fn pollReadWrite(ctx: *const IoCtx) u32 {
    _ = ctx;
    return POLL_IN | POLL_OUT;
}

pub const null_node_ops: NodeOps = .{
    .read = nullRead,
    .write = nullWrite,
    .poll = pollReadWrite,
};

pub const zero_node_ops: NodeOps = .{
    .read = zeroRead,
    .write = nullWrite,
    .poll = pollReadWrite,
};

pub const full_node_ops: NodeOps = .{
    .read = nullRead,
    .write = fullWrite,
    .poll = pollReadWrite,
};
