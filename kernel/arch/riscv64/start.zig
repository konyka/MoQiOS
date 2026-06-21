//! Minimal RISC-V 64 (rv64) kernel skeleton — Milestone 1 of the cross-ISA port.
//!
//! Boot model: QEMU `virt` with `-bios default -kernel kernel.elf`. OpenSBI
//! (the default firmware) runs in M-mode, then enters our ELF entry (`_start`)
//! in **S-mode** with:
//!   a0 = hartid
//!   a1 = pointer to the flattened device tree (DTB)
//! We ignore a0/a1 for now, set up a boot stack, jump to `kmain`, print over the
//! SBI legacy console, then power off via SBI.
//!
//! Subsequent milestones grow this toward parity (UART direct-drive, `stvec`
//! trap handling, Sv39 paging, timer, context switch, scheduler, user mode) and
//! extract the shared `arch` interface (see docs/cross-arch-port-plan.md).

const BOOT_STACK_SIZE: usize = 64 * 1024;

// M4 cross-arch abstraction: even though the riscv64 build still roots at this
// skeleton (not the full kernel/main.zig), we force-compile arch_impl.zig so
// the riscv64 backend stays type-checked and in sync with the contract in
// kernel/arch/arch.zig.
comptime {
    _ = @import("arch_impl.zig");
}

/// Boot stack in .bss. Exported (C linkage) so the naked `_start` can take its
/// address with a RIP/PC-relative `la` (medany code model).
export var boot_stack: [BOOT_STACK_SIZE]u8 align(16) = undefined;

/// Kernel entry from OpenSBI (S-mode). Naked: no prologue — we own the stack.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
    // sp = &boot_stack + BOOT_STACK_SIZE (stacks grow down)
        \\la sp, boot_stack
        \\li t0, 0x10000
        \\add sp, sp, t0
        // 16-byte align the stack pointer for the C ABI.
        \\andi sp, sp, -16
        \\call kmain
        // kmain should not return; if it does, spin in low-power wait.
        \\1:
        \\wfi
        \\j 1b
    );
}

/// SBI legacy ecall. a7 = extension/function id (EID), a0 = arg0.
/// Returns the value SBI leaves in a0.
fn sbiCall(eid: usize, arg0: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [eid] "{a7}" (eid),
          [a0] "{a0}" (arg0),
        : .{ .memory = true });
}

/// SBI legacy console putchar (EID 0x01).
fn sbiPutchar(c: u8) void {
    _ = sbiCall(0x01, c);
}

/// SBI legacy system shutdown (EID 0x08). Does not return on success.
fn sbiShutdown() void {
    _ = sbiCall(0x08, 0);
}

fn putStr(s: []const u8) void {
    for (s) |c| sbiPutchar(c);
}

/// First C-ABI function on the kernel stack. Prints a banner and halts.
export fn kmain() callconv(.c) noreturn {
    putStr("MoQiOS riscv64 skeleton: booted in S-mode via OpenSBI\n");
    putStr("[riscv64] arch skeleton online; halting (Milestone 1)\n");
    sbiShutdown();
    while (true) asm volatile ("wfi");
}
