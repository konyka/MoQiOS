//! AArch64 kernel early bring-up — Milestone 9 skeleton (M1-equivalent).
//!
//! Boot model: QEMU `virt` with `-cpu max -kernel kernel.elf`. QEMU loads the
//! ELF at 0x40000000 and enters `_start` in EL1 with:
//!   x0 = pointer to the flattened device tree (DTB)
//!
//! M9-1: PL011 UART console + banner + halt.

const uart = @import("uart.zig");

const BOOT_STACK_SIZE: usize = 64 * 1024;

comptime {
    _ = @import("arch_impl.zig");
}

export var boot_stack: [BOOT_STACK_SIZE]u8 align(16) = undefined;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\adrp x1, boot_stack
        \\add  x1, x1, :lo12:boot_stack
        \\mov  x2, #0x10000
        \\add  x1, x1, x2
        \\bic  x1, x1, #0xf
        \\mov  sp, x1
        \\bl   kmain
        \\1:
        \\wfi
        \\b    1b
    );
}

fn putStr(s: []const u8) void {
    uart.writeString(s);
}

fn putHex(v: u64) void {
    const hex = "0123456789abcdef";
    putStr("0x");
    var i: u6 = 60;
    while (true) {
        uart.writeByte(hex[@intCast((v >> i) & 0xf)]);
        if (i == 0) break;
        i -= 4;
    }
}

export fn kmain(dtb: usize) callconv(.c) noreturn {
    uart.init();

    putStr("MoQiOS aarch64: M9 skeleton (PL011)\n");
    putStr("  dtb=");
    putHex(dtb);
    putStr("\n");
    putStr("[aarch64] M9-1 complete\n");

    while (true) asm volatile ("wfi");
}
