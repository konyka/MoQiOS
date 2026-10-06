/// ServicingSpinlock — interrupt-safe spinlock whose spin loop manually
/// services pending TLB shootdown broadcasts via the arch hook
/// (`arch.tlb.servicePendingShootdown`; a no-op on uniprocessor ports).
///
/// Motivation: `Mm.vm_lock` holders synchronously wait for remote TLB
/// shootdown acknowledgements (mprotect/munmap/mremap/COW paths). A remote
/// CPU spinning on the same lock with IRQs off would never take the shootdown
/// IPI, so the initiator's ack wait would time out and `failShootdown` would
/// halt the system. `TlbLock` (arch/x86_64/tlb.zig) already solves the same
/// problem for shootdown initiators by servicing broadcasts while spinning;
/// this lock applies the same pattern to general VM-lock waiters.
///
/// Usage is identical to `IrqSpinlock`:
///   const flags = lock.acquire();
///   defer lock.release(flags);
///   // ... critical section ...

const arch = @import("../arch/arch.zig");
const Ticket = @import("ticket_lock.zig").Ticket;

/// Spin with IRQs OFF (fault-handler safe), servicing any in-flight shootdown
/// broadcast ourselves so the current owner can complete its shootdown wait
/// without needing our IF=1.
fn serviceAndRelax() void {
    arch.tlb.servicePendingShootdown();
    arch.cpu.pause();
}

pub const ServicingSpinlock = struct {
    ticket: Ticket = .{},

    /// Fair (FIFO ticket) acquire, see sync/ticket_lock.zig.
    pub inline fn acquire(self: *ServicingSpinlock) u64 {
        const saved = arch.irq.saveAndDisable();
        self.ticket.lock(serviceAndRelax);
        return saved;
    }

    pub inline fn release(self: *ServicingSpinlock, saved: u64) void {
        self.ticket.unlock();
        arch.irq.restore(saved);
    }

    /// Non-blocking acquire: a single CAS that only succeeds on a free lock.
    /// Returns the saved IRQ flags on success (release with `release`), or
    /// null on contention — IRQ state is restored before returning null, so
    /// the caller's interrupt state is exactly as it entered. Used by
    /// best-effort paths (swap reclaim) that must never wait on vm_lock.
    pub inline fn tryAcquire(self: *ServicingSpinlock) ?u64 {
        const saved = arch.irq.saveAndDisable();
        if (self.ticket.tryLock()) return saved;
        arch.irq.restore(saved);
        return null;
    }
};
