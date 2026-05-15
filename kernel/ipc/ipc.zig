/// Inter-Process Communication engine — synchronous message passing.
///
/// Design based on MINIX 3 IPC model adapted for MoQiOS:
/// - send:     block until receiver is ready
/// - receive:  block until a message arrives
/// - call:     send + wait for reply (transaction)
/// - reply:    reply to a caller
/// - notify:   async notification (bitmap, no payload)
///
/// Messages are fixed 256 bytes, cache-line aligned.
/// Endpoints are kernel-managed message ports bound to tasks.
///
/// For M4, this operates kernel-to-kernel only. User-space syscall
/// integration comes in M5.

const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const serial = @import("../arch/x86_64/serial.zig");

// --- Deadlock prevention limits ---
const MAX_CALL_DEPTH: u32 = 8; // Maximum nested IPC call chain depth
const IPC_TIMEOUT_MS: u64 = 30000; // 30 second timeout for IPC operations

/// Per-task IPC state for deadlock prevention.
const IpcTaskState = struct {
    call_depth: u32,
    /// Endpoint the task is currently blocked on (for deadlock detection).
    blocked_on: EndpointId,
    /// Timestamp when the task started blocking (for timeout).
    block_start_tick: u64,
};

var task_ipc_state: [task.MAX_TASKS]IpcTaskState = [_]IpcTaskState{
    .{ .call_depth = 0, .blocked_on = 0, .block_start_tick = 0 },
} ** task.MAX_TASKS;

// --- Types ---

/// Endpoint identifier — each service/task gets a unique endpoint.
pub const EndpointId = u32;

pub const INVALID_ENDPOINT: EndpointId = 0;

/// IPC operation type.
pub const IpcOp = enum(u8) {
    send = 0,
    receive = 1,
    call = 2,
    reply = 3,
    notify = 4,
};

/// IPC error codes.
pub const IpcError = enum(i32) {
    success = 0,
    invalid_endpoint = -1,
    not_ready = -2,
    would_deadlock = -3,
    timeout = -4,
    bad_message = -5,
};

/// Notification bitmap — 64 distinct notification types.
pub const NotifyBitmap = u64;

/// IPC message — fixed 256 bytes, cache-line aligned.
/// Layout:
///   [0..8]    sender endpoint
///   [8..16]   reply_to endpoint (for call/reply)
///   [16..20]  message type
///   [20..24]  flags
///   [24..256] payload (232 bytes)
pub const Message = extern struct {
    sender: u64,
    reply_to: u64,
    msg_type: u32,
    flags: u32,
    payload: Payload,
};

comptime {
    if (@sizeOf(Message) != 256) {
        @compileError("IPC Message must be exactly 256 bytes");
    }
}

/// Message payload — 232-byte union for different message types.
pub const Payload = extern union {
    raw: [232]u8,
    small: SmallPayload,
    syscall: SyscallPayload,
    fault: FaultPayload,
    irq: IrqPayload,
};

/// Small payload — simple integer + pointer message.
pub const SmallPayload = extern struct {
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
    arg7: u64,
    arg8: u64,
    arg9: u64,
    arg10: u64,
    arg11: u64,
    arg12: u64,
    arg13: u64,
    arg14: u64,
    arg15: u64,
    arg16: u64,
    arg17: u64,
    arg18: u64,
    arg19: u64,
    arg20: u64,
    arg21: u64,
    arg22: u64,
    arg23: u64,
    arg24: u64,
    arg25: u64,
    arg26: u64,
    arg27: u64,
    arg28: u64,
    arg29: u64,
};

/// Syscall payload — for forwarding system calls via IPC.
pub const SyscallPayload = extern struct {
    syscall_nr: u64,
    arg0: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    ret0: u64,
    ret1: u64,
    pad: [152]u8,
};

/// Fault payload — for page fault and exception forwarding.
pub const FaultPayload = extern struct {
    fault_addr: u64,
    error_code: u64,
    rip: u64,
    flags: u64,
    reserved: [200]u8,
};

/// IRQ payload — for interrupt notifications.
pub const IrqPayload = extern struct {
    irq_number: u32,
    pad0: u32,
    timestamp: u64,
    reserved: [216]u8,
};

// --- Endpoint management ---

pub const MAX_ENDPOINTS: u32 = 128;

const Endpoint = struct {
    owner_task_idx: ?u32,
    /// Task index of a sender waiting for this endpoint to receive (blocked on send).
    waiting_sender: ?u32,
    /// Task index of the owner waiting to receive a message (blocked on receive).
    waiting_receiver: ?u32,
    /// Pending notification bitmap.
    pending_notify: NotifyBitmap,
    /// Buffered message for the waiting receiver.
    pending_msg: ?Message,
    /// Whether this endpoint is in use.
    active: bool,
};

var endpoints: [MAX_ENDPOINTS]Endpoint = [_]Endpoint{
    .{
        .owner_task_idx = null,
        .waiting_sender = null,
        .waiting_receiver = null,
        .pending_notify = 0,
        .pending_msg = null,
        .active = false,
    },
} ** MAX_ENDPOINTS;
var next_endpoint: EndpointId = 1; // 0 is invalid

/// Create a new endpoint bound to the given task.
/// Returns the endpoint ID or null if exhausted.
pub fn createEndpoint(owner_task_idx: u32) ?EndpointId {
    // Verify the task exists
    _ = task.getTask(owner_task_idx) orelse return null;

    // Find a free slot
    for (1..MAX_ENDPOINTS) |i| {
        if (!endpoints[i].active) {
            endpoints[i] = Endpoint{
                .owner_task_idx = owner_task_idx,
                .waiting_sender = null,
                .waiting_receiver = null,
                .pending_notify = 0,
                .pending_msg = null,
                .active = true,
            };
            return @intCast(i);
        }
    }
    return null;
}

/// Destroy an endpoint.
pub fn destroyEndpoint(ep: EndpointId) void {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return;
    // Unblock any tasks waiting on this endpoint
    if (endpoints[ep].waiting_sender) |sender_idx| {
        const t = task.getTask(sender_idx) orelse return;
        t.state = .ready;
    }
    if (endpoints[ep].waiting_receiver) |recv_idx| {
        const t = task.getTask(recv_idx) orelse return;
        t.state = .ready;
    }
    endpoints[ep].active = false;
    endpoints[ep].owner_task_idx = null;
    endpoints[ep].waiting_sender = null;
    endpoints[ep].waiting_receiver = null;
}

/// Get the task index that owns an endpoint.
pub fn getEndpointOwner(ep: EndpointId) ?u32 {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return null;
    if (!endpoints[ep].active) return null;
    return endpoints[ep].owner_task_idx;
}

// --- IPC operations ---

/// Send a message to an endpoint. Blocks until the receiver is ready.
/// For kernel-to-kernel IPC, the sender's task index is determined from the scheduler.
pub fn send(target_ep: EndpointId, msg: *const Message) IpcError {
    if (target_ep == 0 or target_ep >= MAX_ENDPOINTS) return .invalid_endpoint;
    if (!endpoints[target_ep].active) return .invalid_endpoint;

    const sender_idx = sched.currentTaskIndex() orelse return .not_ready;
    const sender_ep = findEndpointForTask(sender_idx) orelse return .not_ready;

    // Check for self-send deadlock
    if (endpoints[target_ep].owner_task_idx) |owner| {
        if (owner == sender_idx) return .would_deadlock;
    }

    // Check for circular wait deadlock
    if (checkCircularWait(sender_idx, target_ep)) return .would_deadlock;

    // Copy message with sender info
    var out_msg: Message = msg.*;
    out_msg.sender = @intCast(sender_ep);

    if (endpoints[target_ep].waiting_receiver) |recv_idx| {
        // Receiver is already waiting — deliver immediately
        const recv_task = task.getTask(recv_idx) orelse return .not_ready;

        // Copy message to receiver's buffer
        if (endpoints[target_ep].pending_msg) |*pending| {
            pending.* = out_msg;
        } else {
            endpoints[target_ep].pending_msg = out_msg;
        }

        // Wake up receiver
        recv_task.state = .ready;
        endpoints[target_ep].waiting_receiver = null;
        task_ipc_state[recv_idx].blocked_on = 0;
    } else {
        // No receiver waiting — block the sender
        const sender_task = task.getTask(sender_idx) orelse return .not_ready;
        endpoints[target_ep].waiting_sender = sender_idx;
        endpoints[target_ep].pending_msg = out_msg;
        sender_task.state = .blocked;
        task_ipc_state[sender_idx].blocked_on = target_ep;
    }

    return .success;
}

/// Receive a message from any sender on this endpoint. Blocks until one arrives.
pub fn receive(ep: EndpointId, buf: *Message) IpcError {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return .invalid_endpoint;
    if (!endpoints[ep].active) return .invalid_endpoint;

    // Verify caller owns this endpoint
    const caller_idx = sched.currentTaskIndex() orelse return .not_ready;
    if (endpoints[ep].owner_task_idx != caller_idx) return .not_ready;

    if (endpoints[ep].waiting_sender) |sender_idx| {
        // Sender is waiting — pick up the message
        if (endpoints[ep].pending_msg) |msg| {
            buf.* = msg;
            endpoints[ep].pending_msg = null;
        }

        // Wake up sender
        const sender_task = task.getTask(sender_idx) orelse return .not_ready;
        sender_task.state = .ready;
        endpoints[ep].waiting_sender = null;
        return .success;
    }

    // No sender waiting — block the receiver
    const recv_task = task.getTask(caller_idx) orelse return .not_ready;
    endpoints[ep].waiting_receiver = caller_idx;
    recv_task.state = .blocked;
    // Receiver will be descheduled on next tick

    // When sender arrives later, the message will be written to this buf.
    // For simplicity in kernel-kernel IPC, we'll use a different approach:
    // the receiver spins on a flag. This is OK for kernel threads.
    // TODO: proper event-based blocking for user-space
    return .success;
}

/// Call = send + wait for reply. Transactional IPC.
/// The caller sends a message and blocks until the callee replies.
/// Enforces maximum call depth to prevent stack overflow via IPC chains.
pub fn call(target_ep: EndpointId, msg: *Message) IpcError {
    // Check call depth
    const caller_idx = sched.currentTaskIndex() orelse return .not_ready;
    if (task_ipc_state[caller_idx].call_depth >= MAX_CALL_DEPTH) {
        return .would_deadlock;
    }

    const caller_ep = findEndpointForTask(caller_idx) orelse return .not_ready;

    msg.reply_to = @intCast(caller_ep);

    // Increment call depth
    task_ipc_state[caller_idx].call_depth += 1;

    // Send the message
    const send_result = send(target_ep, msg);
    if (send_result != .success) {
        task_ipc_state[caller_idx].call_depth -= 1;
        return send_result;
    }

    // Block caller until reply arrives
    const caller_task = task.getTask(caller_idx) orelse return .not_ready;
    caller_task.state = .blocked;
    task_ipc_state[caller_idx].blocked_on = target_ep;

    return .success;
}

/// Reply to a caller — sends the reply message back.
/// Decrements the caller's IPC call depth.
pub fn reply(caller_ep: EndpointId, reply_msg: *const Message) IpcError {
    if (caller_ep == 0 or caller_ep >= MAX_ENDPOINTS) return .invalid_endpoint;
    if (!endpoints[caller_ep].active) return .invalid_endpoint;

    // Unblock the caller
    if (endpoints[caller_ep].owner_task_idx) |owner_idx| {
        const owner_task = task.getTask(owner_idx) orelse return .not_ready;
        owner_task.state = .ready;

        // Decrement call depth
        if (task_ipc_state[owner_idx].call_depth > 0) {
            task_ipc_state[owner_idx].call_depth -= 1;
        }
        task_ipc_state[owner_idx].blocked_on = 0;

        // Store reply message
        endpoints[caller_ep].pending_msg = reply_msg.*;
    }

    return .success;
}

/// Notify an endpoint — async, non-blocking. Sets bits in the notification bitmap.
pub fn notify(target_ep: EndpointId, bits: NotifyBitmap) IpcError {
    if (target_ep == 0 or target_ep >= MAX_ENDPOINTS) return .invalid_endpoint;
    if (!endpoints[target_ep].active) return .invalid_endpoint;

    endpoints[target_ep].pending_notify |= bits;

    // If receiver is blocked on this endpoint, wake it
    if (endpoints[target_ep].waiting_receiver) |recv_idx| {
        const recv_task = task.getTask(recv_idx) orelse return .not_ready;
        recv_task.state = .ready;
        endpoints[target_ep].waiting_receiver = null;
    }

    return .success;
}

/// Get pending notifications and clear them.
pub fn getNotify(ep: EndpointId) NotifyBitmap {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return 0;
    const bits = endpoints[ep].pending_notify;
    endpoints[ep].pending_notify = 0;
    return bits;
}

// --- Helpers ---

/// Find the endpoint owned by a task (first match).
fn findEndpointForTask(task_idx: u32) ?EndpointId {
    for (1..MAX_ENDPOINTS) |i| {
        if (endpoints[i].active and endpoints[i].owner_task_idx == task_idx) {
            return @intCast(i);
        }
    }
    return null;
}

/// Check for circular wait in IPC chain.
/// Follows the chain: sender → target_ep's owner → that owner's blocked_on → ...
/// If we find a cycle back to sender, it's a deadlock.
fn checkCircularWait(sender_idx: u32, target_ep: EndpointId) bool {
    // Get the owner of the target endpoint
    const first_owner = endpoints[target_ep].owner_task_idx orelse return false;
    if (first_owner == sender_idx) return true; // Self-deadlock (should be caught earlier)

    // Follow the chain
    var current = first_owner;
    var depth: u32 = 0;
    while (depth < MAX_CALL_DEPTH) : (depth += 1) {
        const blocked_ep = task_ipc_state[current].blocked_on;
        if (blocked_ep == 0) return false; // Not blocked — no cycle
        if (blocked_ep >= MAX_ENDPOINTS) return false;

        const next_owner = endpoints[blocked_ep].owner_task_idx orelse return false;
        if (next_owner == sender_idx) return true; // Cycle detected!
        current = next_owner;
    }
    return false; // Chain too long but no cycle
}

/// Initialize the IPC subsystem.
pub fn init() void {
    // Endpoints and task state are zero-initialized already (all inactive)
}
