/// fbcon pure text-console core — cell grid, cursor tracking, scrolling.
///
/// No imports, no allocation: fixed-size cell buffer, so the whole file is
/// host-tested via tests/main.zig (wired through kernel/host_test.zig). The
/// kernel glue in drivers/fbcon.zig renders the cell grid to the Limine
/// framebuffer; this core only models the text state.
///
/// Semantics (matching the kernel's serial-log output conventions):
///   - printable ASCII 32..126 (and 127) put a glyph and advance the cursor,
///     wrapping to the next line at the right edge;
///   - '\n' is a full newline: carriage return + line feed (serial output
///     never emits '\r', so '\n' alone must return the cursor to column 0);
///   - '\r' returns to column 0 without advancing the line;
///   - '\t' advances to the next multiple of 8 columns (wrapping like text);
///   - 0x08 (backspace) moves the cursor one cell left, without erasing;
///   - other control bytes are ignored;
///   - a line feed on the last row scrolls the grid up by one line and
///     clears the new bottom line.
pub const MAX_COLS: u16 = 200;
pub const MAX_ROWS: u16 = 75;

/// What a putChar did, so the renderer can redraw incrementally instead of
/// repainting the whole grid per byte.
pub const Effect = union(enum) {
    /// Nothing visible changed (ignored control byte).
    none,
    /// The cell at (x, y) now holds `ch` — redraw that glyph.
    cell: struct { x: u16, y: u16, ch: u8 },
    /// Cells in rows first..last (inclusive) changed without per-cell
    /// effects (a tab's blanks) — redraw those rows.
    rows: struct { first: u16, last: u16 },
    /// The grid scrolled up one line — every row changed.
    scroll,
};

pub const Core = struct {
    cols: u16,
    rows: u16,
    cx: u16 = 0,
    cy: u16 = 0,
    cells: [MAX_ROWS][MAX_COLS]u8,

    /// Grid clamped to the fixed buffer capacity.
    pub fn init(cols: u16, rows: u16) Core {
        var self = Core{
            .cols = @min(cols, MAX_COLS),
            .rows = @min(rows, MAX_ROWS),
            .cells = undefined,
        };
        self.clearAll();
        return self;
    }

    /// Blank every cell and home the cursor.
    pub fn clearAll(self: *Core) void {
        for (&self.cells) |*row| @memset(row, ' ');
        self.cx = 0;
        self.cy = 0;
    }

    pub fn cellAt(self: *const Core, x: u16, y: u16) u8 {
        return self.cells[y][x];
    }

    /// Bottom-right cell (the cursor rests there after a full last line).
    fn newline(self: *Core) Effect {
        self.cx = 0;
        if (self.cy + 1 < self.rows) {
            self.cy += 1;
            return .none;
        }
        self.scrollUp();
        return .scroll;
    }

    fn scrollUp(self: *Core) void {
        var y: u16 = 1;
        while (y < self.rows) : (y += 1) {
            @memcpy(self.cells[y - 1][0..self.cols], self.cells[y][0..self.cols]);
        }
        @memset(self.cells[self.rows - 1][0..self.cols], ' ');
    }

    pub fn putChar(self: *Core, ch: u8) Effect {
        switch (ch) {
            '\n' => return self.newline(),
            '\r' => {
                self.cx = 0;
                return .none;
            },
            '\t' => {
                // Blank up to the next multiple of 8 (or the line end), then
                // wrap like text when the line is full.
                const first = self.cy;
                const target: u16 = @min((self.cx + 8) & ~@as(u16, 7), self.cols);
                @memset(self.cells[self.cy][self.cx..target], ' ');
                self.cx = target;
                if (self.cx >= self.cols and self.newline() == .scroll) return .scroll;
                return .{ .rows = .{ .first = first, .last = self.cy } };
            },
            0x08 => {
                if (self.cx > 0) self.cx -= 1;
                return .none;
            },
            else => {
                if (ch < 32 or ch > 127) return .none;
                const fx = self.cx;
                const fy = self.cy;
                self.cells[fy][fx] = ch;
                self.cx += 1;
                if (self.cx >= self.cols) {
                    const e = self.newline();
                    // The cell draw still happened; report the scroll first
                    // (the renderer's scroll moves the drawn cell's pixels).
                    if (e == .scroll) return .scroll;
                }
                return .{ .cell = .{ .x = fx, .y = fy, .ch = ch } };
            },
        }
    }

    /// Feed a string; the renderer replays the per-byte effects.
    pub fn write(self: *Core, s: []const u8, render: ?*const fn (Effect) void) void {
        for (s) |ch| {
            const e = self.putChar(ch);
            if (render) |r| r(e);
        }
    }
};
