/// Kernel symbol table — parses ELF .symtab for panic backtraces.
const serial = @import("../arch/arch.zig").serial;
const fmt = @import("../lib/fmt.zig");

pub const Symbol = struct {
    addr: u64 = 0,
    size: u32 = 0,
    name: [64]u8 = .{0} ** 64,
    name_len: u8 = 0,
};

const MAX_SYMBOLS: u32 = 4096;

pub const SymbolTable = struct {
    symbols: [MAX_SYMBOLS]Symbol,
    count: u32,
};

pub var table: SymbolTable = undefined;

var initialized: bool = false;

pub fn init() void {
    // Idempotent: subsystem_boot / main / SK-35 may all call this.
    if (initialized) return;
    table.count = 0;
    for (&table.symbols) |*sym| {
        sym.* = .{};
    }
    initialized = true;
}

pub fn addSymbol(addr: u64, size: u32, name: []const u8) void {
    if (table.count >= MAX_SYMBOLS) return;
    var sym = &table.symbols[table.count];
    sym.addr = addr;
    sym.size = size;
    sym.name_len = @intCast(@min(name.len, 63));
    for (0..sym.name_len) |i| {
        sym.name[i] = name[i];
    }
    sym.name[sym.name_len] = 0;
    table.count += 1;
}

pub fn lookup(addr: u64) ?[]const u8 {
    if (table.count == 0) return null;
    var lo: u32 = 0;
    var hi: u32 = table.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (table.symbols[mid].addr <= addr) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo == 0) return null;
    const sym = &table.symbols[lo - 1];
    if (addr >= sym.addr and addr < sym.addr + sym.size) {
        return sym.name[0..sym.name_len];
    }
    if (sym.size == 0 and addr == sym.addr) {
        return sym.name[0..sym.name_len];
    }
    return null;
}

pub fn sort() void {
    var i: u32 = 1;
    while (i < table.count) : (i += 1) {
        const key = table.symbols[i];
        var j: u32 = i;
        while (j > 0 and table.symbols[j - 1].addr > key.addr) : (j -= 1) {
            table.symbols[j] = table.symbols[j - 1];
        }
        table.symbols[j] = key;
    }
}

pub fn printBacktrace(addrs: []const u64) void {
    for (addrs, 0..) |addr, i| {
        serial.writeString("  #");
        fmt.writeDecimal(@intCast(i));
        serial.writeString(" 0x");
        fmt.writeHex(addr);
        if (lookup(addr)) |name| {
            serial.writeString(" ");
            serial.writeString(name);
        }
        serial.writeString("\n");
    }
}
