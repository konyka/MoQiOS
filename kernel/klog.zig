/// Kernel log system — outputs to serial with level prefixes, and mirrors
/// every emitted line into a fixed-size ring buffer backing /dev/kmsg (G4).
const serial = @import("arch/arch.zig").serial;
const fmt = @import("lib/fmt.zig");
const kmsg_ring = @import("lib/kmsg_ring.zig");
const IrqSpinlock = @import("sync/irq_spinlock.zig").IrqSpinlock;

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
};

/// Capacity of the /dev/kmsg backing ring. On overflow the oldest complete
/// lines are dropped (see lib/kmsg_ring.zig).
pub const KMSG_CAP: usize = 64 * 1024;

var ring: kmsg_ring.KmsgRing(KMSG_CAP) = .{};
/// ISR-safe: same pattern as serial.zig — IrqSpinlock masks IRQs while the
/// ring is mutated, so log() from interrupt context cannot tear state.
/// No allocation anywhere on this path.
var ring_lock: IrqSpinlock = .{};

var min_level: Level = .debug;

pub fn setLevel(level: Level) void {
    min_level = level;
}

fn levelPrefix(comptime level: Level) []const u8 {
    return switch (level) {
        .err => "[ERR] ",
        .warn => "[WRN] ",
        .info => "[INF] ",
        .debug => "[DBG] ",
    };
}

/// Read from the kmsg ring at absolute cursor `read_pos` (0 = oldest
/// available byte; stale cursors clamp forward). Short reads at the
/// physical wrap are normal — callers loop on `new_pos`.
pub fn kmsgRead(read_pos: u64, buf: []u8) kmsg_ring.ReadResult {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    return ring.read(read_pos, buf);
}

/// Absolute cursor of the oldest byte still in the ring.
pub fn kmsgOldestPos() u64 {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    return ring.oldestPos();
}

fn ringAppend(parts: []const []const u8) void {
    const flags = ring_lock.acquire();
    defer ring_lock.release(flags);
    for (parts) |p| ring.appendLine(p);
}

pub fn log(comptime level: Level, comptime msg: []const u8) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    const prefix = comptime levelPrefix(level);
    serial.writeString(prefix);
    serial.writeString(msg);
    serial.writeString("\n");
    ringAppend(&.{ prefix, msg, "\n" });
}

pub fn logHex(comptime level: Level, comptime prefix: []const u8, value: u64) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    const lp = comptime levelPrefix(level);
    serial.writeString(lp);
    serial.writeString(prefix);
    serial.writeString("0x");
    fmt.writeHex(value);
    serial.writeString("\n");
    var hexbuf: [16]u8 = undefined;
    ringAppend(&.{ lp, prefix, "0x", fmt.fmtHex16(&hexbuf, value), "\n" });
}
