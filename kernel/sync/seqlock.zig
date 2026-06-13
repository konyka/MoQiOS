/// SeqLock — Sequential Lock for read-mostly data.
///
/// Writers take an exclusive lock (via spinlock). Readers never block;
/// they read the sequence counter before and after accessing data.
/// If the sequence changed during the read, the reader retries.
///
/// Sequence number: even = no writer active, odd = write in progress.
///
/// Usage:
///   var lock: SeqLock = .{};
///
///   // Writer:
///   lock.writeLock();
///   // ... modify shared data ...
///   lock.writeUnlock();
///
///   // Reader:
///   var seq1: u64 = undefined;
///   var seq2: u64 = undefined;
///   repeat: {
///       seq1 = lock.readBegin();
///       // ... read shared data ...
///       seq2 = lock.readEnd();
///       if (seq1 != seq2 or seq1 & 1 != 0) continue :repeat;
///   }

const IrqSpinlock = @import("irq_spinlock.zig").IrqSpinlock;

pub const SeqLock = struct {
    sequence: u64 = 0,
    lock: IrqSpinlock = .{},

    /// Begin a read section. Returns the current sequence number.
    /// The reader should check that the sequence didn't change after reading.
    pub fn readBegin(self: *SeqLock) u64 {
        var seq: u64 = undefined;
        while (true) {
            seq = @atomicLoad(u64, &self.sequence, .acquire);
            if (seq & 1 == 0) return seq; // Even = no writer
            asm volatile ("pause");
        }
    }

    /// End a read section. Returns the current sequence number.
    /// If this differs from readBegin()'s result, the data was modified.
    pub fn readEnd(self: *SeqLock) u64 {
        return @atomicLoad(u64, &self.sequence, .acquire);
    }

    /// Check if a read needs to be retried.
    /// Returns true if the read is valid (no concurrent write occurred).
    pub fn readRetry(self: *SeqLock, start_seq: u64) bool {
        const end_seq = @atomicLoad(u64, &self.sequence, .acquire);
        return end_seq != start_seq or start_seq & 1 != 0;
    }

    /// Acquire the write lock. Returns IRQ flags.
    /// Increments sequence to odd (indicating write in progress).
    pub fn writeLock(self: *SeqLock) u64 {
        const flags = self.lock.acquire();
        @atomicRmw(u64, &self.sequence, .Add, 1, .release); // seq → odd
        return flags;
    }

    /// Release the write lock.
    /// Increments sequence to even (indicating write complete).
    pub fn writeUnlock(self: *SeqLock, flags: u64) void {
        @atomicRmw(u64, &self.sequence, .Add, 1, .release); // seq → even
        self.lock.release(flags);
    }
};
