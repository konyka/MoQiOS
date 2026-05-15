/// Capability-based access control for IPC.
///
/// Each task has a capability table with up to 32 slots.
/// Capabilities authorize specific IPC operations:
///   - Send to an endpoint
///   - Receive from an endpoint
///   - Notify an endpoint
///   - Manage (create/destroy) an endpoint
///
/// For M4, capabilities are simple tokens. Full capability
/// derivation (mint, restrict) comes in M5+.

const task = @import("../proc/task.zig");

/// Capability rights (bitmask).
pub const CapRights = packed struct {
    send: bool,
    receive: bool,
    notify: bool,
    manage: bool,
    pad: u4 = 0,
};

/// A capability authorizing access to an endpoint.
pub const Capability = packed struct {
    /// Target endpoint ID.
    endpoint: u32,
    /// Access rights.
    rights: CapRights,
    /// Whether this slot is in use.
    valid: bool,
    pad: u15 = 0,
};

pub const MAX_CAPS_PER_TASK: u32 = 32;

/// Per-task capability table.
const CapTable = [MAX_CAPS_PER_TASK]Capability;

/// Global capability tables — one per task slot.
var cap_tables: [task.MAX_TASKS]CapTable = [_]CapTable{
    [_]Capability{
        .{
            .endpoint = 0,
            .rights = .{ .send = false, .receive = false, .notify = false, .manage = false },
            .valid = false,
        },
    } ** MAX_CAPS_PER_TASK,
} ** task.MAX_TASKS;

/// Grant a capability to a task.
/// Returns the capability slot index, or null if the table is full.
pub fn grantCapability(task_idx: u32, endpoint: u32, rights: CapRights) ?u32 {
    if (task_idx >= task.MAX_TASKS) return null;
    const table = &cap_tables[task_idx];
    for (0..MAX_CAPS_PER_TASK) |i| {
        if (!table[i].valid) {
            table[i] = .{
                .endpoint = endpoint,
                .rights = rights,
                .valid = true,
            };
            return @intCast(i);
        }
    }
    return null;
}

/// Revoke a capability from a task.
pub fn revokeCapability(task_idx: u32, cap_slot: u32) void {
    if (task_idx >= task.MAX_TASKS) return;
    if (cap_slot >= MAX_CAPS_PER_TASK) return;
    cap_tables[task_idx][cap_slot].valid = false;
}

/// Check if a task has a specific capability.
/// Returns true if the task has a valid capability for the endpoint with the required rights.
pub fn checkCapability(task_idx: u32, endpoint: u32, required: CapRights) bool {
    if (task_idx >= task.MAX_TASKS) return false;
    const table = &cap_tables[task_idx];
    for (0..MAX_CAPS_PER_TASK) |i| {
        const cap = table[i];
        if (cap.valid and cap.endpoint == endpoint) {
            // Check all required rights
            if (required.send and !cap.rights.send) continue;
            if (required.receive and !cap.rights.receive) continue;
            if (required.notify and !cap.rights.notify) continue;
            if (required.manage and !cap.rights.manage) continue;
            return true;
        }
    }
    return false;
}

/// Clear all capabilities for a task (used on task destruction).
pub fn clearCapabilities(task_idx: u32) void {
    if (task_idx >= task.MAX_TASKS) return;
    for (0..MAX_CAPS_PER_TASK) |i| {
        cap_tables[task_idx][i].valid = false;
    }
}

/// Initialize the capability system.
pub fn init() void {
    // Tables are zero-initialized (all invalid) already
}
