/// fbcon — framebuffer console: mirrors serial/klog output as text on the
/// Limine framebuffer using the embedded VGA 8x16 font (fbcon_font.zig).
///
/// Pure addition to the console path: arch/x86_64/serial.zig calls
/// writeString() AFTER emitting to the UART, so serial stays the primary
/// console and a missing framebuffer (or non-32bpp mode) turns fbcon into a
/// no-op. The `fbcon_enable` gate can silence the mirror at runtime.
/// Text state (cells, cursor, scroll) lives in the pure, host-tested
/// fbcon_core.zig and painting in fbcon_render.zig; this file supplies the
/// framebuffer and the lock. No allocation anywhere — the write path is
/// IRQ-safe under its own IrqSpinlock (klog can log from interrupt context
/// through the serial path) and does O(bytes) work; scroll repaints run from
/// the idle loop, one text row per lock hold.
const fb = @import("framebuffer.zig");
const core_mod = @import("fbcon_core.zig");
const font = @import("fbcon_font.zig");
const render = @import("fbcon_render.zig");
const tsc = @import("../arch/arch.zig").tsc;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

/// Runtime gate: when false the serial mirror is silenced (serial output
/// itself is unaffected).
pub var fbcon_enable: bool = true;

var lock: IrqSpinlock = .{};
var active: bool = false;
var core: core_mod.Core = undefined;
var renderer: render.Renderer = .{};
var last_write_ns: u64 = 0;

/// Arm the console on the Limine framebuffer. No-op without a framebuffer
/// or in a non-32bpp mode (the renderer writes u32 pixels).
pub fn init() void {
    const serial = @import("../arch/arch.zig").serial;
    if (!fb.isInitialized()) {
        serial.writeString("[fbcon] no framebuffer, console mirror disabled\n");
        return;
    }
    if (fb.getBpp() != 32) {
        serial.writeString("[fbcon] non-32bpp framebuffer, console mirror disabled\n");
        return;
    }
    const cols: u16 = @intCast(fb.getWidth() / font.GLYPH_W);
    const rows: u16 = @intCast(fb.getHeight() / font.GLYPH_H);
    if (cols < 2 or rows < 2) {
        serial.writeString("[fbcon] framebuffer too small, console mirror disabled\n");
        return;
    }
    core = core_mod.Core.init(cols, rows);
    fb.fillRect(0, 0, fb.getWidth(), fb.getHeight(), render.BG);
    active = true;

    serial.writeString("[fbcon] ");
    const fmt = @import("../lib/fmt.zig");
    fmt.writeDecimal(cols);
    serial.writeString("x");
    fmt.writeDecimal(rows);
    serial.writeString(" text console on framebuffer\n");
}

pub fn isActive() bool {
    return active;
}

/// Mirror a string onto the framebuffer. Called from the serial write path
/// (arch/x86_64/serial.zig) — never call serial from here (lock order is
/// serial → fbcon, and the UART must stay the primary console).
pub fn writeString(s: []const u8) void {
    if (!active or !fbcon_enable) return;
    const surf = surface() orelse return;
    @atomicStore(u64, &last_write_ns, tsc.nanos(), .monotonic);
    const flags = lock.acquire();
    defer lock.release(flags);
    renderer.write(&core, surf, s);
    if (!renderer.repaint_pending) fb.present();
}

/// Idle-loop hook: advance a pending repaint one row per lock hold, so the
/// IRQ-off window stays one text row long and a woken task preempts the
/// repaint between rows. Backs off while the console is being written.
pub fn idleFlush() void {
    if (!active) return;
    const surf = surface() orelse return;
    while (true) {
        if (!render.repaintMayRun(tsc.nanos(), @atomicLoad(u64, &last_write_ns, .monotonic))) return;
        const flags = lock.acquire();
        const step: render.Step = if (fbcon_enable) renderer.repaintStep(&core, surf) else .idle;
        if (step == .done) fb.present();
        lock.release(flags);
        if (step != .more) return;
    }
}

/// Repaint everything on the next idle flush (the screen no longer shows the
/// grid, e.g. after a userspace fb0 owner let go).
pub fn requestRepaint() void {
    if (!active) return;
    const flags = lock.acquire();
    defer lock.release(flags);
    renderer.requestRepaint();
}

/// Panic path: the idle loop will never run again, so repaint now. Lock-free
/// — the other CPUs are parked and may have been parked holding the lock.
pub fn panicFlush() void {
    if (!active or !fbcon_enable) return;
    const surf = surface() orelse return;
    if (!renderer.repaint_pending) return;
    while (renderer.repaintStep(&core, surf) == .more) {}
    fb.present();
}

fn surface() ?render.Surface {
    const buf = fb.rawBuffer() orelse return null;
    return .{ .buf = buf, .pitch = fb.getPitch() };
}
