//! Shared serialization domain for IPC endpoints and capability tables.
//!
//! The lock is deliberately independent of `ipc.zig` and `capability.zig` so
//! either subsystem can participate in one atomic authorization operation.

const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

var authority_lock: IrqSpinlock = .{};

pub inline fn acquire() u64 {
    return authority_lock.acquire();
}

pub inline fn release(flags: u64) void {
    authority_lock.release(flags);
}
