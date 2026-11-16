//! Frames waiting for an IPv6 next hop's MAC (Linux __neigh_event_send queues them on the neighbour while Neighbor Discovery asks
//! for it; neigh_update sends them once the advertisement comes, and a neighbour that never answers fails and its queue is
//! dropped). The solicitations themselves are ndp.zig's (resolveNextHop marks the entry incomplete, ndp.timerTick repeats them);
//! here a frame is only kept for arp_policy.HOLD_NS and goes out when ndp.update learns its hop's MAC.

const nic = @import("nic.zig");
const policy = @import("arp_policy.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const FRAME_MAX: usize = 1518;
var pending: [policy.MAX_PENDING]policy.Slot6 = @splat(.{});
var pending_frame: [policy.MAX_PENDING][FRAME_MAX]u8 = undefined;
var pending_len: [policy.MAX_PENDING]u32 = @splat(0);
var lock: IrqSpinlock = .{};

fn nowNs() u64 {
    return @import("../arch/arch.zig").tsc.nanos();
}

fn sameAddr(a: [16]u8, b: [16]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Keep the Ethernet frame `frame` (its destination MAC still unset) until `hop` is resolved. A slot whose frame waited longer than
/// HOLD_NS is free again, so a neighbour that never answers drops its frames without a timer.
pub fn queueFrame(hop: [16]u8, frame: [*]const u8, len: u32) void {
    if (len > FRAME_MAX) return;
    const now = nowNs();
    const saved = lock.acquire();
    defer lock.release(saved);
    const i = policy.pickSlot(&pending, now);
    pending[i] = .{ .used = true, .hop = hop, .queued_ns = now };
    @memcpy(pending_frame[i][0..len], frame[0..len]);
    pending_len[i] = len;
}

/// Send the frames waiting for `ip`, now at `mac`.
pub fn flush(ip: [16]u8, mac: [6]u8) void {
    var out: [FRAME_MAX]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        {
            const saved = lock.acquire();
            defer lock.release(saved);
            const now = nowNs();
            for (0..policy.MAX_PENDING) |i| {
                if (!pending[i].used or policy.expired(pending[i], now) or !sameAddr(pending[i].hop, ip)) continue;
                n = pending_len[i];
                @memcpy(out[0..n], pending_frame[i][0..n]);
                pending[i].used = false;
                break;
            }
        }
        if (n == 0) return;
        @memcpy(out[0..6], &mac);
        _ = nic.sendPacket(&out, n);
    }
}
