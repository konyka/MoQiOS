//! Loopback (lo) interface (F2).
//!
//! Frames destined to 127.0.0.0/8 never reach the hardware NIC and never
//! trigger ARP: the TX paths (udp.sendTo, tcp sendSegment) queue the finished
//! L2 frame here, and the next drain feeds it back into net.handleRxPacket,
//! giving local TCP/UDP traffic a full stack round trip.
//!
//! The queue state is a plain struct with an explicit init — no arch deps —
//! so the ring logic is host-unit-testable (see tests/main.zig, block
//! `// ─── loopback (F2) ───`). The kernel-global instance below adds an
//! IrqSpinlock for SMP/IRQ safety on top of that pure core.

const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

/// Frames held between TX and the next drain.
pub const QUEUE_DEPTH: u32 = 16;
/// Room for a full 1500-byte-MTU Ethernet frame with slack.
pub const MAX_FRAME: u32 = 2048;

const FrameSlot = struct {
    len: u32,
    data: [MAX_FRAME]u8,
};

/// Pure ring-buffer state — no locks, no arch deps (host-tested).
pub const LoopbackQueue = struct {
    slots: [QUEUE_DEPTH]FrameSlot,
    head: u32, // next dequeue slot
    tail: u32, // next enqueue slot
    len: u32, // queued frames
    dropped: u64, // TX drops because the queue was full

    pub fn init() LoopbackQueue {
        return .{
            .slots = @splat(.{ .len = 0, .data = @splat(0) }),
            .head = 0,
            .tail = 0,
            .len = 0,
            .dropped = 0,
        };
    }

    pub fn pending(self: *const LoopbackQueue) u32 {
        return self.len;
    }

    /// Queue one frame. Returns false — counting a drop only when the ring is
    /// full — for empty or oversized frames as well.
    pub fn enqueue(self: *LoopbackQueue, frame: []const u8) bool {
        if (frame.len == 0 or frame.len > MAX_FRAME) return false;
        if (self.len == QUEUE_DEPTH) {
            self.dropped += 1;
            return false;
        }
        const slot = &self.slots[self.tail];
        slot.len = @intCast(frame.len);
        @memcpy(slot.data[0..frame.len], frame);
        self.tail = (self.tail + 1) % QUEUE_DEPTH;
        self.len += 1;
        return true;
    }

    /// Pop the oldest frame into `out`; returns its length (0 when empty).
    pub fn dequeue(self: *LoopbackQueue, out: []u8) u32 {
        if (self.len == 0) return 0;
        const slot = &self.slots[self.head];
        const n: u32 = @intCast(@min(slot.len, out.len));
        @memcpy(out[0..n], slot.data[0..n]);
        slot.len = 0;
        self.head = (self.head + 1) % QUEUE_DEPTH;
        self.len -= 1;
        return n;
    }
};

/// Route decision: the entire 127.0.0.0/8 block is loopback (RFC 1122 §3.2.1.3).
pub fn isLoopback(ip: [4]u8) bool {
    return ip[0] == 127;
}

// ─── kernel-global instance ───────────────────────────────────────────────

var rx_queue: LoopbackQueue = LoopbackQueue.init();
// TX (tcp/udp send paths) and drain (netPoll / NIC IRQ bottom half) can run
// on different CPUs and in IRQ context.
var lo_lock: IrqSpinlock = .{};

/// Reset the queue (net.init).
pub fn init() void {
    const saved = lo_lock.acquire();
    defer lo_lock.release(saved);
    rx_queue = LoopbackQueue.init();
}

/// TX entry used by udp/tcp when the destination is 127.0.0.0/8: queue the
/// finished L2 frame for loopback delivery. Mirrors nic.sendPacket's
/// contract — false means the frame was not accepted (queue full).
pub fn sendPacket(data: [*]const u8, len: u32) bool {
    const saved = lo_lock.acquire();
    defer lo_lock.release(saved);
    return rx_queue.enqueue(data[0..len]);
}

/// Deliver queued frames to the RX demux; returns how many were delivered.
/// Called from the RX pump points (netPoll syscalls, e1000 IRQ bottom half).
///
/// The pop runs under lo_lock but handleRxPacket does not: RX processing
/// takes tcp_lock and may re-enter lo.sendPacket (SYN-ACK/ACK emission),
/// which would deadlock on lo_lock. Lock order everywhere is
/// tcp_lock → lo_lock, never the reverse.
pub fn drain() u32 {
    const net_mod = @import("mod.zig");
    var buf: [MAX_FRAME]u8 = undefined;
    var count: u32 = 0;
    // Bound one drain so a TX/RX ping-pong cannot starve the caller;
    // anything left is picked up by the next pump.
    while (count < QUEUE_DEPTH * 4) {
        const saved = lo_lock.acquire();
        const n = rx_queue.dequeue(&buf);
        lo_lock.release(saved);
        if (n == 0) break;
        net_mod.handleRxPacket(&buf, n);
        count += 1;
    }
    return count;
}
