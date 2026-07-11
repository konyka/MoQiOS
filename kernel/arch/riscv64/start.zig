//! RISC-V 64 kernel early bring-up — Milestone 2 of the cross-ISA port.
//!
//! Boot model: QEMU `virt` with `-bios default -kernel kernel.elf`. OpenSBI
//! enters `_start` in S-mode with:
//!   a0 = hartid
//!   a1 = pointer to the flattened device tree (DTB)
//!
//! M2 goals (see docs/cross-arch-port-plan.md):
//!   * soft-float ABI (lp64, no F/D) — enforced by build.zig `-mcpu`
//!   * preserve/print hartid + DTB magic
//!   * UART16550 direct-drive console (no SBI putchar)
//!   * `stvec` + trap frame; catch a deliberate breakpoint (`ebreak`)
//!     (illegal-instruction is not delegated by default OpenSBI medeleg)

const uart = @import("uart.zig");
const trap = @import("trap.zig");

const BOOT_STACK_SIZE: usize = 64 * 1024;

// Keep the arch_impl contract type-checked even though this skeleton is the
// build root (not the full kernel/main.zig).
comptime {
    _ = @import("arch_impl.zig");
}

/// Boot stack in .bss. Exported so naked `_start` can `la` it (medany).
export var boot_stack: [BOOT_STACK_SIZE]u8 align(16) = undefined;

/// Kernel entry from OpenSBI (S-mode). Naked: no prologue — we own the stack.
/// a0/a1 are preserved through the stack setup (only t0 is clobbered) and
/// become the C arguments to `kmain(hartid, dtb)`.
///
/// Must live in `.text.boot` so the linker places it at 0x80200000 — OpenSBI's
/// `-kernel` handoff jumps to the payload base, not ELF `e_entry`.
export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\la sp, boot_stack
        \\li t0, 0x10000
        \\add sp, sp, t0
        \\andi sp, sp, -16
        \\call kmain
        \\1:
        \\wfi
        \\j 1b
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

fn putDec(v: u64) void {
    if (v == 0) {
        uart.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (n += 1) {
        buf[n] = @intCast('0' + (x % 10));
        x /= 10;
    }
    while (n > 0) {
        n -= 1;
        uart.writeByte(buf[n]);
    }
}

/// Read big-endian u32 (FDT header fields are BE).
fn readBe32(addr: usize) u32 {
    const p: [*]const u8 = @ptrFromInt(addr);
    return (@as(u32, p[0]) << 24) |
        (@as(u32, p[1]) << 16) |
        (@as(u32, p[2]) << 8) |
        @as(u32, p[3]);
}

/// SBI system reset (SRST extension) — preferred over legacy shutdown.
fn sbiShutdown() void {
    // SBI SRST: EID 0x53525354, FID 0, reset_type=0 (shutdown), reason=0
    asm volatile ("ecall"
        :
        : [eid] "{a7}" (@as(usize, 0x53525354)),
          [fid] "{a6}" (@as(usize, 0)),
          [a0] "{a0}" (@as(usize, 0)),
          [a1] "{a1}" (@as(usize, 0)),
        : .{ .memory = true });
    // Fallback: legacy shutdown EID 0x08
    asm volatile ("ecall"
        :
        : [eid] "{a7}" (@as(usize, 0x08)),
          [a0] "{a0}" (@as(usize, 0)),
        : .{ .memory = true });
}

/// First C-ABI function on the kernel stack.
export fn kmain(hartid: usize, dtb: usize) callconv(.c) noreturn {
    uart.init();
    putStr("MoQiOS riscv64: M2 early init (soft-float, UART16550, stvec)\n");

    putStr("  hartid=");
    putDec(hartid);
    putStr("\n");

    putStr("  dtb=");
    putHex(dtb);
    if (dtb != 0) {
        const magic = readBe32(dtb);
        putStr(" magic=");
        putHex(magic);
        if (magic == 0xd00dfeed) {
            const totalsize = readBe32(dtb + 4);
            putStr(" totalsize=");
            putDec(totalsize);
            putStr(" (FDT OK)");
        } else {
            putStr(" (bad FDT magic)");
        }
    }
    putStr("\n");

    trap.init();
    putStr("  stvec installed\n");

    // Deliberate ebreak — OpenSBI delegates breakpoint (cause 3) to S-mode
    // (illegal-instruction cause 2 is NOT in the default medeleg mask).
    trap.armBreakpointTest();
    putStr("  triggering breakpoint (ebreak)...\n");
    // Force the 4-byte encoding so sepc+=4 in the handler is unambiguous
    // (plain `ebreak` may assemble to compressed c.ebreak).
    asm volatile (".word 0x00100073");
    if (trap.breakpointWasCaught()) {
        putStr("  breakpoint trap: OK\n");
    } else {
        putStr("  breakpoint trap: FAILED\n");
    }

    putStr("[riscv64] M2 complete; shutting down\n");
    sbiShutdown();
    while (true) asm volatile ("wfi");
}
