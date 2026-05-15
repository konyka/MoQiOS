/// ACPI parser — RSDP/XSDT/MADT/MCFG parsing.

const hhdm = @import("../mm/hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
const tables = @import("acpi_tables.zig");
const main = @import("../main.zig");

pub const AcpiInfo = struct {
    rsdp: ?*const tables.RSDP,
    lapic_address: u64,
    cpu_count: u32,
    cpu_apic_ids: [256]u32,
    ioapic_address: u64,
    ioapic_gsi_base: u32,
    mcfg_base: u64,
    mcfg_segment: u16,
    mcfg_start_bus: u8,
    mcfg_end_bus: u8,
};

pub var info: AcpiInfo = .{
    .rsdp = null,
    .lapic_address = 0,
    .cpu_count = 0,
    .cpu_apic_ids = .{0} ** 256,
    .ioapic_address = 0,
    .ioapic_gsi_base = 0,
    .mcfg_base = 0,
    .mcfg_segment = 0,
    .mcfg_start_bus = 0,
    .mcfg_end_bus = 0,
};

pub fn init(rsdp_phys: u64) void {
    if (rsdp_phys == 0) {
        serial.writeString("[ACPI] No RSDP provided\n");
        return;
    }

    // Ensure the RSDP page is mapped (may be in BIOS ROM area)
    main.mapAcpiPage(rsdp_phys);

    const rsdp: *const tables.RSDP = hhdm.physToPtr(tables.RSDP, rsdp_phys);
    info.rsdp = rsdp;

    if (!memEql(rsdp.signature[0..], "RSD PTR ")) {
        serial.writeString("[ACPI] Invalid RSDP signature\n");
        return;
    }

    serial.writeString("[ACPI] RSDP found, revision: ");
    writeDecimal(rsdp.revision);
    serial.writeString("\n");

    if (rsdp.revision >= 2 and rsdp.xsdt_address != 0) {
        // Ensure XSDT page is mapped
        main.mapAcpiPage(rsdp.xsdt_address);
        parseXsdt(rsdp.xsdt_address);
    }
}

fn parseXsdt(xsdt_phys: u64) void {
    const xsdt: *const tables.SdtHeader = hhdm.physToPtr(tables.SdtHeader, xsdt_phys);

    const entry_count = (xsdt.length - @sizeOf(tables.SdtHeader)) / 8;
    const entries: [*]const u64 = @ptrFromInt(@intFromPtr(xsdt) + @sizeOf(tables.SdtHeader));

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const entry_phys = entries[i];
        if (entry_phys == 0) continue;
        // Ensure ACPI table page is mapped (may be in firmware area)
        main.mapAcpiPage(entry_phys);
        const header: *const tables.SdtHeader = hhdm.physToPtr(tables.SdtHeader, entry_phys);

        if (memEql(header.signature[0..], "APIC")) {
            parseMadt(entry_phys);
        } else if (memEql(header.signature[0..], "MCFG")) {
            parseMcfg(entry_phys);
        }
    }
}

fn parseMadt(madt_phys: u64) void {
    const madt: *const tables.Madt = hhdm.physToPtr(tables.Madt, madt_phys);
    info.lapic_address = madt.local_apic_address;

    var offset: u32 = @sizeOf(tables.Madt);
    while (offset < madt.header.length) {
        const entry_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(madt) + offset);
        const entry_type = entry_ptr[0];
        const entry_len: u32 = entry_ptr[1];

        if (entry_len == 0) break;

        if (entry_type == 0) {
            const lapic: *const tables.MadtLapicEntry = @ptrFromInt(@intFromPtr(entry_ptr));
            if (lapic.flags & 1 != 0 and info.cpu_count < 256) {
                info.cpu_apic_ids[info.cpu_count] = lapic.apic_id;
                info.cpu_count += 1;
            }
        } else if (entry_type == 1) {
            const ioapic: *const tables.MadtIoapicEntry = @ptrFromInt(@intFromPtr(entry_ptr));
            info.ioapic_address = ioapic.ioapic_address;
            info.ioapic_gsi_base = ioapic.gsi_base;
        }

        offset += entry_len;
    }

    serial.writeString("[ACPI] MADT: ");
    writeDecimal(info.cpu_count);
    serial.writeString(" CPUs, LAPIC=0x");
    writeHex(info.lapic_address);
    serial.writeString(", IOAPIC=0x");
    writeHex(info.ioapic_address);
    serial.writeString("\n");
}

fn parseMcfg(mcfg_phys: u64) void {
    const mcfg: *const tables.Mcfg = hhdm.physToPtr(tables.Mcfg, mcfg_phys);

    var offset: u32 = @sizeOf(tables.Mcfg);
    while (offset < mcfg.header.length) {
        const alloc: *const tables.McfgAllocation = @ptrFromInt(@intFromPtr(mcfg) + offset);
        if (alloc.base_address != 0) {
            info.mcfg_base = alloc.base_address;
            info.mcfg_segment = alloc.segment_group;
            info.mcfg_start_bus = alloc.start_bus;
            info.mcfg_end_bus = alloc.end_bus;
            break;
        }
        offset += @sizeOf(tables.McfgAllocation);
    }

    serial.writeString("[ACPI] MCFG: base=0x");
    writeHex(info.mcfg_base);
    serial.writeString("\n");
}

fn memEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ca != cb) return false;
    return true;
}

fn writeDecimal(value: u32) void {
    var buf: [10]u8 = undefined;
    if (value == 0) {
        serial.writeString("0");
        return;
    }
    var v = value;
    var i: usize = 0;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    serial.writeString(buf[0..i]);
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
