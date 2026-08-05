/// Shared PS/2 controller (i8042) port coordination.
///
/// Ports 0x60/0x64 are shared between the keyboard channel and the aux
/// (mouse) channel. drivers/keyboard.zig predates the mouse driver and
/// pokes the controller directly; both drivers now serialize their
/// controller command sequences on `lock` so an init/command sequence can
/// never interleave with the other channel's (e.g. the keyboard IRQ read of
/// 0x60 stealing a mouse ACK byte mid-sequence).
///
/// The lock is an IrqSpinlock: init-time command sequences run with IRQs
/// masked on the local CPU, so the keyboard IRQ handler cannot fire on this
/// CPU while a sequence is in flight.
const io = @import("../arch/arch.zig").io;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

pub const DATA: u16 = 0x60;
pub const STATUS: u16 = 0x64;
pub const COMMAND: u16 = 0x64;

pub const ACK: u8 = 0xFA;

pub var lock: IrqSpinlock = .{};

/// Bounded wait for the input buffer to drain (status bit 1 clear).
pub fn waitWrite() bool {
    var tries: u32 = 0;
    while (tries < 100_000) : (tries += 1) {
        if (io.inb(STATUS) & 0x02 == 0) return true;
    }
    return false;
}

/// Bounded wait for output data (status bit 0 set).
pub fn waitRead() bool {
    var tries: u32 = 0;
    while (tries < 100_000) : (tries += 1) {
        if (io.inb(STATUS) & 0x01 != 0) return true;
    }
    return false;
}

/// Send a controller command byte (port 0x64). Caller holds `lock`.
pub fn command(cmd: u8) void {
    _ = waitWrite();
    io.outb(COMMAND, cmd);
}

/// Send a data byte to the controller data port (0x60). Caller holds `lock`.
pub fn sendData(b: u8) void {
    _ = waitWrite();
    io.outb(DATA, b);
}

/// Send a command to the aux (mouse) device via the 0xD4 prefix and wait
/// for the ACK byte. Returns false on timeout or a non-ACK response.
/// Caller holds `lock`.
pub fn auxCommand(b: u8) bool {
    command(0xD4);
    sendData(b);
    if (!waitRead()) return false;
    return io.inb(DATA) == ACK;
}
