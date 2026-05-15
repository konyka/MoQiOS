/// IrqSpinlock — interrupt-safe spinlock.
/// Saves RFLAGS on acquire, disables interrupts, spins until lock is free.
/// Restores RFLAGS on release (re-enabling interrupts if they were on).
///
/// Usage:
///   const flags = lock.acquire();
///   defer lock.release(flags);
///   // ... critical section ...

pub const IrqSpinlock = struct {
    locked: u32 = 0,

    pub inline fn acquire(self: *IrqSpinlock) u64 {
        // Save RFLAGS (including IF bit) and disable interrupts
        var rflags: u64 = undefined;
        asm volatile (
            \\pushfq
            \\pop %[flags]
            \\cli
            : [flags] "=r" (rflags),
        );

        // Spin until we atomically swap 0 → 1
        while (true) {
            if (@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) == 0) break;
            // Spin on read (avoids bus-locking cache line bouncing)
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                asm volatile ("pause");
            }
        }

        return rflags;
    }

    pub inline fn release(self: *IrqSpinlock, saved_rflags: u64) void {
        @atomicStore(u32, &self.locked, 0, .release);
        asm volatile (
            \\push %[flags]
            \\popfq
            :
            : [flags] "r" (saved_rflags),
        );
    }
};
