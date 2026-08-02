/// TicketSpinlock — fair FIFO spinlock using the ticket algorithm.
/// Guarantees ordering: threads acquire the lock in the order they requested it.
/// IRQs are masked on acquire and restored on release (same contract as
/// IrqSpinlock) so use from IRQ context cannot self-deadlock.
///
/// Usage:
///   const flags = lock.acquire();
///   defer lock.release(flags);
///   // ... critical section ...

const arch = @import("../arch/arch.zig");

pub const TicketSpinlock = struct {
    next_ticket: u32 = 0,
    now_serving: u32 = 0,

    /// Acquire: mask IRQs, atomically get a ticket, spin until now_serving
    /// matches. Returns saved IRQ flags to pass to release().
    pub inline fn acquire(self: *TicketSpinlock) u64 {
        const saved = arch.irq.saveAndDisable();
        const my_ticket = @atomicRmw(u32, &self.next_ticket, .Add, 1, .monotonic);
        while (@atomicLoad(u32, &self.now_serving, .acquire) != my_ticket) {
            arch.cpu.pause();
        }
        return saved;
    }

    /// Release: advance now_serving by 1, restore IRQ flags from acquire().
    pub inline fn release(self: *TicketSpinlock, saved: u64) void {
        _ = @atomicRmw(u32, &self.now_serving, .Add, 1, .release);
        arch.irq.restore(saved);
    }
};
