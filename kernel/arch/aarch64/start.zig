//! AArch64 kernel early bring-up — Milestone 9.
//!
//! Boot model: QEMU `virt` with `-cpu max -kernel kernel.elf`. QEMU loads the
//! ELF at 0x40000000 and enters `_start` in EL1. Non-Linux ELF images do not
//! get a DTB pointer in x0, so the run script also loads a dumped virt DTB at
//! `DTB_FALLBACK` via `-device loader`.
//!
//! M9-1: PL011 UART console
//! M9-2: VBAR_EL1 exception vectors + `brk` self-test

const uart = @import("uart.zig");
const trap = @import("trap.zig");

const BOOT_STACK_SIZE: usize = 64 * 1024;
/// Must match `qemu_run_aarch64.sh` loader address.
const DTB_FALLBACK: usize = 0x4a000000;
const FDT_MAGIC: u32 = 0xd00dfeed;

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

fn readBe32(addr: usize) u32 {
    const p: [*]const u8 = @ptrFromInt(addr);
    return (@as(u32, p[0]) << 24) |
        (@as(u32, p[1]) << 16) |
        (@as(u32, p[2]) << 8) |
        @as(u32, p[3]);
}

fn fdtLooksValid(addr: usize) bool {
    if (addr == 0) return false;
    return readBe32(addr) == FDT_MAGIC;
}

fn resolveDtb(x0: usize) usize {
    if (fdtLooksValid(x0)) return x0;
    if (fdtLooksValid(DTB_FALLBACK)) return DTB_FALLBACK;
    return 0;
}

export fn kmain(x0_dtb: usize) callconv(.c) noreturn {
    uart.init();
    trap.init();

    putStr("MoQiOS aarch64: M9 bring-up (PL011 + vectors)\n");

    const dtb = resolveDtb(x0_dtb);
    putStr("  dtb=");
    putHex(dtb);
    if (dtb != 0) {
        putStr(" magic=");
        putHex(readBe32(dtb));
        putStr(" (FDT OK)\n");
    } else {
        putStr(" (FDT MISSING)\n");
    }
    putStr("[aarch64] M9-1 complete\n");

    _ = trap.brkSelfTest();

    while (true) asm volatile ("wfi");
}
