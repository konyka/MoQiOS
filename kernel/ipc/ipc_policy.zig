//! Pure endpoint slot-occupancy policy for the synchronous IPC engine
//! (kernel/ipc/ipc.zig).
//!
//! Each endpoint has exactly one waiting_sender slot, one waiting_receiver
//! slot, and one pending_msg payload slot. The decisions below are shared by
//! the kernel and the host tests so both agree on one state machine:
//!
//!   send:    receiver waiting  → deliver into pending_msg + wake receiver
//!            sender slot busy  → reject (a second registration would
//!                                 overwrite the first sender's message and
//!                                 strand it blocked forever — no timeout
//!                                 is enforced)
//!            otherwise         → register waiting_sender + pending_msg,
//!                                 block
//!   receive: sender waiting    → take pending_msg + wake sender
//!            receiver slot busy → reject (symmetric overwrite)
//!            otherwise         → register waiting_receiver, block
//!   call:    after the caller is resumed, a reply is present iff the
//!            caller endpoint's pending_msg slot is occupied and no
//!            waiting_sender owns the slot; a bare signal kick leaves the
//!            slot empty.
//!
//! Pure module: no kernel imports — host-testable via kernel/host_test.zig.

/// What send() must do with a message for an endpoint.
pub const SendAction = enum {
    /// Receiver already blocked: copy into pending_msg and wake it.
    deliver,
    /// Nobody waiting: register as waiting_sender and block.
    block,
    /// waiting_sender slot occupied: reject — overwriting it would strand
    /// the first sender blocked forever.
    busy,
};

pub fn sendAction(receiver_waiting: bool, sender_waiting: bool) SendAction {
    if (receiver_waiting) return .deliver;
    if (sender_waiting) return .busy;
    return .block;
}

/// What receive() must do on an endpoint.
pub const ReceiveAction = enum {
    /// Sender blocked: take pending_msg and wake it.
    pick_up,
    /// No sender: register as waiting_receiver and block.
    block,
    /// waiting_receiver slot occupied: reject — overwriting it would strand
    /// the first receiver.
    busy,
};

pub fn receiveAction(sender_waiting: bool, receiver_waiting: bool) ReceiveAction {
    if (sender_waiting) return .pick_up;
    if (receiver_waiting) return .busy;
    return .block;
}

/// What the call() wake path found after being resumed.
pub const CallWake = enum {
    /// pending_msg holds the reply: copy it out and clear the slot.
    reply_arrived,
    /// Woken without a reply (signal kick): no payload to hand off.
    signal_kick,
};

/// After a call() caller is resumed, decide whether a reply payload is
/// waiting. reply() parks the reply in the caller endpoint's pending_msg
/// slot, so slot presence discriminates a real reply from a bare signal
/// kick. A registered waiting_sender owns the slot (its blocked message),
/// so the slot must not be taken as a reply in that case.
pub fn callWake(reply_pending: bool, sender_registered: bool) CallWake {
    if (reply_pending and !sender_registered) return .reply_arrived;
    return .signal_kick;
}

/// Take a buffered payload out of a slot, clearing it. Returns null when
/// the slot is empty (nothing to hand off).
pub fn takeSlot(comptime T: type, slot: *?T) ?T {
    const value = slot.* orelse return null;
    slot.* = null;
    return value;
}

/// Test-visible model of one endpoint's slots. Every transition routes
/// through the decision functions above, so host tests exercise the exact
/// policy the kernel applies to its Endpoint fields.
pub const SlotModel = struct {
    waiting_sender: bool = false,
    waiting_receiver: bool = false,
    pending_msg: ?u64 = null,

    /// Mirror of kernel send(): deliver to a waiting receiver, reject a
    /// second sender, otherwise register and block.
    pub fn send(self: *SlotModel, payload: u64) SendAction {
        const action = sendAction(self.waiting_receiver, self.waiting_sender);
        switch (action) {
            .deliver => {
                self.pending_msg = payload;
                self.waiting_receiver = false;
            },
            .busy => {},
            .block => {
                self.waiting_sender = true;
                self.pending_msg = payload;
            },
        }
        return action;
    }

    /// Mirror of kernel receive(): pick up a blocked sender's message,
    /// reject a second receiver, otherwise register and block.
    pub fn receive(self: *SlotModel, out: *?u64) ReceiveAction {
        const action = receiveAction(self.waiting_sender, self.waiting_receiver);
        switch (action) {
            .pick_up => {
                out.* = takeSlot(u64, &self.pending_msg);
                self.waiting_sender = false;
            },
            .busy => {},
            .block => self.waiting_receiver = true,
        }
        return action;
    }

    /// Mirror of a woken receiver picking up the delivered message.
    pub fn takeDelivered(self: *SlotModel) ?u64 {
        return takeSlot(u64, &self.pending_msg);
    }

    /// Mirror of kernel reply(): park the reply in pending_msg.
    pub fn reply(self: *SlotModel, payload: u64) void {
        self.pending_msg = payload;
    }

    /// Mirror of the call() wake path: take the reply iff the slot holds
    /// one, otherwise report a signal kick.
    pub fn callTakeReply(self: *SlotModel, out: *?u64) CallWake {
        const wake = callWake(self.pending_msg != null, self.waiting_sender);
        if (wake == .reply_arrived) {
            out.* = takeSlot(u64, &self.pending_msg);
        }
        return wake;
    }
};
