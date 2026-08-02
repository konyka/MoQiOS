/// RwLock — Reader-Writer Lock built on IrqSpinlock.
///
/// Allows multiple concurrent readers or a single exclusive writer.
/// Writers wait for all readers to finish; readers wait for writers.
/// IRQs stay masked for the whole critical section (saved in *Lock, restored
/// in *Unlock — same contract as IrqSpinlock) so an IRQ handler on this CPU
/// touching the lock cannot deadlock against the interrupted holder.

const arch = @import("../arch/arch.zig");
const IrqSpinlock = @import("irq_spinlock.zig").IrqSpinlock;

pub const RwLock = struct {
    lock: IrqSpinlock = .{},
    reader_count: u32 = 0,
    writer_wait: u32 = 0,
    writer_active: bool = false,

    /// Acquire a shared (read) lock. Returns saved IRQ flags for readUnlock.
    /// Blocks if a writer is active or waiting (writer-priority to prevent starvation).
    pub fn readLock(self: *RwLock) u64 {
        const irq_flags = arch.irq.saveAndDisable();
        // Spin until no writer is active or waiting
        while (true) {
            const f = self.lock.acquire();
            if (!self.writer_active and self.writer_wait == 0) {
                self.reader_count += 1;
                self.lock.release(f);
                return irq_flags;
            }
            self.lock.release(f);
            arch.cpu.pause();
        }
    }

    /// Release a shared (read) lock; restores IRQ flags from readLock.
    pub fn readUnlock(self: *RwLock, flags: u64) void {
        const f = self.lock.acquire();
        self.reader_count -= 1;
        self.lock.release(f);
        arch.irq.restore(flags);
    }

    /// Acquire an exclusive (write) lock. Returns saved IRQ flags for writeUnlock.
    /// Blocks until all readers and other writers have released.
    pub fn writeLock(self: *RwLock) u64 {
        const irq_flags = arch.irq.saveAndDisable();
        // Keep writer_wait elevated across the whole wait so new readers block
        // behind us (writer priority); drop it once the write side is held.
        {
            const f = self.lock.acquire();
            self.writer_wait += 1;
            self.lock.release(f);
        }
        while (true) {
            const f = self.lock.acquire();
            if (!self.writer_active and self.reader_count == 0) {
                self.writer_active = true;
                self.writer_wait -= 1;
                self.lock.release(f);
                return irq_flags;
            }
            self.lock.release(f);
            arch.cpu.pause();
        }
    }

    /// Release an exclusive (write) lock; restores IRQ flags from writeLock.
    pub fn writeUnlock(self: *RwLock, flags: u64) void {
        const f = self.lock.acquire();
        self.writer_active = false;
        self.lock.release(f);
        arch.irq.restore(flags);
    }
};
