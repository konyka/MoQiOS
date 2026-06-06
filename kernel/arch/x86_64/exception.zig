/// Exception ring buffer — per-CPU circular buffer recording recent exceptions.
/// Records the last 64 exceptions with vector, error code, RIP, RFLAGS, CR2, and TSC timestamp.
const serial = @import("serial.zig");
const fmt = @import("../../lib/fmt.zig");

pub const ExceptionEntry = struct {
    vector: u8,
    error_code: u64,
    rip: u64,
    rflags: u64,
    cr2: u64,
    timestamp: u64,
};

const CAPACITY: u8 = 64;

pub const ExceptionRing = struct {
    entries: [CAPACITY]ExceptionEntry,
    head: u8,
    count: u8,

    pub fn init() ExceptionRing {
        return .{
            .entries = undefined,
            .head = 0,
            .count = 0,
        };
    }

    pub fn record(self: *ExceptionRing, vector: u8, error_code: u64, rip: u64, rflags: u64, cr2: u64) void {
        const ts = readTsc();
        self.entries[self.head] = .{
            .vector = vector,
            .error_code = error_code,
            .rip = rip,
            .rflags = rflags,
            .cr2 = cr2,
            .timestamp = ts,
        };
        self.head = (self.head + 1) % CAPACITY;
        if (self.count < CAPACITY) self.count += 1;
    }

    pub fn dump(self: *ExceptionRing) void {
        if (self.count == 0) {
            serial.writeString("[exception] No exceptions recorded\n");
            return;
        }
        serial.writeString("[exception] === Exception History ===\n");
        const start = if (self.count < CAPACITY) @as(u8, 0) else self.head;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const idx = (start + i) % CAPACITY;
            const entry = self.entries[idx];
            serial.writeString("  #");
            fmt.writeDecimal(i);
            serial.writeString(" vec=");
            fmt.writeDecimal(entry.vector);
            serial.writeString(" err=0x");
            fmt.writeHex(entry.error_code);
            serial.writeString(" rip=0x");
            fmt.writeHex(entry.rip);
            serial.writeString(" cr2=0x");
            fmt.writeHex(entry.cr2);
            serial.writeString("\n");
        }
    }
};

pub var ring: ExceptionRing = .{
    .entries = undefined,
    .head = 0,
    .count = 0,
};

fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}
