/// Kernel panic handler — Zig's std.builtin.PanicHandler interface.

const std = @import("std");
const serial = @import("arch/x86_64/serial.zig");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    serial.writeString("\n!!! KERNEL PANIC !!!\n");
    serial.writeString("  message: ");
    serial.writeString(msg);
    serial.writeString("\n");

    if (ret_addr) |addr| {
        serial.writeString("  ret_addr: 0x");
        writeHex(addr);
        serial.writeString("\n");
    }

    serial.writeString("  system halted\n");

    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}
