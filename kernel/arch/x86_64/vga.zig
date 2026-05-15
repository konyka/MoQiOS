/// VGA text mode output — 80x25 text buffer at physical 0xB8000.

const hhdm = @import("../../mm/hhdm.zig");

const COLS = 80;
const ROWS = 25;
const VGA_PHYS = 0xB8000;
const ATTR_WHITE_ON_BLACK: u8 = 0x07;

var buffer: [*]volatile u16 = undefined;
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;

pub fn init() void {
    buffer = @ptrFromInt(hhdm.physToVirt(VGA_PHYS));
    clear();
}

pub fn clear() void {
    var i: u32 = 0;
    while (i < COLS * ROWS) : (i += 1) {
        buffer[i] = @as(u16, ' ') | (@as(u16, ATTR_WHITE_ON_BLACK) << 8);
    }
    cursor_x = 0;
    cursor_y = 0;
    updateCursor();
}

pub fn putchar(ch: u8) void {
    if (ch == '\n') {
        cursor_x = 0;
        cursor_y += 1;
    } else {
        buffer[cursor_y * COLS + cursor_x] = @as(u16, ch) | (@as(u16, ATTR_WHITE_ON_BLACK) << 8);
        cursor_x += 1;
        if (cursor_x >= COLS) {
            cursor_x = 0;
            cursor_y += 1;
        }
    }
    if (cursor_y >= ROWS) {
        scrollUp();
        cursor_y = ROWS - 1;
    }
    updateCursor();
}

pub fn writeString(s: []const u8) void {
    for (s) |ch| putchar(ch);
}

fn scrollUp() void {
    var y: u32 = 0;
    while (y < ROWS - 1) : (y += 1) {
        var x: u32 = 0;
        while (x < COLS) : (x += 1) {
            buffer[y * COLS + x] = buffer[(y + 1) * COLS + x];
        }
    }
    var x: u32 = 0;
    while (x < COLS) : (x += 1) {
        buffer[(ROWS - 1) * COLS + x] = @as(u16, ' ') | (@as(u16, ATTR_WHITE_ON_BLACK) << 8);
    }
}

fn updateCursor() void {
    const pos = cursor_y * COLS + cursor_x;
    const io = @import("io.zig");
    io.outb(0x3D4, 0x0F);
    io.outb(0x3D5, @truncate(pos));
    io.outb(0x3D4, 0x0E);
    io.outb(0x3D5, @truncate(pos >> 8));
}
