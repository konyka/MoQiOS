/// fbcon — framebuffer console: mirrors serial/klog output as text on the
/// Limine framebuffer using the embedded VGA 8x16 font (fbcon_font.zig).
///
/// Pure addition to the console path: arch/x86_64/serial.zig calls
/// writeString() AFTER emitting to the UART, so serial stays the primary
/// console and a missing framebuffer (or non-32bpp mode) turns fbcon into a
/// no-op. The `fbcon_enable` gate can silence the mirror at runtime.
/// Text state (cells, cursor, scroll) lives in the pure, host-tested
/// fbcon_core.zig; this file only renders the core's effects. No allocation
/// anywhere — the render path is IRQ-safe under its own IrqSpinlock (klog
/// can log from interrupt context through the serial path).
const builtin = @import("builtin");
const std = @import("std");
const fb = @import("framebuffer.zig");
const core_mod = @import("fbcon_core.zig");
const font = @import("fbcon_font.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

/// Runtime gate: when false the serial mirror is silenced (serial output
/// itself is unaffected).
pub var fbcon_enable: bool = true;

const FG: u32 = 0x00CC_CCCC; // light gray text
const BG: u32 = 0x0000_0000; // black background
const CURSOR: u32 = 0x00CC_CCCC;

var lock: IrqSpinlock = .{};
var active: bool = false;
var core: core_mod.Core = undefined;
var last_cx: u16 = 0;
var last_cy: u16 = 0;

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
    fb.fillRect(0, 0, fb.getWidth(), fb.getHeight(), BG);
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
    const buf = fb.rawBuffer() orelse return;
    const flags = lock.acquire();
    defer lock.release(flags);
    const pitch = fb.getPitch();
    for (s) |ch| {
        switch (core.putChar(ch)) {
            .none => {},
            .cell => |c| drawGlyph(buf, pitch, c.x, c.y, c.ch),
            .scroll => doScroll(buf, pitch),
        }
    }
    // Hardware cursor: restore the glyph at the old position, paint a
    // two-scanline underline at the new one.
    if (last_cx != core.cx or last_cy != core.cy) {
        drawGlyph(buf, pitch, last_cx, last_cy, core.cellAt(last_cx, last_cy));
        drawCursor(buf, pitch, core.cx, core.cy);
        last_cx = core.cx;
        last_cy = core.cy;
    }
    fb.present();
}

fn drawGlyph(buf: [*]u8, pitch: u32, gx: u16, gy: u16, ch: u8) void {
    const glyph = if (ch >= font.FIRST and ch <= font.LAST)
        font.data[ch - font.FIRST]
    else
        font.data['?' - font.FIRST];
    const base = @as(u64, gy) * font.GLYPH_H * pitch + @as(u64, gx) * font.GLYPH_W * 4;
    for (glyph, 0..) |bits, row| {
        var px: [*]u32 = @ptrCast(@alignCast(buf + base + row * pitch));
        var mask: u8 = 0x80;
        while (mask != 0) : (mask >>= 1) {
            px[0] = if (bits & mask != 0) FG else BG;
            px += 1;
        }
    }
}

fn drawCursor(buf: [*]u8, pitch: u32, gx: u16, gy: u16) void {
    const base = @as(u64, gy) * font.GLYPH_H * pitch + (@as(u64, gx) * font.GLYPH_W) * 4 + (font.GLYPH_H - 2) * pitch;
    var row: u32 = 0;
    while (row < 2) : (row += 1) {
        const px: [*]u32 = @ptrCast(@alignCast(buf + base + row * pitch));
        for (px[0..font.GLYPH_W]) |*p| p.* = CURSOR;
    }
}

/// Grid scrolled: move the pixel rows up one text line, then repaint the
/// bottom two text lines from the cell grid (the second-to-last may hold
/// the glyph whose wrap triggered the scroll; the last is the blank line).
fn doScroll(buf: [*]u8, pitch: u32) void {
    const line_bytes: u64 = font.GLYPH_H * pitch;
    const total: u64 = @as(u64, core.rows) * line_bytes;
    std.mem.copyForwards(u8, buf[0 .. total - line_bytes], buf[line_bytes..total]);
    var y: u16 = core.rows - 2;
    while (y < core.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < core.cols) : (x += 1) {
            drawGlyph(buf, pitch, x, y, core.cellAt(x, y));
        }
    }
}
