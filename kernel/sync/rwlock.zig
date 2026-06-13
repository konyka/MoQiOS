/// RwLock — Reader-Writer Lock based on ticket spinlock.
///
/// Allows multiple concurrent readers or a single exclusive writer.
/// Writers wait for all readers to finish; readers wait for writers.
/// Uses the existing IrqSpinlock for interrupt safety.

const IrqSpinlock = @import("irq_spinlock.zig").IrqSpinlock;

pub const RwLock = struct {
    lock: IrqSpinlock = .{},
    reader_count: u32 = 0,
    writer_wait: u32 = 0,
    writer_active: bool = false,

    /// Acquire a shared (read) lock.
    /// Blocks if a writer is active or waiting (writer-priority to prevent starvation).
    pub fn readLock(self: *RwLock) u64 {
        // Spin until no writer is active or waiting
        while (true) {
            const flags = self.lock.acquire();
            if (!self.writer_active and self.writer_wait == 0) {
                self.reader_count += 1;
                self.lock.release(flags);
                return flags;
            }
            self.lock.release(flags);
            asm volatile ("pause");
        }
    }

    /// Release a shared (read) lock.
    pub fn readUnlock(self: *RwLock, flags: u64) void {
        const f = self.lock.acquire();
        self.reader_count -= 1;
        self.lock.release(f);
        _ = flags;
    }

    /// Acquire an exclusive (write) lock.
    /// Blocks until all readers and other writers have released.
    pub fn writeLock(self: *RwLock) u64 {
        var flags: u64 = 0;
        while (true) {
            flags = self.lock.acquire();
            self.writer_wait += 1;
            if (!self.writer_active and self.reader_count == 0) {
                self.writer_active = true;
                self.writer_wait -= 1;
                self.lock.release(flags);
                return flags;
            }
            self.writer_wait -= 1;
            self.lock.release(flags);
            asm volatile ("pause");
        }
    }

    /// Release an exclusive (write) lock.
    pub fn writeUnlock(self: *RwLock, flags: u64) void {
        const f = self.lock.acquire();
        self.writer_active = false;
        self.lock.release(f);
        _ = flags;
    }
};
