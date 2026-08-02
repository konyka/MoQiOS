/// epoll — Linux-compatible event multiplexing.
///
/// Provides epoll_create1, epoll_ctl, and epoll_wait system calls.
/// Uses a simple array-based fd management (max 64 fds per instance)
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
const idt = @import("../arch/arch.zig").interrupts;

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

/// Limits.
pub const MAX_EPOLL_INSTANCES: u32 = 32;
pub const MAX_EPOLL_ITEMS: u8 = 128;

/// Approximate timer tick interval (ms).
const TICK_MS: u64 = 10;

/// EpollEvent — matches Linux struct epoll_event (8 bytes payload).
pub const EpollEvent = extern struct {
    events: u32,
    data: u64,
};

/// WaitNode for epoll_wait blocking — stack-allocated on the
/// waiter's kernel stack, modelled after eventfd.zig.
const WaitNode = struct {
    task_idx: u32,
    granted: bool = false,
    next: ?*WaitNode = null,
};

/// EpollItem — per-fd registration within an epoll instance.
pub const EpollItem = struct {
    fd: i32 = -1,
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
};

// ---- Global pool ----

var epoll_pool: [MAX_EPOLL_INSTANCES]EpollInstance = @splat(.{});
/// Bitmap of valid epoll instances (1 = valid).
var valid_epoll_bm: u32 = 0;
/// Guards valid_epoll_bm and instance create/destroy. Lock order:
/// pool_lock -> inst.spin (epollNotify may run from IRQ context).
var pool_lock: IrqSpinlock = .{};

/// Obtain a pointer to an epoll instance by index.
pub fn getInstance(idx: u32) ?*EpollInstance {
    if (idx >= MAX_EPOLL_INSTANCES) return null;
    const inst = &epoll_pool[idx];
    if (!inst.valid) return null;
    return inst;
}

// ---- Public API ----

/// Create a new epoll instance.
/// Returns the pool index or a negative errno on failure.
pub fn epollCreate() i32 {
    const cur_idx = sched.currentTaskIndex() orelse return @intCast(EMFILE);
    const psaved = pool_lock.acquire();
    defer pool_lock.release(psaved);
    const all_mask: u32 = if (MAX_EPOLL_INSTANCES >= 32) 0xFFFFFFFF else (@as(u32, 1) << MAX_EPOLL_INSTANCES) - 1;
    const free_mask = ~valid_epoll_bm & all_mask;
    if (free_mask == 0) return @intCast(EMFILE);
    const i: u5 = @intCast(@ctz(free_mask));
    valid_epoll_bm |= @as(u32, 1) << i;
    epoll_pool[i] = .{
        .owner_task_idx = cur_idx,
        .valid = true,
    };
    return @intCast(i);
}

/// Control an epoll instance — add, modify, or delete an fd registration.
pub fn epollCtl(epfd_idx: u32, op: i32, fd: i32, event_ptr: u64) i64 {
    const inst = getInstance(epfd_idx) orelse return EBADF;
    if (fd < 0) return EBADF;

    const cur_idx = sched.currentTaskIndex() orelse return EBADF;
    const cur = task_mod.getTask(cur_idx) orelse return EBADF;
    if (fd >= @as(i32, @intCast(vfs.MAX_FDS))) return EBADF;
    const desc = &cur.fd_table.fds[@as(u32, @intCast(fd))];
    if (desc.fd_type == .none) return EBADF;

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
                    if (inst.items[i].fd == fd) return EEXIST;
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
                .events = ev.events,
                .data = ev.data,
                .fd_type = desc.fd_type,
                .resource_idx = resourceIdxFromDesc(desc),
                .is_et = (ev.events & EPOLLET) != 0,
                .is_oneshot = (ev.events & EPOLLONESHOT) != 0,
                .in_use = true,
            };
            inst.item_count += 1;
            inst.in_use_bm[s >> 6] |= @as(u64, 1) << @intCast(s & 63);

            const current = computeCurrentEvents(desc.fd_type, resourceIdxFromDesc(desc));
            if (current & (ev.events & ~EPOLLET & ~EPOLLONESHOT) != 0) {
                addToReadyList(inst, @intCast(s));
            }
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
                    if (item.fd == fd) {
                        const ev = copyEventFromUser(event_ptr) orelse return EINVAL;
                        item.events = ev.events;
                        item.data = ev.data;
                        item.is_et = (ev.events & EPOLLET) != 0;
                        item.is_oneshot = (ev.events & EPOLLONESHOT) != 0;
                        item.is_disabled = false;
                        item.last_reported = 0;
                        found = true;
                        if (!item.on_ready) {
                            const current = computeCurrentEvents(item.fd_type, item.resource_idx);
                            if (current & (ev.events & ~EPOLLET & ~EPOLLONESHOT) != 0) {
                                addToReadyList(inst, i);
                            }
                        }
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
                    if (inst.items[i].fd == fd) {
                        if (inst.items[i].on_ready) removeFromReadyList(inst, inst.items[i].fd);
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
    const inst = getInstance(epfd_idx) orelse return EBADF;
    const max_out: u32 = @min(max_events, MAX_EPOLL_ITEMS);
    const copy = @import("../mm/copy_from_user.zig");
    if (!copy.validateUserBufferWritable(events_buf, @as(usize, max_out) * @sizeOf(EpollEvent))) return -14; // EFAULT

    var start_tick: u64 = 0;
    if (timeout_ms >= 0) start_tick = idt.getTickCount();

    while (true) {
        // Woken by epollDestroy: the instance is gone, report EBADF.
        if (!inst.valid) return EBADF;
        var out_events: [MAX_EPOLL_ITEMS]EpollEvent = undefined;
        const n = collectEvents(inst, &out_events, max_out);
        if (n > 0) {
            const bytes: usize = @as(usize, n) * @sizeOf(EpollEvent);
            if (copy.copyToUser(@ptrFromInt(events_buf), @ptrCast(&out_events), bytes) != bytes) return -14; // EFAULT
            return @intCast(n);
        }
        if (timeout_ms == 0) return 0;
        if (timeout_ms > 0) {
            const elapsed_ms = (idt.getTickCount() - start_tick) * TICK_MS;
            if (elapsed_ms >= @as(u64, @intCast(timeout_ms))) return 0;
        }
        switch (blockOnEpoll(inst, start_tick, timeout_ms)) {
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
                }
            }
        }

        wakeWaiterLocked(inst);
        inst.spin.release(saved);
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
        else => 0,
    };
}

fn computeCurrentEvents(fd_type: vfs.FdType, resource_idx: u32) u32 {
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
        .ramdisk_file, .fat32_file, .ext2_file, .proc_file => {
            revents |= EPOLLIN | EPOLLOUT;
        },
        .epoll => {
            const inst = getInstance(resource_idx) orelse return EPOLLERR;
            if (inst.ready_head != null) revents |= EPOLLIN;
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
        .unix_socket => {},
        .none => {},
        .random => {
            revents |= EPOLLIN;
        },
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

fn removeFromReadyList(inst: *EpollInstance, fd: i32) void {
    var prev: ?u8 = null;
    var cur = inst.ready_head;
    while (cur) |idx| {
        const next = inst.items[idx].ready_next;
        if (inst.items[idx].fd == fd) {
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

fn collectEvents(inst: *EpollInstance, out: []EpollEvent, max_out: u32) u32 {
    const saved = inst.spin.acquire();

    const scan_head = inst.ready_head;
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

        const current = computeCurrentEvents(item.fd_type, item.resource_idx);
        const interest = item.events & ~EPOLLET & ~EPOLLONESHOT;
        const matched = current & interest;
        const always_report = current & (EPOLLERR | EPOLLHUP);
        const final_events = matched | always_report;

        if (final_events != 0 and count < max_out) {
            out[count] = .{
                .events = final_events,
                .data = item.data,
            };
            count += 1;

            if (item.is_oneshot) {
                item.is_disabled = true;
            } else if (!item.is_et) {
                if (matched != 0) {
                    addToReadyListLocked(inst, @intCast(idx));
                }
            }
        }
        cur = next;
    }

    inst.spin.release(saved);
    return count;
}

/// Result of blockOnEpoll.
const BlockOutcome = enum {
    /// Woken by a readiness notification (or events were already pending).
    event,
    /// The tick-based deadline expired (caller returns 0 to userspace).
    timeout,
    /// A pending signal kicked the task out of the wait (caller returns -EINTR).
    interrupted,
};

/// Block until an event arrives, the tick-based deadline expires, or a
/// pending signal interrupts the wait.
fn blockOnEpoll(inst: *EpollInstance, start_tick: u64, timeout_ms: i32) BlockOutcome {
    const my_idx = sched.currentTaskIndex() orelse {
        asm volatile ("sti; hlt");
        return .event;
    };

    const saved = inst.spin.acquire();

    if (inst.ready_head != null) {
        inst.spin.release(saved);
        return .event;
    }

    var node = WaitNode{
        .task_idx = my_idx,
        .granted = false,
        .next = inst.waiter,
    };
    inst.waiter = &node;

    if (task_mod.getTask(my_idx)) |t| {
        t.state = .blocked;
        asm volatile ("" ::: .{ .memory = true });
    }

    inst.spin.release(saved);

    while (!@atomicLoad(bool, &node.granted, .acquire)) {
        if (timeout_ms > 0) {
            const elapsed_ms = (idt.getTickCount() - start_tick) * TICK_MS;
            if (elapsed_ms >= @as(u64, @intCast(timeout_ms))) {
                // Deadline expired: unlink our wait node unless a concurrent
                // notify already granted it (wakeWaiterLocked holds inst.spin).
                const s2 = inst.spin.acquire();
                const granted = node.granted;
                if (!granted) removeWaiterLocked(inst, &node);
                inst.spin.release(s2);
                if (!granted) {
                    // We set our own state to .blocked above — restore it.
                    task_mod.unblockTask(my_idx);
                    return .timeout;
                }
            }
        }
        // Signal kick: sendSignal unblocks the task without granting the
        // wait node. Bail out with EINTR (handled signal) or die via the
        // same exit-by-signal path the timer tick uses (fatal default).
        if (task_mod.getTask(my_idx)) |ct| {
            const sig_mod = @import("../proc/signal.zig");
            if (sig_mod.pendingActionable(ct)) {
                const s2 = inst.spin.acquire();
                const granted = node.granted;
                if (!granted) removeWaiterLocked(inst, &node);
                inst.spin.release(s2);
                if (!granted) {
                    task_mod.unblockTask(my_idx);
                    if (sig_mod.pendingFatal(ct)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
                    return .interrupted;
                }
            }
        }
        asm volatile ("sti; hlt");
    }
    return .event;
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
    if (!inst.valid) return;
    inst.ref_count += 1;
}

/// Destroy an epoll instance by pool index (used by VFS close).
pub fn epollDestroy(epoll_idx: u32) void {
    if (epoll_idx >= MAX_EPOLL_INSTANCES) return;
    const psaved = pool_lock.acquire();
    defer pool_lock.release(psaved);
    const inst = &epoll_pool[epoll_idx];
    // Shared across fork/clone: drop one reference, free only at zero.
    if (inst.valid and inst.ref_count > 1) {
        inst.ref_count -= 1;
        return;
    }
    // Take the instance lock before wiping: an IRQ-side epollNotify may hold
    // it — wait for that critical section to finish.
    const isaved = inst.spin.acquire();
    // Wake any task blocked in blockOnEpoll so it can observe the destroy.
    wakeWaiterLocked(inst);
    if (epoll_idx < 32) {
        valid_epoll_bm &= ~(@as(u32, 1) << @intCast(epoll_idx));
    }
    // Wipe the instance but preserve the lock word we are holding.
    const spin = inst.spin;
    epoll_pool[epoll_idx] = .{};
    inst.spin = spin;
    inst.spin.release(isaved);
}
