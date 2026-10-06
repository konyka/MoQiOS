/// IrqSpinlock — interrupt-safe fair spinlock (SK-4: arch-neutral IRQ masking).
/// Saves interrupt-enable state on acquire, disables IRQs, then waits for its
/// ticket (sync/ticket_lock.zig): waiters are served strictly FIFO, so the
/// worst-case acquisition latency is bounded by the holders queued in front
/// instead of being unbounded test-and-set starvation.
/// Restores prior interrupt state on release.
///
/// IRQs are masked BEFORE the ticket is taken, so an interrupt on the same
/// CPU can never queue behind its own interrupted holder.
///
/// Usage:
///   const flags = lock.acquire();
///   defer lock.release(flags);
///   // ... critical section ...

const arch = @import("../arch/arch.zig");
const Ticket = @import("ticket_lock.zig").Ticket;

fn relax() void {
    arch.cpu.pause();
}

pub const IrqSpinlock = struct {
    ticket: Ticket = .{},

    pub inline fn acquire(self: *IrqSpinlock) u64 {
        const saved = arch.irq.saveAndDisable();
        self.ticket.lock(relax);
        return saved;
    }

    pub inline fn release(self: *IrqSpinlock, saved: u64) void {
        self.ticket.unlock();
        arch.irq.restore(saved);
    }

    /// Non-blocking acquire; IRQ state is restored before returning null.
    pub inline fn tryAcquire(self: *IrqSpinlock) ?u64 {
        const saved = arch.irq.saveAndDisable();
        if (self.ticket.tryLock()) return saved;
        arch.irq.restore(saved);
        return null;
    }
};
