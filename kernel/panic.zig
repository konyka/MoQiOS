/// Kernel panic handler — Zig's std.builtin.PanicHandler interface.
const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch/arch.zig");
const serial = arch.serial;
const fmt = @import("lib/fmt.zig");

/// Set while any CPU is inside panic(). The LAPIC timer tick
/// (idt.handleLapicTimer) polls this and parks the CPU with cli+hlt, so APs
/// stop scheduling and interleaving serial output with the panic dump.
/// Best-effort park: APs halt within one tick (~10ms at 100Hz).
var panicking = std.atomic.Value(bool).init(false);

pub fn isPanicking() bool {
    return panicking.load(.acquire);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // Mask IRQs on the panicking CPU before anything else.
    _ = arch.irq.saveAndDisable();

    // Recursion guard: a panic raised while this CPU already holds the serial
    // IrqSpinlock would deadlock in serial.writeString below with zero output.
    // On re-entry fall back to raw, lock-free COM1 writes, then halt.
    if (panicking.swap(true, .acq_rel)) {
        writeRaw("\n!!! RECURSIVE PANIC !!!\n  message: ");
        writeRaw(msg);
        writeRaw("\n  system halted\n");
        arch.cpu.halt();
    }

    // Park the other CPUs immediately via NMI so they stop scheduling and
    // interleaving serial output with the panic dump. LAPIC may be unmapped
    // this early (guarded inside sendNmiAllButSelf), and the timer-tick
    // isPanicking() check remains as the fallback for unreachable CPUs.
    if (comptime builtin.cpu.arch == .x86_64) {
        const smp = @import("smp.zig");
        if (smp.isCpuOnline(1)) {
            const lapic = @import("arch/x86_64/lapic.zig");
            _ = lapic.sendNmiAllButSelf();
        }
    }

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
    arch.cpu.halt();
}

/// Lock-free COM1 (port 0x3F8) write for recursive panics, where the serial
/// lock state is unknown. x86_64 only; other targets just halt.
fn writeRaw(s: []const u8) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const io = arch.io;
    const COM1: u16 = 0x3F8;
    for (s) |byte| {
        if (byte == '\n') {
            while ((io.inb(COM1 + 5) & 0x20) == 0) {}
            io.outb(COM1, '\r');
        }
        while ((io.inb(COM1 + 5) & 0x20) == 0) {}
        io.outb(COM1, byte);
    }
}
