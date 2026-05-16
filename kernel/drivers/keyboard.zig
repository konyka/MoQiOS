const serial = @import("../arch/x86_64/serial.zig");
const io = @import("../arch/x86_64/io.zig");

const PS2_DATA: u16 = 0x60;
const PS2_STATUS: u16 = 0x64;
const PS2_COMMAND: u16 = 0x64;

const BUF_SIZE = 256;
var ring: [BUF_SIZE]u8 = undefined;
var ring_head: u32 = 0;
var ring_tail: u32 = 0;
var shift_pressed: bool = false;
var ctrl_pressed: bool = false;
var extended: bool = false;

const scancode_to_ascii = [128]u8{
    0,   0x1B, '1',  '2',  '3',  '4',  '5',  '6',
    '7',  '8',  '9',  '0',  '-',  '=',  0x08, 0x09,
    'q',  'w',  'e',  'r',  't',  'y',  'u',  'i',
    'o',  'p',  '[',  ']',  '\n', 0,    'a',  's',
    'd',  'f',  'g',  'h',  'j',  'k',  'l',  ';',
    '\'', '`',  0,    '\\', 'z',  'x',  'c',  'v',
    'b',  'n',  'm',  ',',  '.',  '/',  0,    '*',
    0,    ' ',  0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
};

const scancode_shift = [128]u8{
    0,   0x1B, '!',  '@',  '#',  '$',  '%',  '^',
    '&',  '*',  '(',  ')',  '_',  '+',  0x08, 0x09,
    'Q',  'W',  'E',  'R',  'T',  'Y',  'U',  'I',
    'O',  'P',  '{',  '}',  '\n', 0,    'A',  'S',
    'D',  'F',  'G',  'H',  'J',  'K',  'L',  ':',
    '"',  '~',  0,    '|',  'Z',  'X',  'C',  'V',
    'B',  'N',  'M',  '<',  '>',  '?',  0,    '*',
    0,    ' ',  0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,
};

pub fn init() void {
    ring_head = 0;
    ring_tail = 0;

    // Enable PS/2 keyboard device
    // Clear any pending output from the keyboard controller
    while ((io.inb(PS2_STATUS) & 0x01) != 0) {
        _ = io.inb(PS2_DATA);
    }

    // Enable first PS/2 port (keyboard)
    io.outb(PS2_COMMAND, 0xAE);

    // Enable keyboard scanning
    io.outb(PS2_DATA, 0xF4);
    // Read acknowledge
    while ((io.inb(PS2_STATUS) & 0x01) == 0) {}
    _ = io.inb(PS2_DATA);

    serial.writeString("[keyboard] PS/2 keyboard initialized\n");
}

/// Called from IRQ1 handler. Reads scancode and converts to character.
pub fn handleInterrupt() void {
    const scancode = io.inb(PS2_DATA);

    // Extended key prefix (E0)
    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    const release = (scancode & 0x80) != 0;
    const key = scancode & 0x7F;

    if (release) {
        // Key release
        switch (key) {
            0x2A, 0x36 => shift_pressed = false,
            0x1D => ctrl_pressed = false,
            else => {},
        }
        extended = false;
        return;
    }

    // Key press
    switch (key) {
        0x2A, 0x36 => {
            shift_pressed = true;
            extended = false;
            return;
        },
        0x1D => {
            ctrl_pressed = true;
            extended = false;
            return;
        },
        else => {},
    }

    // Convert to ASCII (only for non-extended basic keys)
    if (!extended and key < 128) {
        var ch: u8 = if (shift_pressed) scancode_shift[key] else scancode_to_ascii[key];
        if (ctrl_pressed and ch >= 'a' and ch <= 'z') {
            ch = ch - 'a' + 1; // Ctrl+A = 0x01, etc.
        }
        if (ch != 0) {
            push(ch);
        }
    }

    extended = false;
}

fn push(ch: u8) void {
    const next = (ring_head + 1) % BUF_SIZE;
    if (next == ring_tail) return; // buffer full, drop
    ring[ring_head] = ch;
    ring_head = next;
}

/// Read a character from the keyboard buffer. Returns 0 if empty.
pub fn readChar() u8 {
    if (ring_tail == ring_head) return 0;
    const ch = ring[ring_tail];
    ring_tail = (ring_tail + 1) % BUF_SIZE;
    return ch;
}

/// Read multiple characters into buffer. Returns count.
pub fn read(buf: []u8) usize {
    var count: usize = 0;
    while (count < buf.len) {
        const ch = readChar();
        if (ch == 0) break;
        buf[count] = ch;
        count += 1;
    }
    return count;
}

/// Check if keyboard data is available.
pub fn hasData() bool {
    return ring_head != ring_tail;
}
