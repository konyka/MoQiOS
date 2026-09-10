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

pub const ServicingSpinlock = struct {
    locked: u32 = 0,

    pub inline fn acquire(self: *ServicingSpinlock) u64 {
        const saved = arch.irq.saveAndDisable();

        while (true) {
            if (@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) == 0) break;
            // Failed: spin with IRQs OFF (fault-handler safe), servicing any
            // in-flight shootdown broadcast ourselves so the current owner can
            // complete its shootdown wait without needing our IF=1.
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                arch.tlb.servicePendingShootdown();
                arch.cpu.pause();
            }
        }

        return saved;
    }

    pub inline fn release(self: *ServicingSpinlock, saved: u64) void {
        @atomicStore(u32, &self.locked, 0, .release);
        arch.irq.restore(saved);
    }
};
