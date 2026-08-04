/// devfs — registration table backing /dev device nodes.
///
/// Pure core: no kernel imports, so lookup/enumerate (and the trivial
/// null/zero/full node ops) are host-tested via tests/main.zig (wired
/// through kernel/host_test.zig). The built-in node implementations that
/// touch kernel subsystems (random, kmsg, pci, tty) live in
/// devfs_nodes.zig and register themselves at kernel init.
///
/// Contract:
///   - The table is append-only. Built-in nodes are registered once during
///     kernel init, BEFORE any user task can open /dev; userspace-owned
///     nodes (devfs_proxy) register later from syscall context under the
///     proxy's own alloc lock. The table itself stays lock-free: register
///     publishes the entry before bumping the count, and readers tolerate
///     a node appearing mid-scan.
///   - unregister() tombstones a slot (owner death of a userspace node):
///     lookup/nameAt skip it, getdents skips it, new opens of the name get
///     ENOENT, and the name can be registered again. The ops stay callable
///     through opsAt so fds that already cached the slot index fail cleanly
///     inside the op (-EIO from the proxy) instead of dereferencing a stale
///     entry.
///   - Tombstoned slots ARE reusable (v1.1): register() prefers the oldest
///     tombstone (lowest index) over appending, so the table cannot be
///     exhausted by repeated register/unregister cycles. A cached
///     devfs_idx can therefore retarget a newer node — this is guarded by
///     the per-slot generation: every registration bumps
///     entries[idx].generation, the vfs caches it in the FileDescriptor at
///     open, and the proxy op rejects a mismatched generation with -EIO.
///     While a slot is tombstoned its generation is unchanged, so the
///     original "stale fd fails cleanly" contract still holds until reuse.
///   - Slot indices stay dense (0..nodeCount()-1) across reuse, so a
///     FileDescriptor can cache the index and getdents can use it directly
///     as the directory cursor; the generation (not the index) identifies
///     which registration an fd belongs to.
///   - changeCounter() counts register+unregister events (monotonic u64)
///     and backs /dev/devfs-watch; change_hook (installed by devfs_nodes)
///     fires after each bump to wake watchers.
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
    /// devfs slot generation captured at open (devfs.generationAt). Proxy
    /// ops reject a mismatch with -EIO: after a tombstone+reuse cycle the
    /// fd's slot may point at a newer node, and the generation is what
    /// keeps stale fds failing cleanly instead of retargeting it.
    generation: u32 = 0,

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
    /// Bumped on every registration of this slot (1 for the first). The
    /// vfs caches it in FileDescriptor.devfs_generation at open; after a
    /// tombstone+reuse cycle a stale fd's generation no longer matches and
    /// the (proxy) op fails with -EIO instead of retargeting the new node.
    generation: u32 = 0,
};

var entries: [MAX_NODES]Entry = @splat(.{});
var count: u32 = 0;

/// Monotonic register/unregister event counter backing /dev/devfs-watch.
var change_counter: u64 = 0;
/// Installed by devfs_nodes.init(); fired after every counter bump to wake
/// blocked /dev/devfs-watch readers. Null in host tests unless a test sets
/// it. Runs in the registrant's context with no devfs lock held.
pub var change_hook: ?*const fn () void = null;

fn bumpChange() void {
    _ = @atomicRmw(u64, &change_counter, .Add, 1, .seq_cst);
    if (change_hook) |h| h();
}

/// Number of register+unregister events so far (the devfs-watch cursor
/// space). Seq-cst so a watcher that sees the bump also sees the entry.
pub fn changeCounter() u64 {
    return @atomicLoad(u64, &change_counter, .seq_cst);
}

fn nameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    for (name) |c| {
        if (c == '/' or c == 0) return false;
    }
    return true;
}

/// Register a device node. Returns the stable slot index, or null when
/// the name is invalid, already registered, or the table is full.
/// Tombstoned slots are recycled oldest-first (lowest index) before the
/// table grows; every registration bumps the slot's generation.
/// Init-time only for built-ins; devfs_proxy serializes runtime
/// registrations under its own alloc lock.
pub fn register(name: []const u8, ops: NodeOps) ?u32 {
    if (!nameValid(name)) return null;
    if (lookup(name) != null) return null;
    // Prefer the oldest tombstone (lowest dead index); append only when
    // no slot has been recycled yet.
    var idx: u32 = MAX_NODES;
    for (0..count) |i| {
        if (!entries[i].used) {
            idx = @intCast(i);
            break;
        }
    }
    if (idx == MAX_NODES) {
        if (count >= MAX_NODES) return null;
        idx = count;
        count += 1;
    }
    const generation = entries[idx].generation +% 1;
    entries[idx] = .{
        .used = true,
        .name_len = @intCast(name.len),
        .ops = ops,
        .generation = generation,
    };
    @memcpy(entries[idx].name[0..name.len], name);
    // Publish the entry before the count bump makes it visible to
    // lock-free readers (getdents / lookup / open). A reused slot was
    // already covered by count, so only appends bump it.
    asm volatile ("" ::: .{ .memory = true });
    bumpChange();
    return idx;
}

/// Tombstone slot `idx` (userspace-node owner death). lookup/nameAt stop
/// resolving it; opsAt keeps returning the ops so cached fds fail cleanly
/// inside the op. Returns false for out-of-range or already-dead slots.
pub fn unregister(idx: u32) bool {
    if (idx >= count) return false;
    if (!entries[idx].used) return false;
    asm volatile ("" ::: .{ .memory = true });
    entries[idx].used = false;
    bumpChange();
    return true;
}

/// Look up a node by bare device name (no "/dev/" prefix).
pub fn lookup(name: []const u8) ?u32 {
    if (!nameValid(name)) return null;
    for (0..count) |i| {
        const e = &entries[i];
        if (!e.used) continue;
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
/// Tombstoned slots report null so enumeration skips them.
pub fn nameAt(idx: u32) ?[]const u8 {
    if (idx >= count) return null;
    if (!entries[idx].used) return null;
    return entries[idx].name[0..entries[idx].name_len];
}

/// Ops of the node at slot `idx`. Deliberately returned even for
/// tombstoned slots: a FileDescriptor caches the slot index at open, so a
/// client op racing an unregister must still reach the (proxy) op, which
/// then reports -EIO.
pub fn opsAt(idx: u32) ?*const NodeOps {
    if (idx >= count) return null;
    return &entries[idx].ops;
}

/// Current generation of slot `idx` (see Entry.generation). Returned for
/// live and tombstoned slots alike — the vfs snapshots it at open and the
/// proxy compares it per-op, so a stale fd fails with -EIO both while the
/// slot is dead and after it has been recycled for a newer node.
pub fn generationAt(idx: u32) ?u32 {
    if (idx >= count) return null;
    return entries[idx].generation;
}

/// Test-only reset — host tests re-register from a clean table. Never
/// call after kernel init (open fds cache slot indices).
pub fn resetForTest() void {
    entries = @splat(.{});
    count = 0;
    change_counter = 0;
    change_hook = null;
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
