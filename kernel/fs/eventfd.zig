/// eventfd — lightweight event notification mechanism.
///
/// Provides a simple file-descriptor-based event notification that can be
/// used for signaling between kernel subsystems or user-space processes.
///
/// Design:
///   - Global pool of 16 eventfd instances
///   - Each instance holds a 64-bit counter
///   - Read: returns the counter value and resets to 0
///   - Write: adds to the counter (wakes any blocked reader)
///   - Supports epoll integration via epollNotify
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const idt = @import("../arch/arch.zig").interrupts;
const bo = @import("../lib/byte_order.zig");

/// Limits.
pub const MAX_EVENTFD_INSTANCES: u32 = 16;

/// Eventfd instance.
pub const EventfdInstance = struct {
    counter: u64 = 0,
    spin: IrqSpinlock = .{},
    waiter: ?*WaitNode = null,
    owner_task_idx: u32 = 0,
    valid: bool = false,
};

/// WaitNode for blocking read — stack-allocated on the waiter's kernel stack.
const WaitNode = struct {
    task_idx: u32,
    granted: bool = false,
    next: ?*WaitNode = null,
};

// Global pool
var eventfd_pool: [MAX_EVENTFD_INSTANCES]EventfdInstance = @splat(.{});

/// Create a new eventfd instance.
/// Returns the pool index or a negative errno on failure.
pub fn eventfdCreate(init_val: u64) i32 {
    const cur_idx = sched.currentTaskIndex() orelse return -24; // EMFILE
    for (&eventfd_pool, 0..) |*inst, i| {
        if (!inst.valid) {
            inst.* = .{
                .counter = init_val,
                .owner_task_idx = cur_idx,
                .valid = true,
            };
            return @intCast(i);
        }
    }
    return -24; // EMFILE
}

/// Read from an eventfd instance.
/// Returns the counter value as 8 bytes written to buf, resets counter to 0.
/// Returns 8 on success, -1 on error, 0 if no data available.
pub fn eventfdRead(eventfd_idx: u32, buf: [*]u8, count: usize) i64 {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return -1;
    const inst = &eventfd_pool[eventfd_idx];
    if (!inst.valid) return -1;

    const saved = inst.spin.acquire();
    defer inst.spin.release(saved);

    if (inst.counter == 0) return 0;

    const val = inst.counter;
    inst.counter = 0;

    if (count >= 8) {
        // Write little-endian u64
        bo.writeU64At(buf, 0, val);
    }

    // Notify epoll: writable now (counter was drained)
    const epoll_mod = @import("../net/epoll.zig");
    epoll_mod.epollNotify(.eventfd, eventfd_idx, epoll_mod.EPOLLOUT);

    return 8;
}

/// Write to an eventfd instance.
/// Adds val to the counter (must be a u64).
/// Returns 8 on success, -1 on error.
pub fn eventfdWrite(eventfd_idx: u32, buf: [*]const u8, count: usize) i64 {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return -1;
    const inst = &eventfd_pool[eventfd_idx];
    if (!inst.valid) return -1;
    if (count < 8) return -1;

    // Read little-endian u64
    const val: u64 = bo.readU64At(buf, 0);

    if (val == 0xFFFFFFFFFFFFFFFF) return -1; // would overflow

    const saved = inst.spin.acquire();

    const new_counter = inst.counter +| val;
    inst.counter = new_counter;

    // Wake any blocked reader
    if (inst.waiter) |node| {
        inst.waiter = node.next;
        node.next = null;
        @atomicStore(bool, &node.granted, true, .release);
        task_mod.unblockTask(node.task_idx);
    }

    inst.spin.release(saved);

    // Notify epoll: readable now (counter > 0)
    const epoll_mod = @import("../net/epoll.zig");
    epoll_mod.epollNotify(.eventfd, eventfd_idx, epoll_mod.EPOLLIN);

    return 8;
}

/// Close an eventfd instance.
pub fn eventfdClose(eventfd_idx: u32) void {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return;
    const inst = &eventfd_pool[eventfd_idx];

    const saved = inst.spin.acquire();
    defer inst.spin.release(saved);

    // Wake any blocked waiter
    if (inst.waiter) |node| {
        inst.waiter = node.next;
        node.next = null;
        @atomicStore(bool, &node.granted, true, .release);
        task_mod.unblockTask(node.task_idx);
    }

    // Notify epoll: hangup
    const epoll_mod = @import("../net/epoll.zig");
    epoll_mod.epollNotify(.eventfd, eventfd_idx, epoll_mod.EPOLLHUP);

    inst.* = .{};
}

/// Get the current counter value (for epoll computeCurrentEvents).
pub fn eventfdGetCounter(eventfd_idx: u32) u64 {
    if (eventfd_idx >= MAX_EVENTFD_INSTANCES) return 0;
    const inst = &eventfd_pool[eventfd_idx];
    if (!inst.valid) return 0;
    return inst.counter;
}
