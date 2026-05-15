/// TicketSpinlock — fair FIFO spinlock using the ticket algorithm.
/// Guarantees ordering: threads acquire the lock in the order they requested it.
///
/// Usage:
///   lock.acquire();
///   defer lock.release();
///   // ... critical section ...

pub const TicketSpinlock = struct {
    next_ticket: u32 = 0,
    now_serving: u32 = 0,

    /// Acquire: atomically get a ticket, spin until now_serving matches.
    pub inline fn acquire(self: *TicketSpinlock) void {
        const my_ticket = @atomicRmw(u32, &self.next_ticket, .Add, 1, .monotonic);
        while (@atomicLoad(u32, &self.now_serving, .acquire) != my_ticket) {
            asm volatile ("pause");
        }
    }

    /// Release: advance now_serving by 1.
    pub inline fn release(self: *TicketSpinlock) void {
        _ = @atomicRmw(u32, &self.now_serving, .Add, 1, .release);
    }
};
