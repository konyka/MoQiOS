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
const ipc_policy = @import("ipc_policy.zig");
const serial = @import("../arch/arch.zig").serial;
const authority = @import("ipc_authority.zig");
const ipc_lock = authority;
const capability = @import("capability.zig");

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
    wake_error: IpcError,
};

var task_ipc_state: [task.MAX_TASKS]IpcTaskState = [_]IpcTaskState{
    .{ .call_depth = 0, .blocked_on = 0, .block_start_tick = 0, .wake_error = .success },
} ** task.MAX_TASKS;

// --- Types ---

/// Endpoint identifier — each service/task gets a unique endpoint.
pub const EndpointId = u32;

pub const INVALID_ENDPOINT: EndpointId = 0;

pub const CapabilityGrantError = enum(i64) {
    invalid = -22,
    permission = -1,
    no_memory = -12,
    no_process = -3,
};

var next_call_token: u64 = 1;

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
var endpoint_generations: [MAX_ENDPOINTS]u64 = @splat(0);

const Endpoint = struct {
    owner_task_idx: ?u32,
    owner_tid: ?u32,
    /// Task index of a sender waiting for this endpoint to receive (blocked on send).
    waiting_sender: ?u32,
    /// Task index of the owner waiting to receive a message (blocked on receive).
    waiting_receiver: ?u32,
    /// Task allowed to complete the outstanding call for this endpoint.
    reply_callee_task_idx: ?u32,
    reply_callee_tid: ?u32,
    reply_token: u64,
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
        .owner_tid = null,
        .waiting_sender = null,
        .waiting_receiver = null,
        .reply_callee_task_idx = null,
        .reply_callee_tid = null,
        .reply_token = 0,
        .pending_notify = 0,
        .pending_msg = null,
        .active = false,
    },
} ** MAX_ENDPOINTS;
var next_endpoint: EndpointId = 1; // 0 is invalid

/// Create a new endpoint bound to the given task.
/// Returns the endpoint ID or null if exhausted.
pub fn createEndpoint(owner_task_idx: u32) ?EndpointId {
    const flags = authority.acquire();
    const task_flags = task.acquireIpcTaskLock();
    defer task.releaseIpcTaskLock(task_flags);
    defer authority.release(flags);
    const owner = task.getTask(owner_task_idx) orelse return null;

    // Find a free slot
    for (1..MAX_ENDPOINTS) |i| {
        if (!endpoints[i].active) {
            endpoint_generations[i] +%= 1;
            if (endpoint_generations[i] == 0) endpoint_generations[i] = 1;
            endpoints[i] = Endpoint{
                .owner_task_idx = owner_task_idx,
                .owner_tid = owner.tid,
                .waiting_sender = null,
                .waiting_receiver = null,
                .reply_callee_task_idx = null,
                .reply_callee_tid = null,
                .reply_token = 0,
                .pending_notify = 0,
                .pending_msg = null,
                .active = true,
            };
            return @intCast(i);
        }
    }
    return null;
}

pub fn getEndpointGeneration(ep: EndpointId) ?u64 {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return null;
    const flags = ipc_lock.acquire();
    defer ipc_lock.release(flags);
    if (!endpoints[ep].active) return null;
    return endpoint_generations[ep];
}

/// Destroy an endpoint.
pub fn destroyEndpoint(ep: EndpointId, caller_task_idx: u32) bool {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return false;
    const flags = ipc_lock.acquire();
    if (!@import("ipc_endpoint_policy.zig").canDestroy(endpoints[ep].owner_task_idx, caller_task_idx)) {
        ipc_lock.release(flags);
        return false;
    }

    var sender_to_wake: ?u32 = null;
    var receiver_to_wake: ?u32 = null;

    // Unblock any tasks waiting on this endpoint (unblockTask also
    // re-enqueues them — a bare state = .ready starves the task)
    if (endpoints[ep].waiting_sender) |sender_idx| {
        task_ipc_state[sender_idx].wake_error = .invalid_endpoint;
        task_ipc_state[sender_idx].blocked_on = 0;
        sender_to_wake = sender_idx;
    }
    if (endpoints[ep].waiting_receiver) |recv_idx| {
        task_ipc_state[recv_idx].wake_error = .invalid_endpoint;
        task_ipc_state[recv_idx].blocked_on = 0;
        receiver_to_wake = recv_idx;
    }
    endpoints[ep].active = false;
    endpoints[ep].owner_task_idx = null;
    endpoints[ep].owner_tid = null;
    endpoints[ep].waiting_sender = null;
    endpoints[ep].waiting_receiver = null;
    endpoints[ep].reply_callee_task_idx = null;
    endpoints[ep].reply_callee_tid = null;
    endpoints[ep].reply_token = 0;
    endpoints[ep].pending_msg = null;
    endpoints[ep].pending_notify = 0;
    ipc_lock.release(flags);

    if (sender_to_wake) |idx| task.unblockTask(idx);
    if (receiver_to_wake) |idx| task.unblockTask(idx);
    return true;
}

/// Destroy every endpoint owned by an exiting task before its slot can be reused.
pub fn clearEndpointsForTask(task_idx: u32) void {
    var waiters: [MAX_ENDPOINTS * 3]?u32 = @splat(null);
    var waiter_count: usize = 0;
    const flags = ipc_lock.acquire();
    for (1..MAX_ENDPOINTS) |i| {
        if (endpoints[i].active and endpoints[i].owner_task_idx == task_idx) {
            if (endpoints[i].waiting_sender) |idx| {
                task_ipc_state[idx].wake_error = .invalid_endpoint;
                task_ipc_state[idx].blocked_on = 0;
                waiters[waiter_count] = idx;
                waiter_count += 1;
            }
            if (endpoints[i].waiting_receiver) |idx| {
                task_ipc_state[idx].wake_error = .invalid_endpoint;
                task_ipc_state[idx].blocked_on = 0;
                waiters[waiter_count] = idx;
                waiter_count += 1;
            }
            endpoints[i].active = false;
            endpoints[i].owner_task_idx = null;
            endpoints[i].owner_tid = null;
            endpoints[i].waiting_sender = null;
            endpoints[i].waiting_receiver = null;
            endpoints[i].reply_callee_task_idx = null;
            endpoints[i].reply_callee_tid = null;
            endpoints[i].reply_token = 0;
            endpoints[i].pending_msg = null;
            endpoints[i].pending_notify = 0;
        }
    }
    // Remove this task from waiters owned by other tasks. Otherwise a reused
    // task slot can inherit a stale sender registration and message.
    for (1..MAX_ENDPOINTS) |i| {
        if (!endpoints[i].active) continue;
        if (endpoints[i].waiting_sender == task_idx) {
            endpoints[i].waiting_sender = null;
            endpoints[i].pending_msg = null;
        }
        if (endpoints[i].waiting_receiver == task_idx) {
            endpoints[i].waiting_receiver = null;
        }
        if (endpoints[i].reply_callee_task_idx == task_idx) {
            endpoints[i].reply_callee_task_idx = null;
            endpoints[i].reply_callee_tid = null;
            endpoints[i].reply_token = 0;
            if (endpoints[i].owner_task_idx) |caller_idx| {
                task_ipc_state[caller_idx].wake_error = .invalid_endpoint;
                task_ipc_state[caller_idx].blocked_on = 0;
                waiters[waiter_count] = caller_idx;
                waiter_count += 1;
            }
        }
    }
    task_ipc_state[task_idx] = .{
        .call_depth = 0,
        .blocked_on = 0,
        .block_start_tick = 0,
        .wake_error = .success,
    };
    capability.clearCapabilitiesLocked(task_idx);
    ipc_lock.release(flags);
    for (waiters[0..waiter_count]) |idx| {
        if (idx) |task_idx_to_wake| task.unblockTask(task_idx_to_wake);
    }
}

/// Get the task index that owns an endpoint.
pub fn getEndpointOwner(ep: EndpointId) ?u32 {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return null;
    const flags = ipc_lock.acquire();
    defer ipc_lock.release(flags);
    if (!endpoints[ep].active) return null;
    return endpoints[ep].owner_task_idx;
}

/// Atomically authorize an owner and grant a capability to a live TID.
/// The authority lock serializes endpoint reuse, capability mutation, and
/// task-exit cleanup; task_lock is acquired only after authority.
pub fn grantCapabilityToTid(caller: u32, recipient_tid: u32, ep: EndpointId, rights: capability.CapRights) i64 {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return @intFromEnum(CapabilityGrantError.invalid);
    const flags = authority.acquire();
    defer authority.release(flags);
    const task_flags = task.acquireIpcTaskLock();
    defer task.releaseIpcTaskLock(task_flags);
    const caller_task = task.getTask(caller) orelse return @intFromEnum(CapabilityGrantError.permission);
    if (!endpoints[ep].active or endpoints[ep].owner_task_idx != caller or endpoints[ep].owner_tid != caller_task.tid) return @intFromEnum(CapabilityGrantError.permission);
    const recipient = task.findTaskByTidLocked(recipient_tid) orelse return @intFromEnum(CapabilityGrantError.no_process);
    if (recipient_tid == caller_task.tid) return @intFromEnum(CapabilityGrantError.invalid);
    const slot = capability.grantCapabilityLocked(recipient, ep, endpoint_generations[ep], rights) orelse
        return @intFromEnum(CapabilityGrantError.no_memory);
    return @intCast(slot);
}

pub fn grantCapabilityAuthorized(caller: u32, recipient: u32, ep: EndpointId, rights: capability.CapRights) i64 {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return @intFromEnum(CapabilityGrantError.invalid);
    const flags = authority.acquire();
    defer authority.release(flags);
    const task_flags = task.acquireIpcTaskLock();
    defer task.releaseIpcTaskLock(task_flags);
    const caller_task = task.getTask(caller) orelse return @intFromEnum(CapabilityGrantError.permission);
    if (!endpoints[ep].active or endpoints[ep].owner_task_idx != caller or endpoints[ep].owner_tid != caller_task.tid) return @intFromEnum(CapabilityGrantError.permission);
    if (recipient >= task.MAX_TASKS or task.getTask(recipient) == null) return @intFromEnum(CapabilityGrantError.no_process);
    const slot = capability.grantCapabilityLocked(recipient, ep, endpoint_generations[ep], rights) orelse
        return @intFromEnum(CapabilityGrantError.no_memory);
    return @intCast(slot);
}

pub fn checkCapabilityAuthorized(caller: u32, ep: EndpointId, required: capability.CapRights) bool {
    const flags = authority.acquire();
    defer authority.release(flags);
    return authorizeLocked(caller, ep, required);
}

// --- IPC operations ---

fn capabilityRequired(send_right: bool, receive_right: bool, notify_right: bool) capability.CapRights {
    return .{ .send = send_right, .receive = receive_right, .notify = notify_right, .manage = false };
}

fn authorizeLocked(caller: u32, ep: EndpointId, required: capability.CapRights) bool {
    if (ep == 0 or ep >= MAX_ENDPOINTS or !endpoints[ep].active) return false;
    return capability.checkCapabilityLocked(caller, ep, endpoint_generations[ep], required);
}

/// Send a message to an endpoint. Blocks until the receiver is ready.
/// For kernel-to-kernel IPC, the sender's task index is determined from the scheduler.
pub fn send(target_ep: EndpointId, msg: *const Message) IpcError {
    const sender_idx = sched.currentTaskIndex() orelse return .not_ready;
    return sendInternal(sender_idx, target_ep, msg, false);
}

/// Send after atomically validating the caller's current endpoint generation
/// and send capability under the same authority lock used by `send`.
pub fn sendAuthorized(caller: u32, target_ep: EndpointId, msg: *const Message) IpcError {
    return sendInternal(caller, target_ep, msg, true);
}

fn sendInternal(sender_idx: u32, target_ep: EndpointId, msg: *const Message, require_cap: bool) IpcError {
    if (target_ep == 0 or target_ep >= MAX_ENDPOINTS) return .invalid_endpoint;

    // v53.44: SMP-safe endpoint access
    const flags = ipc_lock.acquire();

    if (!endpoints[target_ep].active) {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }
    if (require_cap and !authorizeLocked(sender_idx, target_ep, capabilityRequired(true, false, false))) {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }
    const sender_ep = findEndpointForTask(sender_idx) orelse {
        ipc_lock.release(flags);
        return .not_ready;
    };

    // Check for self-send deadlock
    if (endpoints[target_ep].owner_task_idx) |owner| {
        if (owner == sender_idx) {
            ipc_lock.release(flags);
            return .would_deadlock;
        }
    }

    // Check for circular wait deadlock
    if (checkCircularWait(sender_idx, target_ep)) {
        ipc_lock.release(flags);
        return .would_deadlock;
    }

    // Copy message with sender info
    var out_msg: Message = msg.*;
    out_msg.sender = @intCast(sender_ep);

    // Single waiting_sender slot: registering a second blocked sender would
    // overwrite the first sender's registration and message, stranding it
    // .blocked forever (IPC_TIMEOUT_MS is never enforced). Reject instead.
    if (ipc_policy.sendAction(endpoints[target_ep].waiting_receiver != null, endpoints[target_ep].waiting_sender != null) == .busy) {
        ipc_lock.release(flags);
        return .not_ready;
    }

    if (endpoints[target_ep].waiting_receiver) |recv_idx| {
        // Receiver is already waiting — deliver immediately
        _ = task.getTask(recv_idx) orelse {
            ipc_lock.release(flags);
            return .not_ready;
        };

        endpoints[target_ep].pending_msg = out_msg;

        endpoints[target_ep].waiting_receiver = null;
        task_ipc_state[recv_idx].blocked_on = 0;
        ipc_lock.release(flags);
        // Re-enqueue only after releasing authority; unblockTask takes the
        // task lock and must not participate in an authority/task lock cycle.
        task.unblockTask(recv_idx);
        return .success;
    }

    // No receiver waiting — block the sender
    const sender_task = task.getTask(sender_idx) orelse {
        ipc_lock.release(flags);
        return .not_ready;
    };
    endpoints[target_ep].waiting_sender = sender_idx;
    endpoints[target_ep].pending_msg = out_msg;
    sender_task.state = .blocked;
    task_ipc_state[sender_idx].blocked_on = target_ep;
    task_ipc_state[sender_idx].wake_error = .success;
    ipc_lock.release(flags);

    // Actually yield the CPU — marking the task .blocked without rescheduling
    // leaves a running task flagged blocked. Lock must be released first
    // (same pattern as receive()).
    sched.forceReschedule();
    sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）

    const wake_error = task_ipc_state[sender_idx].wake_error;
    task_ipc_state[sender_idx].wake_error = .success;
    task_ipc_state[sender_idx].blocked_on = 0;
    if (wake_error != .success) return wake_error;

    // The message is already queued, so delivery is guaranteed regardless —
    // but a fatal signal must still kill the sender, and an actionable one
    // reports EINTR. (.timeout is -4 == -EINTR.)
    const sig_mod = @import("../proc/signal.zig");
    if (sig_mod.pendingFatal(sender_task)) |sig| task.exitTask(128 + @as(i32, @intCast(sig)));
    if (sig_mod.pendingActionable(sender_task)) return .timeout;
    return .success;
}

/// Receive a message from any sender on this endpoint. Blocks until one arrives.
pub fn receive(ep: EndpointId, buf: *Message) IpcError {
    const caller_idx = sched.currentTaskIndex() orelse return .not_ready;
    return receiveInternal(caller_idx, ep, buf, false);
}

pub fn receiveAuthorized(caller: u32, ep: EndpointId, buf: *Message) IpcError {
    return receiveInternal(caller, ep, buf, true);
}

fn receiveInternal(caller_idx: u32, ep: EndpointId, buf: *Message, require_cap: bool) IpcError {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return .invalid_endpoint;

    // v53.44: SMP-safe endpoint access
    const flags = ipc_lock.acquire();

    if (!endpoints[ep].active) {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }
    if (endpoints[ep].owner_task_idx != caller_idx and
        (!require_cap or !capability.checkCapabilityLocked(caller_idx, ep, endpoint_generations[ep], capabilityRequired(false, true, false))))
    {
        ipc_lock.release(flags);
        return .not_ready;
    }

    // Single waiting_receiver slot: a second blocked receiver would
    // overwrite the first one's registration. Reject symmetrically.
    if (ipc_policy.receiveAction(endpoints[ep].waiting_sender != null, endpoints[ep].waiting_receiver != null) == .busy) {
        ipc_lock.release(flags);
        return .not_ready;
    }

    if (endpoints[ep].waiting_sender) |sender_idx| {
        // Sender is waiting — pick up the message
        if (endpoints[ep].pending_msg) |msg| {
            buf.* = msg;
            endpoints[ep].pending_msg = null;
        }

        _ = task.getTask(sender_idx) orelse {
            ipc_lock.release(flags);
            return .not_ready;
        };
        endpoints[ep].waiting_sender = null;
        task_ipc_state[sender_idx].blocked_on = 0;
        ipc_lock.release(flags);
        task.unblockTask(sender_idx);
        return .success;
    }

    // No sender waiting — block the receiver until a sender arrives
    const recv_task = task.getTask(caller_idx) orelse {
        ipc_lock.release(flags);
        return .not_ready;
    };
    endpoints[ep].waiting_receiver = caller_idx;
    recv_task.state = .blocked;
    task_ipc_state[caller_idx].blocked_on = ep;
    task_ipc_state[caller_idx].wake_error = .success;
    ipc_lock.release(flags);

    // Force context switch — must release lock first to avoid deadlock
    sched.forceReschedule();
    sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）

    // Resumed after send() delivered the message and unblocked us
    const flags2 = ipc_lock.acquire();
    const wake_error = task_ipc_state[caller_idx].wake_error;
    task_ipc_state[caller_idx].wake_error = .success;
    if (endpoints[ep].pending_msg) |msg| {
        buf.* = msg;
        endpoints[ep].pending_msg = null;
        task_ipc_state[caller_idx].blocked_on = 0;
        ipc_lock.release(flags2);
        return .success;
    }
    // Woken without a message (signal kick or endpoint teardown): drop our
    // receiver registration so a later send() does not deliver to a task
    // that is no longer waiting.
    if (endpoints[ep].waiting_receiver == caller_idx) {
        endpoints[ep].waiting_receiver = null;
    }
    task_ipc_state[caller_idx].blocked_on = 0;
    ipc_lock.release(flags2);
    if (wake_error != .success) return wake_error;
    // Signal kick (sendSignal unblocks without delivering): die on a fatal
    // signal via the same exit-by-signal path the timer tick uses, or report
    // EINTR so the handler can run on return. (.timeout is -4 == -EINTR.)
    const sig_mod = @import("../proc/signal.zig");
    if (sig_mod.pendingFatal(recv_task)) |sig| task.exitTask(128 + @as(i32, @intCast(sig)));
    if (sig_mod.pendingActionable(recv_task)) return .timeout;
    return .not_ready;
}

/// Call = send + wait for reply. Transactional IPC.
/// The caller sends a message and blocks until the callee replies.
/// Enforces maximum call depth to prevent stack overflow via IPC chains.
pub fn call(target_ep: EndpointId, msg: *Message) IpcError {
    const caller_idx = sched.currentTaskIndex() orelse return .not_ready;
    return callInternal(caller_idx, target_ep, msg, false);
}

pub fn callAuthorized(caller: u32, target_ep: EndpointId, msg: *Message) IpcError {
    return callInternal(caller, target_ep, msg, true);
}

fn callInternal(caller_idx: u32, target_ep: EndpointId, msg: *Message, require_cap: bool) IpcError {
    if (target_ep == 0 or target_ep >= MAX_ENDPOINTS) return .invalid_endpoint;
    const flags = ipc_lock.acquire();
    if (task_ipc_state[caller_idx].call_depth >= MAX_CALL_DEPTH) {
        ipc_lock.release(flags);
        return .would_deadlock;
    }
    const caller_ep = findEndpointForTask(caller_idx) orelse {
        ipc_lock.release(flags);
        return .not_ready;
    };
    if (!endpoints[target_ep].active) {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }
    if (require_cap and !authorizeLocked(caller_idx, target_ep, capabilityRequired(true, false, false))) {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }
    const callee_idx = endpoints[target_ep].owner_task_idx orelse {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    };
    const callee = task.getTask(callee_idx) orelse {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    };
    const token = next_call_token;
    next_call_token +%= 1;
    if (next_call_token == 0) next_call_token = 1;
    const original_reply_to = msg.reply_to;
    msg.reply_to = token;
    endpoints[caller_ep].reply_callee_task_idx = endpoints[target_ep].owner_task_idx;
    endpoints[caller_ep].reply_callee_tid = callee.tid;
    endpoints[caller_ep].reply_token = token;
    task_ipc_state[caller_idx].call_depth += 1;
    ipc_lock.release(flags);

    // Send the message
    const send_result = sendInternal(caller_idx, target_ep, msg, require_cap);
    if (send_result != .success) {
        const rollback_flags = ipc_lock.acquire();
        endpoints[caller_ep].reply_callee_task_idx = null;
        task_ipc_state[caller_idx].call_depth -= 1;
        ipc_lock.release(rollback_flags);
        msg.reply_to = original_reply_to;
        return send_result;
    }

    // Block caller until reply arrives
    const post_send_flags = ipc_lock.acquire();
    const pending_reply = endpoints[caller_ep].pending_msg != null;
    if (pending_reply) {
        msg.* = endpoints[caller_ep].pending_msg.?;
        endpoints[caller_ep].pending_msg = null;
        endpoints[caller_ep].reply_callee_task_idx = null;
        endpoints[caller_ep].reply_callee_tid = null;
        endpoints[caller_ep].reply_token = 0;
        if (task_ipc_state[caller_idx].call_depth > 0) task_ipc_state[caller_idx].call_depth -= 1;
        ipc_lock.release(post_send_flags);
        return .success;
    }
    const caller_task = task.getTask(caller_idx) orelse {
        endpoints[caller_ep].reply_callee_task_idx = null;
        endpoints[caller_ep].reply_callee_tid = null;
        endpoints[caller_ep].reply_token = 0;
        task_ipc_state[caller_idx].call_depth -= 1;
        ipc_lock.release(post_send_flags);
        return .not_ready;
    };
    caller_task.state = .blocked;
    task_ipc_state[caller_idx].blocked_on = target_ep;
    ipc_lock.release(post_send_flags);

    // Actually yield the CPU — marking the task .blocked without rescheduling
    // leaves a running task flagged blocked. No lock is held here.
    sched.forceReschedule();
    sched.repairCurrentAfterBlock(); // 阻塞后状态修复（yield 未切换情形）

    // Woken by reply() or by a signal kick. A fatal signal kills the caller
    // either way (same as before). (.timeout is -4 == -EINTR.)
    const sig_mod = @import("../proc/signal.zig");
    const flags3 = ipc_lock.acquire();
    task_ipc_state[caller_idx].blocked_on = 0;
    const wake_error = task_ipc_state[caller_idx].wake_error;
    task_ipc_state[caller_idx].wake_error = .success;
    if (wake_error != .success and task_ipc_state[caller_idx].call_depth > 0) {
        task_ipc_state[caller_idx].call_depth -= 1;
    }
    ipc_lock.release(flags3);
    if (sig_mod.pendingFatal(caller_task)) |sig| task.exitTask(128 + @as(i32, @intCast(sig)));

    // Reply payload handoff: reply() parked the reply in our endpoint's
    // pending_msg slot. Slot presence (with no waiting_sender owning the
    // slot) discriminates a real reply from a bare signal kick — copy the
    // reply into the caller's buffer and clear the slot so a later
    // receive() cannot consume it out of context.
    const flags2 = ipc_lock.acquire();
    var reply_msg: ?Message = null;
    if (ipc_policy.callWake(endpoints[caller_ep].pending_msg != null, endpoints[caller_ep].waiting_sender != null) == .reply_arrived) {
        reply_msg = ipc_policy.takeSlot(Message, &endpoints[caller_ep].pending_msg);
    }
    ipc_lock.release(flags2);

    if (reply_msg) |m| {
        msg.* = m;
        return .success;
    }
    if (wake_error != .success) return wake_error;

    // Signal kick without a reply: an actionable signal reports EINTR so
    // the handler can run on return; anything else is a spurious wake
    // (mirrors receive()'s woken-without-message tail).
    if (sig_mod.pendingActionable(caller_task)) {
        if (task_ipc_state[caller_idx].call_depth > 0) task_ipc_state[caller_idx].call_depth -= 1;
        return .timeout;
    }
    if (task_ipc_state[caller_idx].call_depth > 0) task_ipc_state[caller_idx].call_depth -= 1;
    return .not_ready;
}

/// Reply to a caller — sends the reply message back.
/// Decrements the caller's IPC call depth.
pub fn reply(caller_ep: EndpointId, reply_msg: *const Message) IpcError {
    _ = caller_ep;
    return replyToken(reply_msg.reply_to, reply_msg);
}

fn replyToken(token: u64, reply_msg: *const Message) IpcError {
    if (token == 0) return .invalid_endpoint;

    // v53.44: SMP-safe endpoint access
    const flags = ipc_lock.acquire();

    var caller_ep: ?EndpointId = null;
    for (1..MAX_ENDPOINTS) |i| {
        if (endpoints[i].active and endpoints[i].reply_token == token) {
            caller_ep = @intCast(i);
            break;
        }
    }
    const caller_endpoint = caller_ep orelse {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    };

    // Unblock the caller
    const callee_idx = sched.currentTaskIndex() orelse {
        ipc_lock.release(flags);
        return .not_ready;
    };
    const callee_task = task.getTask(callee_idx) orelse {
        ipc_lock.release(flags);
        return .not_ready;
    };
    if (endpoints[caller_endpoint].reply_callee_task_idx != callee_idx or
        endpoints[caller_endpoint].reply_callee_tid != callee_task.tid)
    {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }
    if (endpoints[caller_endpoint].owner_task_idx) |owner_idx| {
        _ = task.getTask(owner_idx) orelse {
            ipc_lock.release(flags);
            return .not_ready;
        };
        // Decrement call depth
        if (task_ipc_state[owner_idx].call_depth > 0) {
            task_ipc_state[owner_idx].call_depth -= 1;
        }
        task_ipc_state[owner_idx].blocked_on = 0;

        // Store reply message
        endpoints[caller_endpoint].pending_msg = reply_msg.*;
        endpoints[caller_endpoint].reply_callee_task_idx = null;
        endpoints[caller_endpoint].reply_callee_tid = null;
        endpoints[caller_endpoint].reply_token = 0;
        ipc_lock.release(flags);
        task.unblockTask(owner_idx);
        return .success;
    }
    ipc_lock.release(flags);
    return .success;
}

/// Notify an endpoint — async, non-blocking. Sets bits in the notification bitmap.
pub fn notify(target_ep: EndpointId, bits: NotifyBitmap) IpcError {
    const caller = sched.currentTaskIndex() orelse return .not_ready;
    return notifyInternal(caller, target_ep, bits, false);
}

pub fn notifyAuthorized(caller: u32, target_ep: EndpointId, bits: NotifyBitmap) IpcError {
    return notifyInternal(caller, target_ep, bits, true);
}

fn notifyInternal(caller: u32, target_ep: EndpointId, bits: NotifyBitmap, require_cap: bool) IpcError {
    if (target_ep == 0 or target_ep >= MAX_ENDPOINTS) return .invalid_endpoint;

    // v53.44: SMP-safe endpoint access
    const flags = ipc_lock.acquire();

    if (!endpoints[target_ep].active) {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }
    if (require_cap and !authorizeLocked(caller, target_ep, capabilityRequired(false, false, true))) {
        ipc_lock.release(flags);
        return .invalid_endpoint;
    }

    endpoints[target_ep].pending_notify |= bits;

    // If receiver is blocked on this endpoint, wake it
    if (endpoints[target_ep].waiting_receiver) |recv_idx| {
        _ = task.getTask(recv_idx) orelse {
            ipc_lock.release(flags);
            return .not_ready;
        };
        endpoints[target_ep].waiting_receiver = null;
        task_ipc_state[recv_idx].blocked_on = 0;
        ipc_lock.release(flags);
        task.unblockTask(recv_idx);
        return .success;
    }
    ipc_lock.release(flags);
    return .success;
}

/// Get pending notifications and clear them.
pub fn getNotify(ep: EndpointId) NotifyBitmap {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return 0;
    // v53.44: SMP-safe notification read
    const flags = ipc_lock.acquire();
    defer ipc_lock.release(flags);
    const bits = endpoints[ep].pending_notify;
    endpoints[ep].pending_notify = 0;
    return bits;
}

pub fn getNotifyAuthorized(caller: u32, ep: EndpointId) ?NotifyBitmap {
    if (ep == 0 or ep >= MAX_ENDPOINTS) return null;
    const flags = ipc_lock.acquire();
    defer ipc_lock.release(flags);
    if (!endpoints[ep].active) return null;
    const owner_ok = endpoints[ep].owner_task_idx == caller;
    if (!owner_ok and !authorizeLocked(caller, ep, capabilityRequired(false, false, true))) return null;
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
