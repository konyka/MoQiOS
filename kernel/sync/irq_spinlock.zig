/// IrqSpinlock — interrupt-safe spinlock (SK-4: arch-neutral IRQ masking).
/// Saves interrupt-enable state on acquire, disables IRQs, spins until free.
/// Restores prior interrupt state on release.
///
/// Usage:
///   const flags = lock.acquire();
///   defer lock.release(flags);
///   // ... critical section ...

const arch = @import("../arch/arch.zig");

pub const IrqSpinlock = struct {
    locked: u32 = 0,

    pub inline fn acquire(self: *IrqSpinlock) u64 {
        const saved = arch.irq.saveAndDisable();

        while (true) {
            if (@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) == 0) break;
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                arch.cpu.pause();
            }
        }

        return saved;
    }

    pub inline fn release(self: *IrqSpinlock, saved: u64) void {
        @atomicStore(u32, &self.locked, 0, .release);
        arch.irq.restore(saved);
    }
};
