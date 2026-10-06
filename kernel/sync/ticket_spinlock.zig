/// TicketSpinlock — kept as an alias: IrqSpinlock itself is now the fair FIFO
/// ticket lock (sync/ticket_lock.zig core + IRQ masking).
pub const TicketSpinlock = @import("irq_spinlock.zig").IrqSpinlock;
