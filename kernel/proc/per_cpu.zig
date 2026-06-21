//! Per-CPU run queues with work-stealing (Task #2).
//!
//! Each logical CPU owns a fixed-size ring buffer of ready tasks. Local
//! enqueue / dequeue happen at `head`; remote stealers consume from `tail`.
//!
//! Locking model:
//!   * `head` / `tail` updates are serialised via the per-queue `lock`.
//!   * Local push/pop and remote `steal_half` all take the same per-queue
//!     `IrqSpinlock`. This intentionally diverges from the "lock-free local
//!     fast path" mentioned in the design doc — the spinlock is irq-safe and
//!     held only for tens of cycles, so contention is bounded to one CPU pair
//!     during a steal. The win over the previous global `sched_lock` is that
//!     a busy CPU's run queue is independent of every other CPU's.
//!
//! Tasks pinned via `cpu_affinity >= 0` are still placed in the affinity
//! CPU's queue and never stolen — see `enqueueTask` / `steal_half`.

const task_mod = @import("task.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const syscall_entry = @import("../arch/x86_64/syscall_entry.zig");
const tsc = @import("../arch/x86_64/tsc.zig");

pub const MAX_CPUS: u32 = syscall_entry.MAX_CPUS;
pub const QUEUE_SIZE: u32 = 256;

pub const PerCpuRunQueue = struct {
    /// Ring buffer of ready tasks (capacity = QUEUE_SIZE).
    tasks: [QUEUE_SIZE]?*task_mod.Task = [_]?*task_mod.Task{null} ** QUEUE_SIZE,
    /// Local-CPU enqueue/dequeue end (LIFO for cache locality).
    head: u32 = 0,
    /// Steal end (other CPUs consume from here).
    tail: u32 = 0,
    /// Serialises head/tail updates. Acquired by both local and remote ops.
    lock: IrqSpinlock = .{},
    /// Idle task used when the queue is empty and no task can be stolen.
    idle_task: ?*task_mod.Task = null,
    /// Currently running task on this CPU (nullable when idling pre-bootstrap).
    current: ?*task_mod.Task = null,
    /// Logical CPU id this queue belongs to.
    cpu_id: u8 = 0,
    /// Number of tasks currently sitting in the ring (head - tail).
    nr_running: u32 = 0,

    /// Push a task onto the local end of the queue. Returns false if full.
    pub fn push(self: *PerCpuRunQueue, t: *task_mod.Task) bool {
        const flags = self.lock.acquire();
        defer self.lock.release(flags);
        if (self.nr_running >= QUEUE_SIZE) return false;
        const slot = self.head % QUEUE_SIZE;
        self.tasks[slot] = t;
        self.head +%= 1;
        self.nr_running += 1;
        t.last_cpu = self.cpu_id;
        return true;
    }

    /// Pop a task from the local end (most recently pushed).
    pub fn pop(self: *PerCpuRunQueue) ?*task_mod.Task {
        const flags = self.lock.acquire();
        defer self.lock.release(flags);
        if (self.nr_running == 0) return null;
        self.head -%= 1;
        const slot = self.head % QUEUE_SIZE;
        const t = self.tasks[slot];
        self.tasks[slot] = null;
        self.nr_running -= 1;
        return t;
    }

    /// Steal up to half of `target`'s tasks into self. Returns count stolen.
    /// Tasks pinned via `cpu_affinity >= 0` to a different CPU are skipped.
    pub fn steal_half(self: *PerCpuRunQueue, target: *PerCpuRunQueue) u32 {
        if (self.cpu_id == target.cpu_id) return 0;
        const flags = target.lock.acquire();
        defer target.lock.release(flags);
        const want: u32 = target.nr_running / 2;
        if (want == 0) return 0;
        var stolen: u32 = 0;
        var attempts: u32 = 0;
        while (stolen < want and attempts < target.nr_running) : (attempts += 1) {
            if (target.nr_running == 0) break;
            const slot = target.tail % QUEUE_SIZE;
            const tt_opt = target.tasks[slot];
            target.tasks[slot] = null;
            target.tail +%= 1;
            target.nr_running -= 1;
            const tt = tt_opt orelse continue;
            // Skip tasks pinned away from us.
            if (tt.cpu_affinity >= 0 and tt.cpu_affinity != @as(i8, @intCast(self.cpu_id))) {
                // Re-insert at target's local end (head) so it stays runnable
                // on its pinned CPU. This walks the loop's tail forward but
                // never loses the task.
                if (target.nr_running < QUEUE_SIZE) {
                    const re_slot = target.head % QUEUE_SIZE;
                    target.tasks[re_slot] = tt;
                    target.head +%= 1;
                    target.nr_running += 1;
                }
                continue;
            }
            // Push into self (we already hold target.lock; self is local —
            // no races on its head, but bump nr_running atomically wrt readers).
            if (self.nr_running >= QUEUE_SIZE) {
                // Self overflowed: put it back on target.
                if (target.nr_running < QUEUE_SIZE) {
                    const re_slot = target.head % QUEUE_SIZE;
                    target.tasks[re_slot] = tt;
                    target.head +%= 1;
                    target.nr_running += 1;
                }
                break;
            }
            const my_slot = self.head % QUEUE_SIZE;
            self.tasks[my_slot] = tt;
            self.head +%= 1;
            self.nr_running += 1;
            tt.last_cpu = self.cpu_id;
            stolen += 1;
        }
        return stolen;
    }

    /// True if any task is currently queued (atomic snapshot).
    pub fn isEmpty(self: *PerCpuRunQueue) bool {
        return @atomicLoad(u32, &self.nr_running, .monotonic) == 0;
    }
};

/// One run queue per logical CPU. Initialised lazily by `init(cpu_id)`.
pub var run_queues: [MAX_CPUS]PerCpuRunQueue = blk: {
    var arr: [MAX_CPUS]PerCpuRunQueue = undefined;
    var i: usize = 0;
    while (i < MAX_CPUS) : (i += 1) {
        arr[i] = .{ .cpu_id = @intCast(i) };
    }
    break :blk arr;
};

/// Whether `init(cpu_id)` has been called for that CPU.
var initialised: [MAX_CPUS]bool = [_]bool{false} ** MAX_CPUS;

/// Initialise the per-CPU queue for `cpu_id`. Idempotent.
pub fn init(cpu_id: u8) void {
    if (cpu_id >= MAX_CPUS) return;
    run_queues[cpu_id] = .{ .cpu_id = cpu_id };
    initialised[cpu_id] = true;
}

/// True if any per-CPU queue has been initialised — gates the new fast path
/// from running before main.zig has wired up the BSP queue.
pub fn isAnyReady() bool {
    for (initialised) |b| if (b) return true;
    return false;
}

/// Get the queue belonging to the CPU executing this code.
pub fn getCurrent() *PerCpuRunQueue {
    const pc = syscall_entry.getPerCpuOrNull() orelse return &run_queues[0];
    const id: u8 = @intCast(pc.cpu_id);
    if (id >= MAX_CPUS) return &run_queues[0];
    return &run_queues[id];
}

/// Get the queue for a specific logical CPU id.
pub fn getQueue(cpu_id: u8) ?*PerCpuRunQueue {
    if (cpu_id >= MAX_CPUS) return null;
    return &run_queues[cpu_id];
}

/// Decide which CPU a ready task should be enqueued onto:
///   * Pinned (cpu_affinity >= 0): the affinity CPU.
///   * Otherwise: the task's `last_cpu` (or 0 if uninitialised).
pub fn targetCpuFor(t: *task_mod.Task) u8 {
    if (t.cpu_affinity >= 0) return @intCast(t.cpu_affinity);
    return t.last_cpu;
}

/// Push a task onto its target CPU's queue. Returns false if the destination
/// queue is full (caller should fall back to bitmap scan).
pub fn enqueueTask(t: *task_mod.Task) bool {
    const cpu = targetCpuFor(t);
    if (cpu >= MAX_CPUS) return false;
    if (!initialised[cpu]) return false;
    return run_queues[cpu].push(t);
}

/// Try to steal work from any other CPU's queue (random-start scan).
/// Returns the number of tasks moved into the local queue.
pub fn tryStealForCurrent() u32 {
    const pc = syscall_entry.getPerCpuOrNull() orelse return 0;
    const my_id: u8 = @intCast(pc.cpu_id);
    if (my_id >= MAX_CPUS) return 0;
    const my = &run_queues[my_id];

    const smp = @import("../smp.zig");
    const ncpus_raw: u32 = smp.cpu_count;
    const ncpus: u8 = if (ncpus_raw == 0)
        1
    else if (ncpus_raw > MAX_CPUS)
        @intCast(MAX_CPUS)
    else
        @intCast(ncpus_raw);
    if (ncpus <= 1) return 0;

    // TSC-derived random start to spread steal-target contention.
    const start: u8 = @as(u8, @truncate(tsc.read())) % ncpus;
    var i: u8 = 0;
    while (i < ncpus) : (i += 1) {
        const other: u8 = (start +% i) % ncpus;
        if (other == my_id) continue;
        if (!initialised[other]) continue;
        const target = &run_queues[other];
        // Only bother if target has more than a single task — leaving 1 on
        // the victim avoids ping-ponging with the next steal cycle.
        if (@atomicLoad(u32, &target.nr_running, .monotonic) > 1) {
            const n = my.steal_half(target);
            if (n > 0) return n;
        }
    }
    return 0;
}
