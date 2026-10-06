/// fbcon renderer — paints the fbcon_core cell grid onto a 32bpp surface.
///
/// Pure (surface = caller-provided pixel buffer), host-tested in
/// tests/rt_hardening_test.zig; drivers/fbcon.zig supplies the framebuffer
/// and the lock.
///
/// The write path runs inside the serial console path with IRQs off, so it
/// does O(bytes) work: changed cells are painted (write-only), and a scroll
/// only marks a repaint. Pixels are never copied within the framebuffer —
/// reading video memory back is the slowest access a CPU can make to it, and
/// a one-line scroll of a 1280x800 screen moves ~4 MB. The pending repaint
/// rebuilds rows from the cell grid, one row per `repaintStep`, from a
/// context that can afford it (the idle loop); any number of scrolls between
/// two repaints collapse into one.
const core_mod = @import("fbcon_core.zig");
const font = @import("fbcon_font.zig");

pub const FG: u32 = 0x00CC_CCCC; // light gray text
pub const BG: u32 = 0x0000_0000; // black background
pub const CURSOR: u32 = 0x00CC_CCCC;

/// A pending repaint waits until the console has been quiet this long, so a
/// burst of output never competes with it for the console lock (the lock is
/// unfair: a repainter re-taking it between rows can starve a writer).
pub const QUIET_NS: u64 = 20_000_000;

/// `last_write_ns` is published before the writer takes the lock; a stamp
/// ahead of `now_ns` (another CPU's clock) counts as a write just now.
pub fn repaintMayRun(now_ns: u64, last_write_ns: u64) bool {
    return now_ns -| last_write_ns >= QUIET_NS;
}

pub const Surface = struct {
    buf: [*]u8,
    pitch: u32,
};

pub const Step = enum {
    /// No repaint pending.
    idle,
    /// One row repainted; more remain.
    more,
    /// The last row and the cursor were repainted.
    done,
};

pub const Renderer = struct {
    repaint_pending: bool = false,
    /// Next row the pending repaint paints; rows above it are current.
    repaint_row: u16 = 0,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    glyphs_painted: u64 = 0,

    /// Feed `bytes` to the grid and paint what changed.
    pub fn write(self: *Renderer, core: *core_mod.Core, s: Surface, bytes: []const u8) void {
        for (bytes) |ch| switch (core.putChar(ch)) {
            .none => {},
            .cell => |c| if (self.isCurrent(c.y)) self.paintGlyph(s, c.x, c.y, c.ch),
            .rows => |r| {
                var y = r.first;
                while (y <= r.last) : (y += 1) {
                    if (self.isCurrent(y)) self.paintRow(core, s, y);
                }
            },
            .scroll => self.requestRepaint(),
        };
        if (!self.repaint_pending) self.moveCursor(core, s);
    }

    /// Repaint the whole screen from the grid (restarts a pass in progress).
    pub fn requestRepaint(self: *Renderer) void {
        self.repaint_pending = true;
        self.repaint_row = 0;
    }

    /// Paint the next row of a pending repaint; the final step also paints
    /// the cursor.
    pub fn repaintStep(self: *Renderer, core: *const core_mod.Core, s: Surface) Step {
        if (!self.repaint_pending) return .idle;
        self.paintRow(core, s, self.repaint_row);
        self.repaint_row += 1;
        if (self.repaint_row < core.rows) return .more;
        self.repaint_pending = false;
        self.repaint_row = 0;
        self.cursor_x = core.cx;
        self.cursor_y = core.cy;
        drawCursor(s, core.cx, core.cy);
        return .done;
    }

    /// Row `y` already shows the grid (no pending repaint will revisit it).
    fn isCurrent(self: *const Renderer, y: u16) bool {
        return !self.repaint_pending or y < self.repaint_row;
    }

    fn moveCursor(self: *Renderer, core: *const core_mod.Core, s: Surface) void {
        if (self.cursor_x != core.cx or self.cursor_y != core.cy) {
            self.paintGlyph(s, self.cursor_x, self.cursor_y, core.cellAt(self.cursor_x, self.cursor_y));
            self.cursor_x = core.cx;
            self.cursor_y = core.cy;
        }
        drawCursor(s, core.cx, core.cy);
    }

    fn paintRow(self: *Renderer, core: *const core_mod.Core, s: Surface, y: u16) void {
        var x: u16 = 0;
        while (x < core.cols) : (x += 1) self.paintGlyph(s, x, y, core.cellAt(x, y));
    }

    fn paintGlyph(self: *Renderer, s: Surface, gx: u16, gy: u16, ch: u8) void {
        self.glyphs_painted += 1;
        const glyph = if (ch >= font.FIRST and ch <= font.LAST)
            font.data[ch - font.FIRST]
        else
            font.data['?' - font.FIRST];
        const base = @as(u64, gy) * font.GLYPH_H * s.pitch + @as(u64, gx) * font.GLYPH_W * 4;
        for (glyph, 0..) |bits, row| {
            const px: [*]u32 = @ptrCast(@alignCast(s.buf + base + row * s.pitch));
            var mask: u8 = 0x80;
            var i: usize = 0;
            while (mask != 0) : ({
                mask >>= 1;
                i += 1;
            }) px[i] = if (bits & mask != 0) FG else BG;
        }
    }
};

/// Two-scanline underline at the bottom of cell (gx, gy).
fn drawCursor(s: Surface, gx: u16, gy: u16) void {
    const base = @as(u64, gy) * font.GLYPH_H * s.pitch + @as(u64, gx) * font.GLYPH_W * 4 + (font.GLYPH_H - 2) * s.pitch;
    var row: u32 = 0;
    while (row < 2) : (row += 1) {
        const px: [*]u32 = @ptrCast(@alignCast(s.buf + base + row * s.pitch));
        for (px[0..font.GLYPH_W]) |*p| p.* = CURSOR;
    }
}
