/// epoll — Linux-compatible event multiplexing.
///
/// Provides epoll_create1, epoll_ctl, and epoll_wait system calls.
/// Uses a simple array-based fd management (max 128 fds per instance)
/// instead of a red-black tree, which is adequate for the typical
/// number of concurrent connections in MoQiOS.
///
/// Modes:
///   - Level Triggered (LT, default): reports events as long as the
///     condition holds; items stay on the ready list until the fd is
///     no longer ready.
///   - Edge Triggered (ET, EPOLLET): only reports on state transitions;
///     items are removed from the ready list after being returned once.
///   - One-shot (EPOLLONESHOT): disables the item after one event
///     delivery; must be re-armed with EPOLL_CTL_MOD.
///
/// Notification flow:
///   Resource state change -> epollNotify() -> scan all active epoll
///   instances for matching items -> add to ready list -> wake waiter.
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const vfs = @import("../fs/vfs.zig");
const tcp = @import("tcp.zig");
const tsc = @import("../arch/arch.zig").tsc;
const epoll_policy = @import("epoll_policy.zig");

// ---- Event type constants (Linux ABI) ----

pub const EPOLLIN: u32 = 0x001;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;
pub const EPOLLET: u32 = 0x80000000;
pub const EPOLLONESHOT: u32 = 0x40000000;

/// epoll_ctl operations (matching Linux ABI).
pub const EPOLL_CTL_ADD: i32 = 1;
pub const EPOLL_CTL_DEL: i32 = 2;
pub const EPOLL_CTL_MOD: i32 = 3;

/// Error codes (Linux-compatible negative values).
const errno = @import("../lib/errno.zig");
const EBADF = errno.EBADF;
const EEXIST = errno.EEXIST;
const EINVAL = errno.EINVAL;
const ENOENT = errno.ENOENT;
const ENOSPC = errno.ENOSPC;
const EMFILE = errno.EMFILE;
const ELOOP = errno.ELOOP;

/// Limits.
pub const MAX_EPOLL_INSTANCES: u32 = 32;
pub const MAX_EPOLL_ITEMS: u8 = 128;

// Timed epoll waits need an external wakeup: a blocked waiter cannot run
// its in-line deadline check until timerTick makes it runnable.
/// EpollEvent — matches Linux struct epoll_event (8 bytes payload).
pub const EpollEvent = extern struct {
    events: u32,
    data: u64,
};

/// WaitNode for epoll_wait blocking — stack-allocated on the
/// waiter's kernel stack, modelled after eventfd.zig.
const WaitNode = struct {
    task_idx: u32,
    generation: u64,
    granted: bool = false,
    next: ?*WaitNode = null,
};

/// EpollItem — per-fd registration within an epoll instance.
/// (fd, fd_generation) is the registration key used by epoll_ctl, as in
/// Linux's (file, fd) key. (probe_fd, probe_generation) is the live fd in
/// fd_table that readiness probes go through: it starts equal to the key and
/// is moved to a surviving duplicate when the probed fd closes while the
/// resource is still open (see invalidateFdRegistrations).
pub const EpollItem = struct {
    fd: i32 = -1,
    fd_table: ?*vfs.FdTable = null,
    fd_generation: u64 = 0,
    probe_fd: i32 = -1,
    probe_generation: u64 = 0,
    /// Open-resource identity (resourceKeyFromDesc) used to recognise a
    /// duplicate of the probed fd; null when duplicates cannot be told apart.
    resource_key: ?u64 = null,
    registration_generation: u64 = 0,
    target_epoll_generation: u64 = 0,
    events: u32 = 0,
    data: u64 = 0,
    fd_type: vfs.FdType = .none,
    resource_idx: u32 = 0,
    is_et: bool = false,
    is_oneshot: bool = false,
    is_disabled: bool = false,
    on_ready: bool = false,
    ready_next: ?u8 = null,
    last_reported: u32 = 0,
    in_use: bool = false,
};

/// EpollInstance — represents one epoll fd.
pub const EpollInstance = struct {
    items: [MAX_EPOLL_ITEMS]EpollItem = @splat(.{}),
    in_use_bm: [2]u64 = @splat(0), // Bitmap: 128 items = 2 x u64
    item_count: u8 = 0,
    ready_head: ?u8 = null,
    ready_tail: ?u8 = null,
    spin: IrqSpinlock = .{},
    waiter: ?*WaitNode = null,
    owner_task_idx: u32 = 0,
    valid: bool = false,
    /// Cross-process references (fork/clone) — epollDestroy frees at 0 only.
    ref_count: u32 = 1,
    generation: u64 = 1,
    active_ops: u32 = 0,
    closing: bool = false,
    next_registration_generation: u64 = 1,
};

pub const InstanceBorrow = struct {
    instance: *EpollInstance,
    slot: u32,
    generation: u64,
    released: bool = false,

    pub fn release(self: *InstanceBorrow) void {
        if (self.released) return;
        self.released = true;
        const saved = pool_lock.acquire();
        const inst = &epoll_pool[self.slot];
        if (inst.generation == self.generation and inst.active_ops > 0) {
            inst.active_ops -= 1;
            if (@atomicLoad(bool, &inst.closing, .acquire) and inst.active_ops == 0) {
                const next_generation = inst.generation +% 1;
                epoll_pool[self.slot] = .{ .generation = next_generation };
            }
        }
        pool_lock.release(saved);
    }
};

var wait_deadlines: [task_mod.MAX_TASKS]u64 = @splat(0);
var wait_instance_slots: [task_mod.MAX_TASKS]u32 = @splat(0);
var wait_instance_generations: [task_mod.MAX_TASKS]u64 = @splat(0);
var wait_generations: [task_mod.MAX_TASKS]u64 = @splat(0);
pub var epoll_wait_bm: u64 = 0;

// ---- Global pool ----

var epoll_pool: [MAX_EPOLL_INSTANCES]EpollInstance = @splat(.{});
/// Bitmap of valid epoll instances (1 = valid).
var valid_epoll_bm: u32 = 0;
/// Guards valid_epoll_bm and instance create/destroy. Lock order:
/// pool_lock -> inst.spin (epollNotify may run from IRQ context).
var pool_lock: IrqSpinlock = .{};

pub fn acquireInstance(idx: u32) ?InstanceBorrow {
    if (idx >= MAX_EPOLL_INSTANCES) return null;
    const saved = pool_lock.acquire();
    defer pool_lock.release(saved);
    const inst = &epoll_pool[idx];
    if (!@atomicLoad(bool, &inst.valid, .acquire) or @atomicLoad(bool, &inst.closing, .acquire)) return null;
    inst.active_ops += 1;
    return .{ .instance = inst, .slot = idx, .generation = inst.generation };
}

fn epollSlotOf(inst: *const EpollInstance) u32 {
    return @intCast((@intFromPtr(inst) - @intFromPtr(&epoll_pool[0])) / @sizeOf(EpollInstance));
}

fn instanceGenerationOf(inst: *const EpollInstance) u64 {
    return inst.generation;
}

// ---- Public API ----

/// Create a new epoll instance.
/// Returns the pool index or a negative errno on failure.
pub fn epollCreate() i32 {
    const cur_idx = sched.currentTaskIndex() orelse return @intCast(EMFILE);
    const psaved = pool_lock.acquire();
    defer pool_lock.release(psaved);
    const all_mask: u32 = if (MAX_EPOLL_INSTANCES >= 32) 0xFFFFFFFF else (@as(u32, 1) << MAX_EPOLL_INSTANCES) - 1;
    var free_mask = ~valid_epoll_bm & all_mask;
    var selected: ?u5 = null;
    while (free_mask != 0) {
        const candidate: u5 = @intCast(@ctz(free_mask));
        free_mask &= free_mask - 1;
        if (!@atomicLoad(bool, &epoll_pool[candidate].closing, .acquire)) {
            selected = candidate;
            break;
        }
    }
    const i = selected orelse return @intCast(EMFILE);
    const generation = epoll_pool[i].generation;
    valid_epoll_bm |= @as(u32, 1) << i;
    epoll_pool[i] = .{
        .owner_task_idx = cur_idx,
        .valid = true,
        .generation = generation,
    };
    return @intCast(i);
}

/// Control an epoll instance — add, modify, or delete an fd registration.
pub fn epollCtl(epfd_idx: u32, op: i32, fd: i32, event_ptr: u64) i64 {
    var borrow = acquireInstance(epfd_idx) orelse return EBADF;
    defer borrow.release();
    const inst = borrow.instance;
    if (fd < 0) return EBADF;

    const cur_idx = sched.currentTaskIndex() orelse return EBADF;
    const cur = task_mod.getTask(cur_idx) orelse return EBADF;
    if (fd >= @as(i32, @intCast(vfs.MAX_FDS))) return EBADF;
    if (!cur.fd_table.acquireTransferFd(@intCast(fd))) return EBADF;
    defer cur.fd_table.releaseTransferFd(@intCast(fd));
    const identity = cur.fd_table.snapshotFdIdentity(@intCast(fd)) orelse return EBADF;
    const desc = &identity.desc;
    var target_epoll_generation: u64 = 0;
    if (desc.fd_type == .epoll) {
        if (resourceIdxFromDesc(desc) == epfd_idx) return ELOOP;
        const target = acquireInstance(resourceIdxFromDesc(desc)) orelse return EBADF;
        target_epoll_generation = target.generation;
        // Linux rejects a registration that would create a cycle. Beyond the
        // self-loop above, an indirect cycle (epfd → target → … → epfd)
        // circulates readiness between members: every collect re-probes a
        // permanently non-empty child ready list, so epoll_wait returns
        // immediately forever and real EAGAIN can never surface.
        if (nestedChainReaches(target.instance, epfd_idx)) {
            var cycle_borrow = target;
            cycle_borrow.release();
            return ELOOP;
        }
        var target_borrow = target;
        target_borrow.release();
    }
    var needs_readiness_recheck = false;
    defer if (needs_readiness_recheck) {
        const current = computeCurrentEvents(desc.fd_type, resourceIdxFromDesc(desc), desc.offset);
        if (current != 0) epollNotify(desc.fd_type, resourceIdxFromDesc(desc), current);
    };

    const saved = inst.spin.acquire();
    defer inst.spin.release(saved);

    switch (op) {
        EPOLL_CTL_ADD => {
            // Check for duplicate fd via bitmap iteration
            for (0..2) |w| {
                var bits = inst.in_use_bm[w];
                while (bits != 0) {
                    const bit = @ctz(bits);
                    bits &= bits - 1;
                    const i: u8 = @intCast(w * 64 + @as(u32, bit));
                    if (inst.items[i].fd == fd and inst.items[i].fd_generation == identity.generation) return EEXIST;
                }
            }
            var slot: ?u8 = null;
            // Find free slot via inverted in_use bitmap
            for (0..2) |w| {
                const inv = ~inst.in_use_bm[w];
                if (inv == 0) continue;
                const bit = @ctz(inv);
                const idx: u8 = @intCast(w * 64 + @as(u32, bit));
                if (idx >= MAX_EPOLL_ITEMS) break;
                slot = idx;
                break;
            }
            const s = slot orelse return ENOSPC;
            const ev = copyEventFromUser(event_ptr) orelse return EINVAL;

            inst.items[s] = .{
                .fd = fd,
                .fd_table = cur.fd_table,
                .fd_generation = identity.generation,
                .probe_fd = fd,
                .probe_generation = identity.generation,
                .resource_key = resourceKeyFromDesc(desc),
                .registration_generation = inst.next_registration_generation,
                .target_epoll_generation = target_epoll_generation,
                .events = ev.events,
                .data = ev.data,
                .fd_type = desc.fd_type,
                .resource_idx = resourceIdxFromDesc(desc),
                .is_et = (ev.events & EPOLLET) != 0,
                .is_oneshot = (ev.events & EPOLLONESHOT) != 0,
                .in_use = true,
            };
            inst.next_registration_generation +%= 1;
            inst.item_count += 1;
            inst.in_use_bm[s >> 6] |= @as(u64, 1) << @intCast(s & 63);
            needs_readiness_recheck = true;
        },
        EPOLL_CTL_MOD => {
            var found = false;
            for (0..2) |w| {
                var bits = inst.in_use_bm[w];
                while (bits != 0) {
                    const bit = @ctz(bits);
                    bits &= bits - 1;
                    const i: u8 = @intCast(w * 64 + @as(u32, bit));
                    const item = &inst.items[i];
                    if (item.fd == fd and item.fd_generation == identity.generation and
                        item.fd_type == desc.fd_type and item.resource_idx == resourceIdxFromDesc(desc))
                    {
                        const ev = copyEventFromUser(event_ptr) orelse return EINVAL;
                        item.events = ev.events;
                        item.data = ev.data;
                        item.is_et = (ev.events & EPOLLET) != 0;
                        item.is_oneshot = (ev.events & EPOLLONESHOT) != 0;
                        item.is_disabled = false;
                        item.last_reported = 0;
                        item.registration_generation +%= 1;
                        found = true;
                        needs_readiness_recheck = true;
                        break;
                    }
                }
                if (found) break;
            }
            if (!found) return ENOENT;
        },
        EPOLL_CTL_DEL => {
            var found = false;
            for (0..2) |w| {
                var bits = inst.in_use_bm[w];
                while (bits != 0) {
                    const bit = @ctz(bits);
                    bits &= bits - 1;
                    const i: u8 = @intCast(w * 64 + @as(u32, bit));
                    if (inst.items[i].fd == fd and inst.items[i].fd_generation == identity.generation and
                        inst.items[i].fd_type == desc.fd_type and
                        inst.items[i].resource_idx == resourceIdxFromDesc(desc))
                    {
                        if (inst.items[i].on_ready) removeFromReadyListSlot(inst, i);
                        inst.items[i] = .{};
                        inst.in_use_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
                        inst.item_count -= 1;
                        found = true;
                        break;
                    }
                }
                if (found) break;
            }
            if (!found) return ENOENT;
        },
        else => return EINVAL,
    }
    return 0;
}

/// Wait for events on an epoll instance.
pub fn epollWait(epfd_idx: u32, events_buf: u64, max_events: u32, timeout_ms: i32) i64 {
    if (max_events == 0 or max_events > MAX_EPOLL_ITEMS) return EINVAL;
    var borrow = acquireInstance(epfd_idx) orelse return EBADF;
    defer borrow.release();
    const inst = borrow.instance;
    const max_out: u32 = @min(max_events, MAX_EPOLL_ITEMS);
    const copy = @import("../mm/copy_from_user.zig");
    if (!copy.validateUserBufferWritable(events_buf, @as(usize, max_out) * @sizeOf(EpollEvent))) return -14; // EFAULT
    const cur_idx = sched.currentTaskIndex() orelse return EBADF;
    const cur = task_mod.getTask(cur_idx) orelse return EBADF;

    const deadline_ns = epoll_policy.timeoutDeadlineNs(tsc.nanos(), timeout_ms);

    while (true) {
        // Woken by epollDestroy: the instance is gone, report EBADF.
        if (!@atomicLoad(bool, &inst.valid, .acquire)) return EBADF;
        var out_events: [MAX_EPOLL_ITEMS]EpollEvent = undefined;
        const n = collectEvents(inst, cur.fd_table, &out_events, max_out);
        if (n > 0) {
            const bytes: usize = @as(usize, n) * @sizeOf(EpollEvent);
            if (copy.copyToUser(@ptrFromInt(events_buf), @ptrCast(&out_events), bytes) != bytes) return -14; // EFAULT
            return @intCast(n);
        }
        if (timeout_ms == 0) return 0;
        if (deadline_ns) |d| {
            if (tsc.nanos() >= d) return 0;
        }
        switch (blockOnEpoll(inst, deadline_ns)) {
            .event => {},
            .timeout => return 0,
            .interrupted => return -4, // EINTR — a signal kicked us out of the wait
        }
    }
}

/// Notification callback — called by TCP, pipe, etc. when state changes.
pub fn epollNotify(fd_type: vfs.FdType, resource_idx: u32, ready_events: u32) void {
    // Hold pool_lock for the whole sweep: create/destroy mutate valid_epoll_bm
    // and instance storage, and may run concurrently on another CPU.
    const psaved = pool_lock.acquire();
    defer pool_lock.release(psaved);
    var newly_ready: u32 = 0;
    var ebm = valid_epoll_bm;
    while (ebm != 0) {
        const ei = @ctz(ebm);
        ebm &= ebm - 1;
        const inst = &epoll_pool[ei];
        const saved = inst.spin.acquire();
        var instance_became_ready = false;

        for (0..2) |w| {
            var bits = inst.in_use_bm[w];
            while (bits != 0) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                const i: u8 = @intCast(w * 64 + @as(u32, bit));
                const item = &inst.items[i];
                if (item.is_disabled) continue;
                if (item.fd_type != fd_type) continue;
                if (item.resource_idx != resource_idx) continue;

                const interest = item.events & ~EPOLLET & ~EPOLLONESHOT;
                const matched = ready_events & interest;
                if (matched == 0) continue;

                if (item.is_et) {
                    if (matched == item.last_reported) continue;
                    item.last_reported = matched;
                }

                if (!item.on_ready) {
                    addToReadyListLocked(inst, i);
                    newly_ready |= @as(u32, 1) << @intCast(ei);
                    instance_became_ready = true;
                }
            }
        }

        if (instance_became_ready) wakeWaiterLocked(inst);
        inst.spin.release(saved);
    }
    propagateNestedReadyLocked(newly_ready);
}

/// A descriptor incarnation is closing. Registrations probed through it move
/// to another live fd of the same table that still refers to the same open
/// resource (a dup/dup2 copy keeps the registration alive, as Linux ties it
/// to the open file description); without such a copy they are removed.
/// The table pointer prevents an unrelated process' same-numbered fd from
/// touching a live registration in a shared epoll instance. vfs calls this
/// before tearing the resource down, so a copy found here names the same
/// live resource, never a recycled index.
/// Lock order: pool_lock -> inst.spin -> FdTable slot lock (a leaf: no
/// slot-lock holder calls into epoll).
pub fn invalidateFdRegistrations(fd_table: *vfs.FdTable, fd: u32, generation: u64) void {
    const psaved = pool_lock.acquire();
    defer pool_lock.release(psaved);
    var dup: ?SurvivingFd = null;
    var dup_looked_up = false;
    var ebm = valid_epoll_bm;
    while (ebm != 0) {
        const ei = @ctz(ebm);
        ebm &= ebm - 1;
        const inst = &epoll_pool[ei];
        const saved = inst.spin.acquire();
        for (0..2) |w| {
            var bits = inst.in_use_bm[w];
            while (bits != 0) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                const slot: u8 = @intCast(w * 64 + @as(u32, bit));
                const item = &inst.items[slot];
                if (item.in_use and item.fd_table == fd_table and item.probe_fd == @as(i32, @intCast(fd)) and
                    item.probe_generation == generation)
                {
                    // Every item probed through this incarnation names the
                    // same descriptor, so one lookup serves them all.
                    if (!dup_looked_up) {
                        dup = survivingDuplicate(fd_table, fd, item.fd_type, item.resource_key);
                        dup_looked_up = true;
                    }
                    if (dup) |copy| {
                        item.probe_fd = @intCast(copy.fd);
                        item.probe_generation = copy.generation;
                        continue;
                    }
                    if (item.on_ready) removeFromReadyListSlot(inst, slot);
                    inst.items[slot] = .{};
                    inst.in_use_bm[w] &= ~(@as(u64, 1) << @intCast(bit));
                    inst.item_count -= 1;
                }
            }
        }
        inst.spin.release(saved);
    }
}

const SurvivingFd = struct {
    fd: u32,
    generation: u64,
};

/// Another LIVE fd of `fd_table` naming the same open resource as the
/// closing `fd`. Only LIVE slots qualify: a CLOSING/CLEANING copy runs its
/// own invalidation after this one (it needs pool_lock), and while a copy
/// is LIVE its resource cannot be torn down, so the key cannot be stale.
fn survivingDuplicate(fd_table: *vfs.FdTable, fd: u32, fd_type: vfs.FdType, key: ?u64) ?SurvivingFd {
    const want = key orelse return null;
    for (0..vfs.MAX_FDS) |i| {
        if (i == fd) continue;
        const identity = fd_table.snapshotFdIdentity(@intCast(i)) orelse continue;
        if (identity.desc.fd_type != fd_type) continue;
        if (resourceKeyFromDesc(&identity.desc) != want) continue;
        return .{ .fd = @intCast(i), .generation = identity.generation };
    }
    return null;
}

/// Identity of the open resource behind a descriptor, comparable between
/// fds of the same type in one table (the fields vfs hasSharedRef and the
/// pipe ref counts use). null for types whose copies are indistinguishable.
fn resourceKeyFromDesc(desc: *const vfs.FileDescriptor) ?u64 {
    return switch (desc.fd_type) {
        .pipe_read, .pipe_write => desc.pipe_idx,
        .ext2_file => desc.ext2_file_idx,
        .fat32_file => desc.fat32_file_idx,
        .tcp_socket => desc.tcb_idx,
        .udp_socket => desc.udp_port,
        .epoll => desc.epoll_idx,
        .unix_socket => desc.unix_sock_idx,
        .timerfd => desc.timerfd_idx,
        .tmpfs_file => desc.tmpfs_idx,
        .devfs_ctrl => desc.devfs_ctrl_idx,
        .eventfd => desc.eventfd_idx,
        .ramdisk_file => desc.file_data,
        else => null,
    };
}

/// True when the child-epoll chain reachable from `start` contains
/// `epfd_idx`. Used by EPOLL_CTL_ADD on an epoll fd to reject indirect
/// registration cycles. Bounded by the visited bitmap: MAX_EPOLL_INSTANCES
/// is 32, so a u32 covers every instance.
fn nestedChainReaches(start: *EpollInstance, epfd_idx: u32) bool {
    var visited: u32 = 0;
    var pending: u32 = @as(u32, 1) << @intCast(epollSlotOf(start));
    while (pending != 0) {
        const cur_bit = @as(u32, 1) << @intCast(@ctz(pending));
        pending &= ~cur_bit;
        if ((visited & cur_bit) != 0) continue;
        visited |= cur_bit;
        const cur_idx: u32 = @ctz(cur_bit);
        if (cur_idx == epfd_idx) return true;
        var child = acquireInstance(cur_idx) orelse continue;
        const saved = child.instance.spin.acquire();
        var found: u32 = 0;
        for (0..2) |w| {
            var bits = child.instance.in_use_bm[w];
            while (bits != 0) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                const i: u8 = @intCast(w * 64 + @as(u32, bit));
                const item = &child.instance.items[i];
                if (item.fd_type == .epoll and !item.is_disabled) {
                    found |= @as(u32, 1) << @intCast(item.resource_idx);
                }
            }
        }
        child.instance.spin.release(saved);
        child.release();
        pending |= found & ~visited;
    }
    return false;
}

/// Propagate child-epoll readiness while pool_lock is already held. Keeping
/// this as an iterative walk avoids recursive pool-lock acquisition and also
/// bounds cyclic epoll graphs with the visited bitmap.
fn propagateNestedReadyLocked(initial: u32) void {    var pending = initial;
    var visited: u32 = 0;
    while (pending != 0) {
        const child = @ctz(pending);
        pending &= pending - 1;
        const child_bit = @as(u32, 1) << @intCast(child);
        if ((visited & child_bit) != 0) continue;
        visited |= child_bit;

        var ebm = valid_epoll_bm;
        while (ebm != 0) {
            const parent = @ctz(ebm);
            ebm &= ebm - 1;
            if (parent == child) continue;
            const parent_inst = &epoll_pool[parent];
            const saved = parent_inst.spin.acquire();
            var became_ready = false;
            for (0..2) |w| {
                var bits = parent_inst.in_use_bm[w];
                while (bits != 0) {
                    const bit = @ctz(bits);
                    bits &= bits - 1;
                    const item_idx: u8 = @intCast(w * 64 + @as(u32, bit));
                    const item = &parent_inst.items[item_idx];
                    if (item.is_disabled or item.fd_type != .epoll or item.resource_idx != child or
                        item.target_epoll_generation != epoll_pool[child].generation or
                        item.events & EPOLLIN == 0) continue;
                    if (item.is_et) {
                        if (item.last_reported == EPOLLIN) continue;
                        item.last_reported = EPOLLIN;
                    }
                    if (!item.on_ready) {
                        addToReadyListLocked(parent_inst, item_idx);
                        became_ready = true;
                    }
                }
            }
            if (became_ready) {
                wakeWaiterLocked(parent_inst);
                pending |= @as(u32, 1) << @intCast(parent);
            }
            parent_inst.spin.release(saved);
        }
    }
}

/// Clear edge-triggered parent state after a child epoll queue drains. This
/// arms the parent for the next child readiness transition.
fn resetNestedEdgeState(child_slot: u32, child_generation: u64) void {
    const psaved = pool_lock.acquire();
    defer pool_lock.release(psaved);
    if (child_slot >= MAX_EPOLL_INSTANCES or !@atomicLoad(bool, &epoll_pool[child_slot].valid, .acquire) or
        epoll_pool[child_slot].generation != child_generation) return;

    const child_inst = &epoll_pool[child_slot];
    const child_saved = child_inst.spin.acquire();
    const child_empty = child_inst.ready_head == null;
    child_inst.spin.release(child_saved);
    if (!child_empty) return;

    var ebm = valid_epoll_bm & ~(@as(u32, 1) << @intCast(child_slot));
    while (ebm != 0) {
        const parent = @ctz(ebm);
        ebm &= ebm - 1;
        const parent_inst = &epoll_pool[parent];
        const saved = parent_inst.spin.acquire();
        for (0..2) |w| {
            var bits = parent_inst.in_use_bm[w];
            while (bits != 0) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                const item = &parent_inst.items[@intCast(w * 64 + @as(u32, bit))];
                if (item.fd_type == .epoll and item.resource_idx == child_slot and
                    item.target_epoll_generation == child_generation and item.is_et)
                {
                    item.last_reported = 0;
                }
            }
        }
        parent_inst.spin.release(saved);
    }
}

// ---- Internal helpers ----

fn copyEventFromUser(event_ptr: u64) ?EpollEvent {
    if (event_ptr == 0 or event_ptr >= 0x0000_8000_0000_0000) return null;
    const copy = @import("../mm/copy_from_user.zig");
    var ev: EpollEvent = undefined;
    const got = copy.copyFromUser(@as([*]u8, @ptrCast(&ev))[0..@sizeOf(EpollEvent)], @ptrFromInt(event_ptr), @sizeOf(EpollEvent));
    if (got != @sizeOf(EpollEvent)) return null;
    return ev;
}

fn resourceIdxFromDesc(desc: *const vfs.FileDescriptor) u32 {
    return switch (desc.fd_type) {
        .tcp_socket => desc.tcb_idx,
        .udp_socket => desc.udp_port,
        .pipe_read => desc.pipe_idx,
        .pipe_write => desc.pipe_idx,
        .epoll => desc.epoll_idx,
        .eventfd => desc.eventfd_idx,
        .timerfd => desc.timerfd_idx,
        .unix_socket => desc.unix_sock_idx,
        .devfs => desc.devfs_idx,
        .devfs_ctrl => desc.devfs_ctrl_idx,
        else => 0,
    };
}

/// kmsg read cursor for a registered item (J3): the per-fd ring position
/// lives in the FileDescriptor (vfs.read advances desc.offset), so recover
/// it through the epoll instance owner's fd table. A closed or reused fd
/// reports the newest position (nothing unread) — the registration is
/// stale by then anyway.
fn kmsgCursorForItem(inst: *const EpollInstance, fd: i32) u64 {
    const klog = @import("../klog.zig");
    if (fd >= 0 and fd < @as(i32, @intCast(vfs.MAX_FDS))) {
        if (task_mod.getTask(inst.owner_task_idx)) |owner| {
            const desc = &owner.fd_table.fds[@as(u32, @intCast(fd))];
            if (desc.fd_type == .devfs and
                desc.devfs_idx == @import("../fs/devfs_nodes.zig").kmsgNodeIdx())
            {
                return desc.offset;
            }
        }
    }
    return klog.kmsgNewestPos();
}

fn computeCurrentEvents(fd_type: vfs.FdType, resource_idx: u32, kmsg_cursor: u64) u32 {
    var revents: u32 = 0;
    switch (fd_type) {
        .tcp_socket => {
            const tcb_idx = resource_idx;
            if (tcp.tcpIsClosing(tcb_idx)) {
                revents |= EPOLLHUP;
                if (tcp.tcpRecvAvailable(tcb_idx) > 0) revents |= EPOLLIN;
                revents |= EPOLLERR;
                return revents;
            }
            if (tcp.tcpRecvAvailable(tcb_idx) > 0) revents |= EPOLLIN;
            if (tcp.isEstablished(tcb_idx) and tcp.tcpSendSpace(tcb_idx) > 0) {
                revents |= EPOLLOUT;
            }
            revents |= EPOLLERR;
        },
        .pipe_read => {
            const state = vfs.pipeState(resource_idx) orelse return EPOLLERR;
            if (state.readable > 0) revents |= EPOLLIN;
            if (state.readable == 0 and !state.write_open) revents |= EPOLLHUP;
        },
        .pipe_write => {
            const state = vfs.pipeState(resource_idx) orelse return EPOLLERR;
            if (state.writable) revents |= EPOLLOUT;
            if (!state.read_open) revents |= EPOLLERR;
        },
        .special => {
            revents |= EPOLLIN | EPOLLOUT;
        },
        .ramdisk_file, .fat32_file, .ext2_file, .proc_file, .pidfd => {
            revents |= EPOLLIN | EPOLLOUT;
        },
        .devfs => {
            // Device node readiness comes from the node's poll op
            // (fs/devfs.zig). kmsg_cursor carries this fd's ring position
            // for /dev/kmsg; other nodes ignore it.
            const devfs = @import("../fs/devfs.zig");
            if (devfs.opsAt(resource_idx)) |ops| {
                if (ops.poll) |poll_op| {
                    const ctx: devfs.IoCtx = .{ .offset = kmsg_cursor };
                    revents |= poll_op(&ctx);
                }
            }
        },
        .epoll => {
            var borrow = acquireInstance(resource_idx) orelse return EPOLLERR;
            defer borrow.release();
            const inst = borrow.instance;
            const saved = inst.spin.acquire();
            const ready = inst.ready_head != null;
            inst.spin.release(saved);
            if (ready) revents |= EPOLLIN;
            revents |= EPOLLOUT;
        },
        .eventfd => {
            // Level-triggered: readable only while the counter is non-zero.
            const eventfd_mod = @import("../fs/eventfd.zig");
            if (eventfd_mod.eventfdGetCounter(resource_idx) > 0) revents |= EPOLLIN;
            revents |= EPOLLOUT;
        },
        .timerfd => {
            const timerfd_mod = @import("../ipc/timerfd.zig");
            if (timerfd_mod.timerfdGetExpirations(resource_idx) > 0) revents |= EPOLLIN;
            revents |= EPOLLOUT;
        },
        .unix_socket => {
            revents |= @import("unix_socket.zig").unixEpollEvents(resource_idx);
        },
        .none => {},
        .tmpfs_file => {
            revents |= EPOLLIN | EPOLLOUT;
        },
        .udp_socket => {
            // Level-triggered: readable only while a datagram is queued —
            // reporting EPOLLIN unconditionally made LT epoll busy-spin.
            // resource_idx carries the UDP port (see resourceIdxFromDesc).
            const udp_mod = @import("udp.zig");
            if (udp_mod.hasQueuedDatagram(@intCast(resource_idx))) revents |= EPOLLIN;
            revents |= EPOLLOUT; // datagram sockets are always writable
        },
        .inotify => {
            revents |= EPOLLIN | EPOLLOUT;
        },
        .raw_socket => {
            revents |= EPOLLOUT; // no per-socket RX queue to test
        },
        .devfs_ctrl => {
            // Owner end of a userspace node: readable when a request is
            // queued, always writable (responses are matched by seq).
            const dpx = @import("../fs/devfs_proxy.zig");
            if (dpx.ctrlHasQueued(resource_idx)) revents |= EPOLLIN;
            revents |= EPOLLOUT;
        },
    }
    return revents;
}

fn addToReadyList(inst: *EpollInstance, slot: u8) void {
    const saved = inst.spin.acquire();
    addToReadyListLocked(inst, slot);
    inst.spin.release(saved);
}

fn addToReadyListLocked(inst: *EpollInstance, slot: u8) void {
    if (inst.items[slot].on_ready) return;
    inst.items[slot].on_ready = true;
    inst.items[slot].ready_next = null;
    if (inst.ready_tail) |tail| {
        inst.items[tail].ready_next = slot;
    } else {
        inst.ready_head = slot;
    }
    inst.ready_tail = slot;
}

fn removeFromReadyListSlot(inst: *EpollInstance, slot: u8) void {
    var prev: ?u8 = null;
    var cur = inst.ready_head;
    while (cur) |idx| {
        const next = inst.items[idx].ready_next;
        if (idx == slot) {
            if (prev) |p| {
                inst.items[p].ready_next = next;
            } else {
                inst.ready_head = next;
            }
            if (idx == inst.ready_tail.?) {
                inst.ready_tail = if (prev) |p| p else null;
                if (inst.ready_tail == null) inst.ready_head = null;
            }
            inst.items[idx].on_ready = false;
            inst.items[idx].ready_next = null;
            return;
        }
        prev = idx;
        cur = next;
    }
}

fn collectEvents(inst: *EpollInstance, fd_table: *vfs.FdTable, out: []EpollEvent, max_out: u32) u32 {
    const saved = inst.spin.acquire();

    const ReadySnapshot = struct {
        slot: u8,
        fd: i32,
        fd_generation: u64,
        probe_fd: i32,
        probe_generation: u64,
        registration_generation: u64,
        fd_type: vfs.FdType,
        resource_idx: u32,
        target_epoll_generation: u64,
        events: u32,
        data: u64,
        is_et: bool,
        is_oneshot: bool,
        kmsg_cursor: u64,
    };
    var snapshots: [MAX_EPOLL_ITEMS]ReadySnapshot = undefined;
    var snapshot_count: usize = 0;
    const scan_head = inst.ready_head;
    const drained_ready_queue = scan_head != null;
    const drained_slot = epollSlotOf(inst);
    const drained_generation = inst.generation;
    inst.ready_head = null;
    inst.ready_tail = null;
    // First pass: only clear on_ready flag (preserve ready_next for second pass)
    var cur = scan_head;
    while (cur) |idx| {
        inst.items[idx].on_ready = false;
        cur = inst.items[idx].ready_next;
    }

    var count: u32 = 0;
    cur = scan_head;
    while (cur) |idx| {
        const next = inst.items[idx].ready_next;
        const item = &inst.items[idx];

        if (item.is_disabled) {
            cur = next;
            continue;
        }

        snapshots[snapshot_count] = .{
            .slot = idx,
            .fd = item.fd,
            .fd_generation = item.fd_generation,
            .probe_fd = item.probe_fd,
            .probe_generation = item.probe_generation,
            .registration_generation = item.registration_generation,
            .fd_type = item.fd_type,
            .resource_idx = item.resource_idx,
            .target_epoll_generation = item.target_epoll_generation,
            .events = item.events,
            .data = item.data,
            .is_et = item.is_et,
            .is_oneshot = item.is_oneshot,
            .kmsg_cursor = kmsgCursorForItem(inst, item.probe_fd),
        };
        snapshot_count += 1;
        cur = next;
    }

    inst.spin.release(saved);

    // Readiness probes may acquire another epoll instance. Do them without
    // holding the parent spinlock, preserving pool_lock -> inst.spin order.
    for (snapshots[0..snapshot_count]) |snapshot| {
        if (snapshot.probe_fd < 0 or !fd_table.acquireTransferFd(@intCast(snapshot.probe_fd))) continue;
        const target_identity = fd_table.snapshotFdIdentity(@intCast(snapshot.probe_fd));
        if (target_identity == null or target_identity.?.generation != snapshot.probe_generation or
            target_identity.?.desc.fd_type != snapshot.fd_type or
            resourceIdxFromDesc(&target_identity.?.desc) != snapshot.resource_idx)
        {
            fd_table.releaseTransferFd(@intCast(snapshot.probe_fd));
            continue;
        }
        var child_borrow: ?InstanceBorrow = null;
        if (snapshot.fd_type == .epoll) {
            child_borrow = acquireInstance(snapshot.resource_idx) orelse {
                fd_table.releaseTransferFd(@intCast(snapshot.probe_fd));
                continue;
            };
            if (child_borrow.?.generation != snapshot.target_epoll_generation) {
                child_borrow.?.release();
                fd_table.releaseTransferFd(@intCast(snapshot.probe_fd));
                continue;
            }
        }
        const current = computeCurrentEvents(snapshot.fd_type, snapshot.resource_idx, snapshot.kmsg_cursor);
        if (child_borrow) |*borrowed| borrowed.release();
        const interest = snapshot.events & ~EPOLLET & ~EPOLLONESHOT;
        const matched = current & interest;
        const always_report = current & (EPOLLERR | EPOLLHUP);
        const final_events = matched | always_report;
        if (final_events == 0) {
            fd_table.releaseTransferFd(@intCast(snapshot.probe_fd));
            continue;
        }

        const update_saved = inst.spin.acquire();
        const item = &inst.items[snapshot.slot];
        const still_registered = item.in_use and item.fd == snapshot.fd and
            item.fd_generation == snapshot.fd_generation and
            item.registration_generation == snapshot.registration_generation and
            item.fd_type == snapshot.fd_type and item.resource_idx == snapshot.resource_idx;
        if (still_registered) {
            const delivered = count < max_out;
            if (delivered) {
                out[count] = .{
                    .events = final_events,
                    .data = snapshot.data,
                };
                count += 1;
            }

            if (snapshot.is_oneshot and delivered) {
                item.is_disabled = true;
            } else if (final_events != 0 and (!snapshot.is_et or !delivered)) {
                addToReadyListLocked(inst, snapshot.slot);
            }
            if (snapshot.is_et and delivered) {
                // Delivery consumed this edge. Clearing last_reported makes
                // the NEXT identical notify a fresh edge that re-queues the
                // item; without this, an ET reader that drains and blocks
                // again is never woken by the next same-mask event (the
                // notify-side mask-equality suppression eats it).
                item.last_reported = 0;
            }
        }
        inst.spin.release(update_saved);
        fd_table.releaseTransferFd(@intCast(snapshot.probe_fd));
    }
    if (drained_ready_queue) {
        const state_saved = inst.spin.acquire();
        const queue_empty = inst.ready_head == null;
        // A concurrent epoll_wait may have installed a waiter in the window
        // between our drain (ready list emptied) and the LT/undelivered
        // re-inserts above. A non-empty ready list must wake that waiter —
        // epollNotify skips the wake when the item is already on_ready, so
        // this is the only place the wakeup can come from (Linux
        // ep_done_scan wakes when rdllist is non-empty, for the same reason).
        if (!queue_empty) wakeWaiterLocked(inst);
        inst.spin.release(state_saved);
        if (queue_empty) resetNestedEdgeState(drained_slot, drained_generation);
    }
    return count;
}

/// Result of blockOnEpoll.
const BlockOutcome = enum {
    /// Woken by a readiness notification (or events were already pending).
    event,
    /// The monotonic deadline expired (caller returns 0 to userspace).
    timeout,
    /// A pending signal kicked the task out of the wait (caller returns -EINTR).
    interrupted,
};

/// Block until an event arrives, the monotonic deadline expires, or a
/// pending signal interrupts the wait. The waiter yields the CPU right away
/// (it used to `hlt` in place until the next tick switched it out).
fn blockOnEpoll(inst: *EpollInstance, deadline_ns: ?u64) BlockOutcome {
    const my_idx = sched.currentTaskIndex() orelse {
        asm volatile ("sti; hlt");
        return .event;
    };
    const ct = task_mod.getTask(my_idx) orelse return .event;
    const sig_mod = @import("../proc/signal.zig");

    const saved = inst.spin.acquire();

    if (inst.ready_head != null) {
        inst.spin.release(saved);
        return .event;
    }

    const generation = @atomicRmw(u64, &wait_generations[my_idx], .Add, 1, .seq_cst) +% 1;
    var node = WaitNode{
        .task_idx = my_idx,
        .generation = generation,
        .granted = false,
        .next = inst.waiter,
    };
    inst.waiter = &node;

    if (deadline_ns) |d| {
        @atomicStore(u64, &wait_deadlines[my_idx], d, .seq_cst);
        @atomicStore(u32, &wait_instance_slots[my_idx], epollSlotOf(inst), .seq_cst);
        @atomicStore(u64, &wait_instance_generations[my_idx], instanceGenerationOf(inst), .seq_cst);
        _ = @atomicRmw(u64, &epoll_wait_bm, .Or, @as(u64, 1) << @intCast(my_idx), .seq_cst);
    }

    ct.state = .blocked;
    inst.spin.release(saved);

    while (true) {
        // Grants, deadline unlinks and re-blocking all happen under
        // inst.spin, so a notify racing this check is never lost. The
        // acquire also orders our .blocked store before the pending-signal
        // load, pairing with sendSignal (set pending, then kick if .blocked):
        // a signal queued before the wait is seen here, not after a timeout.
        const s2 = inst.spin.acquire();
        if (@atomicLoad(bool, &node.granted, .acquire)) {
            inst.spin.release(s2);
            disarmWaitDeadline(my_idx, generation);
            return .event;
        }
        const expired = if (deadline_ns) |d| tsc.nanos() >= d else false;
        // Signal kick: sendSignal unblocks the task without granting the
        // wait node. epollDestroy wakes waiters of a dead instance the same way.
        const actionable = sig_mod.pendingActionable(ct);
        if (!expired and !actionable and @atomicLoad(bool, &inst.valid, .acquire)) {
            ct.state = .blocked;
            inst.spin.release(s2);
            sched.rescheduleAfterBlock();
            continue;
        }
        removeWaiterLocked(inst, &node);
        inst.spin.release(s2);
        disarmWaitDeadline(my_idx, generation);
        // Leaving without a grant: undo our own .blocked (no-op once woken).
        task_mod.unblockTask(my_idx);
        if (expired) return .timeout;
        if (actionable) {
            if (sig_mod.pendingFatal(ct)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
            return .interrupted;
        }
        return .event; // instance destroyed: epollWait reports EBADF
    }
}

fn disarmWaitDeadline(task_idx: u32, generation: u64) void {
    if (@atomicLoad(u64, &wait_generations[task_idx], .seq_cst) != generation) return;
    @atomicStore(u64, &wait_deadlines[task_idx], 0, .seq_cst);
    @atomicStore(u32, &wait_instance_slots[task_idx], 0, .seq_cst);
    @atomicStore(u64, &wait_instance_generations[task_idx], 0, .seq_cst);
    _ = @atomicRmw(u64, &epoll_wait_bm, .And, ~(@as(u64, 1) << @intCast(task_idx)), .seq_cst);
}

/// Wake expired waiters so their normal epoll loop can return a timeout.
/// The instance lock serializes this unlink with readiness and signal cleanup.
pub fn timerTick(now_ns: u64) void {
    var bm = @atomicLoad(u64, &epoll_wait_bm, .acquire);
    while (bm != 0) {
        const i: u6 = @truncate(@ctz(bm));
        bm &= bm - 1;
        const idx: u32 = i;
        const deadline = @atomicLoad(u64, &wait_deadlines[idx], .seq_cst);
        if (deadline == 0 or now_ns < deadline) continue;
        const generation = @atomicLoad(u64, &wait_generations[idx], .seq_cst);
        const inst_slot = @atomicLoad(u32, &wait_instance_slots[idx], .seq_cst);
        const inst_generation = @atomicLoad(u64, &wait_instance_generations[idx], .seq_cst);
        if (inst_slot >= MAX_EPOLL_INSTANCES or inst_generation == 0) {
            disarmWaitDeadline(idx, generation);
            continue;
        }
        var borrow = acquireInstance(inst_slot) orelse {
            disarmWaitDeadline(idx, generation);
            continue;
        };
        defer borrow.release();
        if (borrow.generation != inst_generation) continue;
        const inst = borrow.instance;
        const saved = inst.spin.acquire();
        var prev: ?*WaitNode = null;
        var current = inst.waiter;
        var unlinked = false;
        while (current) |node| {
            if (node.task_idx == idx and node.generation == generation and
                @atomicLoad(u64, &wait_deadlines[idx], .seq_cst) == deadline and
                @atomicLoad(u32, &wait_instance_slots[idx], .seq_cst) == inst_slot and
                @atomicLoad(u64, &wait_instance_generations[idx], .seq_cst) == inst_generation)
            {
                if (prev) |p| p.next = node.next else inst.waiter = node.next;
                node.next = null;
                unlinked = true;
                break;
            }
            prev = node;
            current = node.next;
        }
        inst.spin.release(saved);
        disarmWaitDeadline(idx, generation);
        if (unlinked) {
            task_mod.unblockTask(idx);
        }
    }
}

/// Unlink a wait node from the instance waiter list. Caller holds inst.spin.
fn removeWaiterLocked(inst: *EpollInstance, node: *WaitNode) void {
    var prev: ?*WaitNode = null;
    var cur = inst.waiter;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                inst.waiter = n.next;
            }
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

fn wakeWaiterLocked(inst: *EpollInstance) void {
    if (inst.waiter) |node| {
        inst.waiter = node.next;
        node.next = null;
        @atomicStore(bool, &node.granted, true, .release);
        task_mod.unblockTask(node.task_idx);
    }
}

/// Add a cross-process reference (fork/clone fd-table copy).
pub fn epollRetain(epoll_idx: u32) void {
    if (epoll_idx >= MAX_EPOLL_INSTANCES) return;
    const psaved = pool_lock.acquire();
    defer pool_lock.release(psaved);
    const inst = &epoll_pool[epoll_idx];
    if (!@atomicLoad(bool, &inst.valid, .acquire)) return;
    inst.ref_count += 1;
}

/// Destroy an epoll instance by pool index (used by VFS close).
pub fn epollDestroy(epoll_idx: u32) void {
    if (epoll_idx >= MAX_EPOLL_INSTANCES) return;
    const psaved = pool_lock.acquire();
    const inst = &epoll_pool[epoll_idx];
    if (!@atomicLoad(bool, &inst.valid, .acquire) or @atomicLoad(bool, &inst.closing, .acquire)) {
        pool_lock.release(psaved);
        return;
    }
    // Shared across fork/clone: drop one reference, free only at zero.
    if (@atomicLoad(bool, &inst.valid, .acquire) and inst.ref_count > 1) {
        inst.ref_count -= 1;
        pool_lock.release(psaved);
        return;
    }
    @atomicStore(bool, &inst.closing, true, .release);
    @atomicStore(bool, &inst.valid, false, .release);
    valid_epoll_bm &= ~(@as(u32, 1) << @intCast(epoll_idx));
    // Take the instance lock before detaching: an IRQ-side epollNotify may hold
    // it — wait for that critical section to finish.
    const isaved = inst.spin.acquire();
    // Wait nodes live on blocked waiters' kernel stacks. Snapshot the complete
    // chain while it is protected, so no node is dereferenced after its task
    // has been made runnable.
    const DetachedWaiter = struct {
        task_idx: u32,
        generation: u64,
    };
    var detached_waiters: [task_mod.MAX_TASKS]DetachedWaiter = undefined;
    var detached_count: usize = 0;
    var detached = inst.waiter;
    inst.waiter = null;
    while (detached) |node| {
        const next = node.next;
        detached_waiters[detached_count] = .{
            .task_idx = node.task_idx,
            .generation = node.generation,
        };
        detached_count += 1;
        node.next = null;
        @atomicStore(bool, &node.granted, true, .release);
        detached = next;
    }
    inst.spin.release(isaved);
    pool_lock.release(psaved);

    // The instance is detached before any task is woken. Deadline state is
    // cleared only if this node still owns the matching task generation.
    for (detached_waiters[0..detached_count]) |waiter| {
        if (@atomicLoad(u64, &wait_generations[waiter.task_idx], .seq_cst) != waiter.generation) continue;
        disarmWaitDeadline(waiter.task_idx, waiter.generation);
        if (@atomicLoad(u64, &wait_generations[waiter.task_idx], .seq_cst) != waiter.generation) continue;
        if (task_mod.getTask(waiter.task_idx)) |task| {
            if (task.state == .blocked) {
                task_mod.unblockTask(waiter.task_idx);
            }
        }
    }
    const final_lock = pool_lock.acquire();
    if (inst.active_ops == 0 and @atomicLoad(bool, &inst.closing, .acquire)) {
        const generation = inst.generation +% 1;
        epoll_pool[epoll_idx] = .{ .generation = generation };
    }
    pool_lock.release(final_lock);
}
