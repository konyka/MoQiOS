//! IPv4 id state (decisions in ipid_policy.zig): random per-socket starting values and the hashed counters of packets no socket owns.

const policy = @import("ipid_policy.zig");
const ipo = @import("ip_opt_policy.zig");
const random = @import("../drivers/random.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

var lock: IrqSpinlock = .{};
var seeded: bool = false;
var secret: u32 = 0;
var buckets: [policy.BUCKETS]u16 = @splat(0);
var stamps: [policy.BUCKETS]u32 = @splat(0);

fn seedLocked() void {
    if (seeded) return;
    random.init();
    random.getRandomBytes(@ptrCast(&secret), @sizeOf(u32));
    random.getRandomBytes(@ptrCast(&buckets), @sizeOf(@TypeOf(buckets)));
    seeded = true;
}

/// A connected socket's first id (get_random_u16 at TCP connect and accept, and at UDP connect).
pub fn initial() u16 {
    const saved = lock.acquire();
    defer lock.release(saved);
    seedLocked();
    var v: u16 = 0;
    random.getRandomBytes(@ptrCast(&v), @sizeOf(u16));
    return v;
}

/// The id of a packet from `saddr` to `daddr` of `protocol` that no socket numbers (__ip_select_ident).
pub fn global(daddr: [4]u8, saddr: [4]u8, protocol: u8) u16 {
    const saved = lock.acquire();
    defer lock.release(saved);
    seedLocked();
    const b = policy.bucket(daddr, saddr, protocol, secret);
    var rand: u32 = 0;
    random.getRandomBytes(@ptrCast(&rand), @sizeOf(u32));
    const now: u32 = @truncate(@import("../arch/arch.zig").interrupts.getTickCount());
    return policy.reserve(&buckets[b], &stamps[b], now, rand);
}

/// The id of a datagram no connected socket numbers, sent by a socket in IP_MTU_DISCOVER `mode` (0 or a shared counter's value).
pub fn unowned(daddr: [4]u8, saddr: [4]u8, protocol: u8, mode: u8) u16 {
    if (!policy.numbersUnowned(ipo.datagramDf(mode), ipo.ignoreDf(mode))) return 0;
    return global(daddr, saddr, protocol);
}

/// global, but never 0: an IP_HDRINCL header whose id is 0 asked the kernel to choose one, and a chosen 0 would read as unchosen.
pub fn globalNonzero(daddr: [4]u8, saddr: [4]u8, protocol: u8) u16 {
    while (true) {
        const id = global(daddr, saddr, protocol);
        if (id != 0) return id;
    }
}
