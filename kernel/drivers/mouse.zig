/// PS/2 mouse driver (i8042 aux channel, IRQ12).
///
/// Init runs the standard aux-channel sequence over the shared 0x64/0x60
/// controller ports (enable aux, enable the IRQ12 bit in the controller
/// config byte, set defaults, sample rate 100, enable data reporting),
/// serialized with the keyboard driver through drivers/ps2.zig's lock.
/// IRQ12 bytes are assembled into 3-byte packets by the pure PacketAssembler
/// (host-tested via tests/main.zig), decoded into {buttons, dx, dy} events
/// and queued in a fixed ring. /dev/mouse (registered in fs/devfs_nodes.zig)
/// dequeues 4-byte event records: [buttons, dx, dy, 0] little-endian —
/// dx/dy are signed per-packet deltas, dy already negated so up = positive.
const builtin = @import("builtin");
const ps2 = @import("ps2.zig");

/// Decoded mouse event as read from /dev/mouse (4 bytes).
pub const Event = struct {
    buttons: u8, // bit0 left, bit1 right, bit2 middle
    dx: i8,
    dy: i8, // up = positive (PS/2 wire Y axis is inverted)
    reserved: u8 = 0,
};

/// Pure 3-byte PS/2 packet assembler. Resync rule: the first byte of a
/// packet always has bit 3 set; a byte with bit 3 clear while a packet is
/// expected restarts the assembly (dropped bytes on the wire desync us, and
/// this is the only in-band framing the protocol offers).
pub const PacketAssembler = struct {
    count: u8 = 0,
    bytes: [3]u8 = .{ 0, 0, 0 },

    /// Feed one byte; returns the completed raw packet, or null.
    pub fn feed(self: *PacketAssembler, byte: u8) ?[3]u8 {
        if (self.count == 0) {
            if (byte & 0x08 == 0) return null; // not a packet start
            self.bytes[0] = byte;
            self.count = 1;
            return null;
        }
        self.bytes[self.count] = byte;
        self.count += 1;
        if (self.count < 3) return null;
        self.count = 0;
        return self.bytes;
    }

    pub fn reset(self: *PacketAssembler) void {
        self.count = 0;
    }
};

/// Pure packet → event decode. Bits 4/5 of byte 0 sign-extend dx/dy into
/// 9-bit deltas, which are then clamped to the i8 event range (the overflow
/// bits 6/7 mark deltas that already saturated on the wire — clamping keeps
/// them at the extreme instead of wrapping).
pub fn decodePacket(p: [3]u8) Event {
    var dx: i16 = p[1];
    var dy: i16 = p[2];
    if (p[0] & 0x10 != 0) dx -= 256;
    if (p[0] & 0x20 != 0) dy -= 256;
    dy = -dy; // wire Y grows downward; report up-positive
    dx = @max(-128, @min(127, dx));
    dy = @max(-128, @min(127, dy));
    return .{
        .buttons = p[0] & 0x07,
        .dx = @intCast(dx),
        .dy = @intCast(dy),
    };
}

const RING_SIZE = 64;
var ring: [RING_SIZE]Event = undefined;
var ring_head: u32 = 0;
var ring_tail: u32 = 0;
var assembler: PacketAssembler = .{};
var present: bool = false;

/// Probe and arm the PS/2 aux channel. Safe when no mouse is attached:
/// every controller transaction is bounded and a missing device simply
/// never ACKs (we log and leave IRQ12 masked).
pub fn init() void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const io = @import("../arch/arch.zig").io;
    const serial = @import("../arch/arch.zig").serial;

    const flags = ps2.lock.acquire();
    defer ps2.lock.release(flags);

    // Flush stale output bytes (bounded — a streaming device must not hang
    // the boot).
    var flush: u32 = 0;
    while (flush < 16 and io.inb(ps2.STATUS) & 0x01 != 0) : (flush += 1) {
        _ = io.inb(ps2.DATA);
    }

    // Enable the aux port.
    ps2.command(0xA8);

    // Controller config byte: set bit 1 (enable IRQ12), clear bit 5
    // (aux clock enable — 0 means the aux clock runs).
    ps2.command(0x20);
    if (!ps2.waitRead()) {
        serial.writeString("[mouse] no i8042 config response, disabled\n");
        return;
    }
    var cfg = io.inb(ps2.DATA);
    cfg |= 0x02;
    cfg &= ~@as(u8, 0x20);
    ps2.command(0x60);
    ps2.sendData(cfg);

    // Set defaults, sample rate 100/s, enable data reporting. EVERY byte
    // to the aux device needs its own 0xD4 prefix (auxCommand) — a bare
    // 0x60 write goes to the keyboard channel instead.
    if (!ps2.auxCommand(0xF6)) {
        serial.writeString("[mouse] no device on aux channel, disabled\n");
        return;
    }
    if (!ps2.auxCommand(0xF3)) return disable(serial);
    if (!ps2.auxCommand(100)) return disable(serial);
    if (!ps2.auxCommand(0xF4)) return disable(serial);

    ring_head = 0;
    ring_tail = 0;
    assembler.reset();
    present = true;

    // Route IRQ12: unmask the slave-PIC cascade (master IRQ2) and the
    // mouse line (slave IRQ12 = slave mask bit 4). idt.zig's handleIrq
    // dispatches vector 44 here.
    io.outb(0x21, io.inb(0x21) & ~@as(u8, 0x04));
    io.outb(0xA1, io.inb(0xA1) & ~@as(u8, 0x10));

    serial.writeString("[mouse] PS/2 mouse initialized (IRQ12)\n");
}

fn disable(serial: anytype) void {
    serial.writeString("[mouse] init sequence failed, disabled\n");
}

/// IRQ12 handler (idt.zig handleIrq): read the data byte and assemble.
pub fn handleInterrupt() void {
    if (!present) return;
    const io = @import("../arch/arch.zig").io;
    const byte = io.inb(ps2.DATA);
    if (assembler.feed(byte)) |packet| {
        const ev = decodePacket(packet);
        const next = (ring_head + 1) % RING_SIZE;
        if (next == ring_tail) return; // full: drop the event
        ring[ring_head] = ev;
        ring_head = next;
    }
}

pub fn isPresent() bool {
    return present;
}

pub fn hasData() bool {
    return ring_head != ring_tail;
}

/// Dequeue events into `buf` as 4-byte records. Returns the byte count
/// (a multiple of 4, 0 when the queue is empty).
pub fn read(buf: []u8) usize {
    var n: usize = 0;
    while (n + 4 <= buf.len and ring_tail != ring_head) {
        const ev = ring[ring_tail];
        ring_tail = (ring_tail + 1) % RING_SIZE;
        buf[n] = ev.buttons;
        buf[n + 1] = @bitCast(ev.dx);
        buf[n + 2] = @bitCast(ev.dy);
        buf[n + 3] = 0;
        n += 4;
    }
    return n;
}
