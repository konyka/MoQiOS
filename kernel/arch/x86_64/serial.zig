/// x86_64 Serial port (COM1) driver for early kernel output
/// Uses I/O port 0x3F8

const ports = @import("io.zig");

const COM1 = 0x3F8;

pub fn init() void {
    // Disable interrupts
    ports.outb(COM1 + 1, 0x00);
    // Enable DLAB (set baud rate divisor)
    ports.outb(COM1 + 3, 0x80);
    // Set divisor to 1 (115200 baud)
    ports.outb(COM1 + 0, 0x01);
    ports.outb(COM1 + 1, 0x00);
    // 8 bits, no parity, one stop bit
    ports.outb(COM1 + 3, 0x03);
    // Enable FIFO, clear them, 14-byte threshold
    ports.outb(COM1 + 2, 0xC7);
    // IRQs enabled, RTS/DSR set
    ports.outb(COM1 + 4, 0x0B);
}

pub fn writeByte(byte: u8) void {
    // Wait for transmit buffer to be empty
    while ((ports.inb(COM1 + 5) & 0x20) == 0) {}
    ports.outb(COM1, byte);
}

pub fn writeString(s: []const u8) void {
    for (s) |byte| {
        if (byte == '\n') writeByte('\r');
        writeByte(byte);
    }
}
