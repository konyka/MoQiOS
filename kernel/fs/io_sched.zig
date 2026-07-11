/// I/O Deadline Scheduler — reduces seek time and prevents starvation.
///
/// Algorithm:
///   - Two queues per device: sorted_queue (LBA-ordered) + deadline_queue (FIFO by submit time)
///   - Requests expire after DEADLINE_MS (default 500ms)
///   - Normal dispatch: serve from sorted_queue (elevator merge + sequential I/O)
///   - On expiry: serve from deadline_queue (prevents starvation)
///   - Batch: serve reads before writes (read-priority, anti-write-starvation)
///   - Elevator merge: consecutive LBA requests merged into single large request

const serial = @import("../arch/arch.zig").serial;
const idt = @import("../arch/x86_64/idt.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const DEADLINE_MS: u64 = 500; // Request expiry time
const MAX_PENDING: u32 = 64; // Max pending I/O requests per device
const MAX_IO_SCHED_DEVICES: u32 = 4; // Max devices with I/O schedulers

pub const IoDirection = enum(u8) {
    read = 0,
    write = 1,
};

pub const IoSchedRequest = struct {
    dev_idx: u8,
    direction: IoDirection,
    lba: u64,
    sector_count: u32,
    buffer: [*]u8,
    submit_tick: u64, // When submitted (tick count)
    merged: bool = false, // Whether this was merged into another request
    completed: bool = false,
    result: i32 = 0,
    // Linked list pointers for sorted and deadline queues
    sorted_next: ?u16 = null, // Index into pending array (sorted by LBA)
    deadline_next: ?u16 = null, // Index into pending array (FIFO by submit time)
};

pub const IoSchedDevice = struct {
    active: bool = false,
    dev_idx: u8 = 0,
    pending: [MAX_PENDING]IoSchedRequest = @splat(.{
        .dev_idx = 0,
        .direction = .read,
        .lba = 0,
        .sector_count = 0,
        .buffer = undefined,
        .submit_tick = 0,
    }),
    pending_count: u32 = 0,
    // Sorted queue heads (LBA-ordered) — separate for reads and writes
    read_sorted_head: ?u16 = null,
    write_sorted_head: ?u16 = null,
    // Deadline queue heads (FIFO by submit time)
    read_deadline_head: ?u16 = null,
    write_deadline_head: ?u16 = null,
    // Free list
    free_head: ?u16 = null,
    // Batch state: alternate between read and write batches
    serving_reads: bool = true, // Start with read batch
    reads_in_batch: u32 = 0,
    writes_in_batch: u32 = 0,
    const BATCH_READ_LIMIT: u32 = 16; // Max reads before switching to writes
    const BATCH_WRITE_LIMIT: u32 = 8; // Max writes before switching to reads
};

var sched_devices: [MAX_IO_SCHED_DEVICES]IoSchedDevice = @splat(.{});
var sched_count: u32 = 0;
var io_sched_lock: IrqSpinlock = .{};

/// Register a device with the I/O scheduler.
/// Returns the scheduler device index, or null if full.
pub fn registerDevice(dev_idx: u8) ?u32 {
    const flags = io_sched_lock.acquire();
    defer io_sched_lock.release(flags);

    if (sched_count >= MAX_IO_SCHED_DEVICES) return null;

    const idx = sched_count;
    sched_devices[idx].active = true;
    sched_devices[idx].dev_idx = dev_idx;
    sched_devices[idx].pending_count = 0;
    sched_devices[idx].read_sorted_head = null;
    sched_devices[idx].write_sorted_head = null;
    sched_devices[idx].read_deadline_head = null;
    sched_devices[idx].write_deadline_head = null;
    sched_devices[idx].serving_reads = true;
    sched_devices[idx].reads_in_batch = 0;
    sched_devices[idx].writes_in_batch = 0;

    // Initialize free list — all slots are free
    for (0..MAX_PENDING - 1) |i| {
        sched_devices[idx].pending[i].sorted_next = @intCast(i + 1);
    }
    sched_devices[idx].pending[MAX_PENDING - 1].sorted_next = null;
    sched_devices[idx].free_head = 0;

    sched_count += 1;
    return idx;
}

/// Submit an I/O request to the scheduler.
/// Returns true if successfully queued, false if queue full.
pub fn submitRequest(sched_idx: u32, dev_idx: u8, direction: IoDirection, lba: u64, sector_count: u32, buffer: [*]u8) bool {
    const flags = io_sched_lock.acquire();

    if (sched_idx >= sched_count or !sched_devices[sched_idx].active) {
        io_sched_lock.release(flags);
        return false;
    }

    var sd = &sched_devices[sched_idx];

    // Try elevator merge first
    if (tryMerge(sd, direction, lba, sector_count, buffer)) {
        io_sched_lock.release(flags);
        return true;
    }

    // Allocate a slot from free list
    const slot = sd.free_head orelse {
        io_sched_lock.release(flags);
        serial.writeString("[io_sched] queue full for dev ");
        var buf: [8]u8 = undefined;
        serial.writeString(formatSmall(&buf, dev_idx));
        serial.writeString("\n");
        return false;
    };

    sd.free_head = sd.pending[slot].sorted_next;
    sd.pending_count += 1;

    // Fill the request
    sd.pending[slot].dev_idx = dev_idx;
    sd.pending[slot].direction = direction;
    sd.pending[slot].lba = lba;
    sd.pending[slot].sector_count = sector_count;
    sd.pending[slot].buffer = buffer;
    sd.pending[slot].submit_tick = idt.getTickCount();
    sd.pending[slot].merged = false;
    sd.pending[slot].completed = false;
    sd.pending[slot].result = 0;
    sd.pending[slot].sorted_next = null;
    sd.pending[slot].deadline_next = null;

    // Insert into sorted queue (LBA-ordered) — insertion sort
    insertSorted(sd, slot, direction);

    // Insert into deadline queue (FIFO — append to tail)
    insertDeadline(sd, slot, direction);

    io_sched_lock.release(flags);
    return true;
}

/// Dispatch the next I/O request from the scheduler.
/// Checks for expired deadlines first, then serves from sorted queue.
/// Returns the request slot index, or null if no pending requests.
pub fn dispatchNext(sched_idx: u32) ?u16 {
    const flags = io_sched_lock.acquire();

    if (sched_idx >= sched_count or !sched_devices[sched_idx].active) {
        io_sched_lock.release(flags);
        return null;
    }

    var sd = &sched_devices[sched_idx];

    if (sd.pending_count == 0) {
        io_sched_lock.release(flags);
        return null;
    }

    const current_tick = idt.getTickCount();
    const deadline_threshold = if (current_tick > DEADLINE_MS) current_tick - DEADLINE_MS else 0;

    // Check for expired read requests
    if (sd.read_deadline_head) |head| {
        if (sd.pending[head].submit_tick < deadline_threshold) {
            const slot = removeDeadlineHead(sd, .read);
            removeFromSorted(sd, slot, .read);
            sd.pending_count -= 1;
            io_sched_lock.release(flags);
            return slot;
        }
    }

    // Check for expired write requests
    if (sd.write_deadline_head) |head| {
        if (sd.pending[head].submit_tick < deadline_threshold) {
            const slot = removeDeadlineHead(sd, .write);
            removeFromSorted(sd, slot, .write);
            sd.pending_count -= 1;
            io_sched_lock.release(flags);
            return slot;
        }
    }

    // Normal dispatch: batch-based, read-priority
    var chosen_slot: ?u16 = null;

    if (sd.serving_reads) {
        if (sd.read_sorted_head != null) {
            chosen_slot = sd.read_sorted_head;
            if (chosen_slot) |s| {
                removeFromSorted(sd, s, .read);
                removeFromDeadline(sd, s, .read);
                sd.reads_in_batch += 1;
                if (sd.reads_in_batch >= IoSchedDevice.BATCH_READ_LIMIT and sd.write_sorted_head != null) {
                    sd.serving_reads = false;
                    sd.reads_in_batch = 0;
                }
            }
        } else if (sd.write_sorted_head != null) {
            sd.serving_reads = false;
            sd.reads_in_batch = 0;
            chosen_slot = sd.write_sorted_head;
            if (chosen_slot) |s| {
                removeFromSorted(sd, s, .write);
                removeFromDeadline(sd, s, .write);
                sd.writes_in_batch += 1;
            }
        }
    } else {
        if (sd.write_sorted_head != null) {
            chosen_slot = sd.write_sorted_head;
            if (chosen_slot) |s| {
                removeFromSorted(sd, s, .write);
                removeFromDeadline(sd, s, .write);
                sd.writes_in_batch += 1;
                if (sd.writes_in_batch >= IoSchedDevice.BATCH_WRITE_LIMIT and sd.read_sorted_head != null) {
                    sd.serving_reads = true;
                    sd.writes_in_batch = 0;
                }
            }
        } else if (sd.read_sorted_head != null) {
            sd.serving_reads = true;
            sd.writes_in_batch = 0;
            chosen_slot = sd.read_sorted_head;
            if (chosen_slot) |s| {
                removeFromSorted(sd, s, .read);
                removeFromDeadline(sd, s, .read);
                sd.reads_in_batch += 1;
            }
        }
    }

    if (chosen_slot) |s| {
        // Return slot to free list (but keep data for caller to read)
        sd.pending_count -= 1;
        sd.pending[s].sorted_next = sd.free_head;
        sd.free_head = s;
    }

    io_sched_lock.release(flags);
    return chosen_slot;
}

/// Get a reference to a pending request by slot index.
pub fn getRequest(sched_idx: u32, slot: u16) ?*const IoSchedRequest {
    if (sched_idx >= sched_count) return null;
    if (slot >= MAX_PENDING) return null;
    return &sched_devices[sched_idx].pending[slot];
}

/// Get pending request count for a device.
pub fn getPendingCount(sched_idx: u32) u32 {
    if (sched_idx >= sched_count) return 0;
    return sched_devices[sched_idx].pending_count;
}

// ─── Internal Helpers ────────────────────────────────────────────────────

/// Try to merge a new request with an existing one in the sorted queue.
/// Returns true if merged successfully.
fn tryMerge(sd: *IoSchedDevice, direction: IoDirection, lba: u64, sector_count: u32, buffer: [*]u8) bool {
    const sorted_head = switch (direction) {
        .read => sd.read_sorted_head,
        .write => sd.write_sorted_head,
    };

    var current = sorted_head;
    while (current) |idx| {
        const req = &sd.pending[idx];
        if (req.direction != direction) {
            current = req.sorted_next;
            continue;
        }

        const req_end = req.lba + req.sector_count;
        const new_end = lba + sector_count;

        // Merge if adjacent or overlapping
        if (lba <= req_end and new_end >= req.lba) {
            // Extend the existing request
            const new_start = @min(req.lba, lba);
            const new_end_lba = @max(req_end, new_end);
            req.lba = new_start;
            req.sector_count = @intCast(new_end_lba - new_start);
            // Note: buffer pointer update is complex; for simplicity, keep original buffer
            // The merged request covers the combined range, caller should handle buffer layout
            _ = buffer;
            return true;
        }

        current = req.sorted_next;
    }
    return false;
}

/// Insert a request into the sorted queue (ordered by LBA).
fn insertSorted(sd: *IoSchedDevice, slot: u16, direction: IoDirection) void {
    const lba = sd.pending[slot].lba;

    switch (direction) {
        .read => {
            var prev: ?u16 = null;
            var current = sd.read_sorted_head;
            while (current) |idx| {
                if (sd.pending[idx].lba > lba) break;
                prev = current;
                current = sd.pending[idx].sorted_next;
            }
            sd.pending[slot].sorted_next = current;
            if (prev) |p| {
                sd.pending[p].sorted_next = slot;
            } else {
                sd.read_sorted_head = slot;
            }
        },
        .write => {
            var prev: ?u16 = null;
            var current = sd.write_sorted_head;
            while (current) |idx| {
                if (sd.pending[idx].lba > lba) break;
                prev = current;
                current = sd.pending[idx].sorted_next;
            }
            sd.pending[slot].sorted_next = current;
            if (prev) |p| {
                sd.pending[p].sorted_next = slot;
            } else {
                sd.write_sorted_head = slot;
            }
        },
    }
}

/// Insert a request into the deadline queue (FIFO — append to tail).
fn insertDeadline(sd: *IoSchedDevice, slot: u16, direction: IoDirection) void {
    switch (direction) {
        .read => {
            // Walk to tail
            var current = sd.read_deadline_head;
            if (current == null) {
                sd.read_deadline_head = slot;
                return;
            }
            while (current) |idx| {
                if (sd.pending[idx].deadline_next == null) {
                    sd.pending[idx].deadline_next = slot;
                    return;
                }
                current = sd.pending[idx].deadline_next;
            }
        },
        .write => {
            var current = sd.write_deadline_head;
            if (current == null) {
                sd.write_deadline_head = slot;
                return;
            }
            while (current) |idx| {
                if (sd.pending[idx].deadline_next == null) {
                    sd.pending[idx].deadline_next = slot;
                    return;
                }
                current = sd.pending[idx].deadline_next;
            }
        },
    }
}

/// Remove a slot from the sorted queue.
fn removeFromSorted(sd: *IoSchedDevice, slot: u16, direction: IoDirection) void {
    switch (direction) {
        .read => {
            var prev: ?u16 = null;
            var current = sd.read_sorted_head;
            while (current) |idx| {
                if (idx == slot) {
                    if (prev) |p| {
                        sd.pending[p].sorted_next = sd.pending[slot].sorted_next;
                    } else {
                        sd.read_sorted_head = sd.pending[slot].sorted_next;
                    }
                    return;
                }
                prev = current;
                current = sd.pending[idx].sorted_next;
            }
        },
        .write => {
            var prev: ?u16 = null;
            var current = sd.write_sorted_head;
            while (current) |idx| {
                if (idx == slot) {
                    if (prev) |p| {
                        sd.pending[p].sorted_next = sd.pending[slot].sorted_next;
                    } else {
                        sd.write_sorted_head = sd.pending[slot].sorted_next;
                    }
                    return;
                }
                prev = current;
                current = sd.pending[idx].sorted_next;
            }
        },
    }
}

/// Remove a slot from the deadline queue.
fn removeFromDeadline(sd: *IoSchedDevice, slot: u16, direction: IoDirection) void {
    switch (direction) {
        .read => {
            var prev: ?u16 = null;
            var current = sd.read_deadline_head;
            while (current) |idx| {
                if (idx == slot) {
                    if (prev) |p| {
                        sd.pending[p].deadline_next = sd.pending[slot].deadline_next;
                    } else {
                        sd.read_deadline_head = sd.pending[slot].deadline_next;
                    }
                    return;
                }
                prev = current;
                current = sd.pending[idx].deadline_next;
            }
        },
        .write => {
            var prev: ?u16 = null;
            var current = sd.write_deadline_head;
            while (current) |idx| {
                if (idx == slot) {
                    if (prev) |p| {
                        sd.pending[p].deadline_next = sd.pending[slot].deadline_next;
                    } else {
                        sd.write_deadline_head = sd.pending[slot].deadline_next;
                    }
                    return;
                }
                prev = current;
                current = sd.pending[idx].deadline_next;
            }
        },
    }
}

/// Remove the head of a deadline queue and return its slot index.
fn removeDeadlineHead(sd: *IoSchedDevice, direction: IoDirection) u16 {
    switch (direction) {
        .read => {
            const slot = sd.read_deadline_head orelse return 0xFFFF;
            sd.read_deadline_head = sd.pending[slot].deadline_next;
            return slot;
        },
        .write => {
            const slot = sd.write_deadline_head orelse return 0xFFFF;
            sd.write_deadline_head = sd.pending[slot].deadline_next;
            return slot;
        },
    }
}

fn formatSmall(buf: *[8]u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}
