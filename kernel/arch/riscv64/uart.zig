//! NS16550A UART driver for QEMU `virt` (MMIO at 0x10000000).
//!
//! Milestone 2: direct-drive console that does not depend on SBI legacy
//! putchar. Register layout matches the classic 16550; we only need the
//! transmitter path for early boot prints.

const UART_BASE: usize = 0x10000000;

const RHR: usize = 0; // receive holding (read)
const THR: usize = 0; // transmit holding (write)
const IER: usize = 1; // interrupt enable
const FCR: usize = 2; // FIFO control
const LCR: usize = 3; // line control
const LSR: usize = 5; // line status

const LSR_THRE: u8 = 1 << 5; // transmitter holding register empty

fn reg(offset: usize) *volatile u8 {
    return @ptrFromInt(UART_BASE + offset);
}

/// Program 8N1, enable FIFOs, disable UART IRQs. Idempotent.
pub fn init() void {
    reg(IER).* = 0; // no interrupts
    reg(LCR).* = 0x03; // 8 bits, no parity, 1 stop
    reg(FCR).* = 0x01; // enable FIFO
}

pub fn writeByte(byte: u8) void {
    // Spin until the holding register is empty, then write.
    while ((reg(LSR).* & LSR_THRE) == 0) {}
    reg(THR).* = byte;
}

pub fn writeString(s: []const u8) void {
    for (s) |c| writeByte(c);
}

/// Optional: non-blocking receive (unused by M2, kept for later).
pub fn tryReadByte() ?u8 {
    if ((reg(LSR).* & 0x01) == 0) return null;
    return reg(RHR).*;
}
