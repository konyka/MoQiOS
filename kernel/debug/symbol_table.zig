/// Kernel symbol table — parses ELF .symtab for panic backtraces.

const serial = @import("../arch/x86_64/serial.zig");

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

pub fn init() void {
    table.count = 0;
    for (&table.symbols) |*sym| {
        sym.* = .{};
    }
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
        writeDecimal(@intCast(i));
        serial.writeString(" 0x");
        writeHex(addr);
        if (lookup(addr)) |name| {
            serial.writeString(" ");
            serial.writeString(name);
        }
        serial.writeString("\n");
    }
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

fn writeDecimal(value: u32) void {
    var buf: [10]u8 = undefined;
    if (value == 0) {
        buf[0] = '0';
        serial.writeString(buf[0..1]);
        return;
    }
    var v = value;
    var len: usize = 0;
    while (v > 0) : (v /= 10) {
        buf[len] = @intCast(v % 10 + '0');
        len += 1;
    }
    var j: usize = 0;
    while (j < len / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[len - 1 - j];
        buf[len - 1 - j] = tmp;
    }
    serial.writeString(buf[0..len]);
}
