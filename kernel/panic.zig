/// Kernel panic handler — Zig's std.builtin.PanicHandler interface.
const std = @import("std");
const serial = @import("arch/x86_64/serial.zig");
const fmt = @import("lib/fmt.zig");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    serial.writeString("\n!!! KERNEL PANIC !!!\n");
    serial.writeString("  message: ");
    serial.writeString(msg);
    serial.writeString("\n");

    if (ret_addr) |addr| {
        serial.writeString("  ret_addr: 0x");
        fmt.writeHex(addr);
        serial.writeString("\n");
    }

    serial.writeString("  system halted\n");

    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}
