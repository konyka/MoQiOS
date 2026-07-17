//! SK-35 — main.zig wires `initCpuSurfaces` + `initSymbolTable`.
//!
//! Proves the shared CPU-surface fragment and symbol-table boot path used by
//! `main.zig`, with a trivial addSymbol/lookup round-trip.

const arch = @import("../arch/arch.zig");
const subsystem_boot = @import("subsystem_boot.zig");
const symbol_table = @import("../debug/symbol_table.zig");

const PROBE_ADDR: u64 = 0x0000_0000_00DE_AD00;
const PROBE_SIZE: u32 = 0x100;

pub fn announce() void {
    subsystem_boot.initCpuSurfaces();
    subsystem_boot.initSymbolTable();

    const t0 = arch.tsc.read();
    const t1 = arch.tsc.read();
    if (t1 < t0) {
        arch.serial.writeString("[SK-35] FAILED: tsc went backwards\n");
        return;
    }

    symbol_table.addSymbol(PROBE_ADDR, PROBE_SIZE, "sk35_probe");
    symbol_table.sort();
    const name = symbol_table.lookup(PROBE_ADDR + 0x10) orelse {
        arch.serial.writeString("[SK-35] FAILED: lookup miss\n");
        return;
    };
    if (name.len != 10 or name[0] != 's' or name[1] != 'k' or name[2] != '3' or name[3] != '5') {
        arch.serial.writeString("[SK-35] FAILED: lookup name\n");
        return;
    }

    arch.serial.writeString("[SK-35] shared cpu surfaces+symbol table: OK\n");
}
