//! PL011 UART for QEMU `virt` (MMIO at 0x09000000).
//!
//! Milestone 9 skeleton: early console only (TX path).

const UART_BASE: usize = 0x09000000;

const UARTDR: usize = 0x00;
const UARTFR: usize = 0x18;
const UARTIBRD: usize = 0x24;
const UARTFBRD: usize = 0x28;
const UARTLCR_H: usize = 0x2c;
const UARTCR: usize = 0x30;
const UARTIMSC: usize = 0x38;

const FR_TXFF: u32 = 1 << 5;

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(UART_BASE + offset);
}

/// Enable 8N1 + FIFO + TX/RX. Baud is largely ignored by QEMU virt.
pub fn init() void {
    reg(UARTCR).* = 0;
    reg(UARTIMSC).* = 0;
    reg(UARTIBRD).* = 26;
    reg(UARTFBRD).* = 3;
    reg(UARTLCR_H).* = 0x70; // 8 bits, FIFO enable
    reg(UARTCR).* = 0x301; // UARTEN | TXE | RXE
}

pub fn writeByte(byte: u8) void {
    while ((reg(UARTFR).* & FR_TXFF) != 0) {}
    reg(UARTDR).* = byte;
}

pub fn writeString(s: []const u8) void {
    for (s) |c| writeByte(c);
}
