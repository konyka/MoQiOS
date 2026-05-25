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

    const rsdt_addr = rsdp.rsdt_address;

    if (rsdp.revision >= 2 and rsdp.xsdt_address != 0) {
        // ACPI 2.0+: use XSDT (64-bit entries)
        main.mapAcpiPage(rsdp.xsdt_address);
        parseXsdt(rsdp.xsdt_address);
    } else if (rsdt_addr != 0) {
        // ACPI 1.0: use RSDT (32-bit entries)
        parseRsdt(rsdt_addr);
    }
}

/// Parse RSDT (ACPI 1.0) — 32-bit entry pointers.
fn parseRsdt(rsdt_phys: u64) void {
    // Map the page containing the RSDT first
    main.mapAcpiPage(rsdt_phys);

    const virt = hhdm.physToVirt(rsdt_phys);
    const bytes: [*]const u8 = @ptrFromInt(virt);

    // Read signature
    if (!(bytes[0] == 'R' and bytes[1] == 'S' and bytes[2] == 'D' and bytes[3] == 'T')) {
        serial.writeString("[ACPI] Invalid RSDT signature\n");
        return;
    }

    const len: u32 = @as(u32, bytes[4]) | (@as(u32, bytes[5]) << 8) |
        (@as(u32, bytes[6]) << 16) | (@as(u32, bytes[7]) << 24);

    if (len < @sizeOf(tables.SdtHeader)) return;

    const entry_count = (len - @sizeOf(tables.SdtHeader)) / 4;

        main.mapAcpiPage(rsdt_phys);

    // Read entries using byte array
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const off = @sizeOf(tables.SdtHeader) + i * 4;
        const b0 = bytes[off];
        const b1 = bytes[off + 1];
        const b2 = bytes[off + 2];
        const b3 = bytes[off + 3];
        const raw_entry: u32 = @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16) | (@as(u32, b3) << 24);
        if (raw_entry == 0) continue;
        const entry_phys: u64 = raw_entry;

        // Map page containing this table
        main.mapAcpiPage(entry_phys);

        // Read table header
        const entry_virt = hhdm.physToVirt(entry_phys);
        const hdr: [*]const u8 = @ptrFromInt(entry_virt);

        const s0 = hdr[0];
        const s1 = hdr[1];
        const s2 = hdr[2];
        const s3 = hdr[3];

        // Dispatch to appropriate parser
        if (s0 == 'A' and s1 == 'P' and s2 == 'I' and s3 == 'C') {
            parseMadt(entry_phys);
        } else if (s0 == 'M' and s1 == 'C' and s2 == 'F' and s3 == 'G') {
            parseMcfg(entry_phys);
        }
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
    const virt = hhdm.physToVirt(madt_phys);
    const bytes: [*]const u8 = @ptrFromInt(virt);

    // Read MADT fields manually to avoid alignment issues
    // Madt layout: SdtHeader(36) + local_apic_address(4) + flags(4) = 44 bytes
    const lapic_addr: u32 = @as(u32, bytes[36]) | (@as(u32, bytes[37]) << 8) |
        (@as(u32, bytes[38]) << 16) | (@as(u32, bytes[39]) << 24);
    info.lapic_address = lapic_addr;

    // Read header.length for iteration (bytes 4-7)
    const hdr_len: u32 = @as(u32, bytes[4]) | (@as(u32, bytes[5]) << 8) |
        (@as(u32, bytes[6]) << 16) | (@as(u32, bytes[7]) << 24);

    var offset: u32 = @sizeOf(tables.Madt);
    while (offset < hdr_len) {
        const entry_type = bytes[offset];
        const entry_len: u32 = bytes[offset + 1];

        if (entry_len == 0) break;

        if (entry_type == 0) {
            // MADT LAPIC entry: type(1) + len(1) + acpi_proc_id(1) + apic_id(1) + flags(4)
            if (offset + 8 <= hdr_len) {
                const apic_id: u32 = bytes[offset + 3];
                const flags: u32 = @as(u32, bytes[offset + 4]) | (@as(u32, bytes[offset + 5]) << 8) |
                    (@as(u32, bytes[offset + 6]) << 16) | (@as(u32, bytes[offset + 7]) << 24);
                if (flags & 1 != 0 and info.cpu_count < 256) {
                    info.cpu_apic_ids[info.cpu_count] = apic_id;
                    info.cpu_count += 1;
                }
            }
        } else if (entry_type == 1) {
            // MADT IOAPIC entry: type(1) + len(1) + ioapic_id(1) + reserved(1) + addr(4) + gsi_base(4)
            if (offset + 12 <= hdr_len) {
                const ioapic_addr: u32 = @as(u32, bytes[offset + 4]) | (@as(u32, bytes[offset + 5]) << 8) |
                    (@as(u32, bytes[offset + 6]) << 16) | (@as(u32, bytes[offset + 7]) << 24);
                const gsi_base: u32 = @as(u32, bytes[offset + 8]) | (@as(u32, bytes[offset + 9]) << 8) |
                    (@as(u32, bytes[offset + 10]) << 16) | (@as(u32, bytes[offset + 11]) << 24);
                info.ioapic_address = ioapic_addr;
                info.ioapic_gsi_base = gsi_base;
            }
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
    const virt = hhdm.physToVirt(mcfg_phys);
    const bytes: [*]const u8 = @ptrFromInt(virt);

    // Read header.length
    const hdr_len: u32 = @as(u32, bytes[4]) | (@as(u32, bytes[5]) << 8) |
        (@as(u32, bytes[6]) << 16) | (@as(u32, bytes[7]) << 24);

    var offset: u32 = @sizeOf(tables.Mcfg);
    while (offset + @sizeOf(tables.McfgAllocation) <= hdr_len) {
        // Read MCFG allocation entry fields manually
        const base_addr = readU64(bytes, offset);
        const seg_group = @as(u16, bytes[offset + 8]) | (@as(u16, bytes[offset + 9]) << 8);
        const start_bus = bytes[offset + 10];
        const end_bus = bytes[offset + 11];

        if (base_addr != 0) {
            info.mcfg_base = base_addr;
            info.mcfg_segment = seg_group;
            info.mcfg_start_bus = start_bus;
            info.mcfg_end_bus = end_bus;
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

/// Read a little-endian u64 from byte array at given offset.
fn readU64(bytes: [*]const u8, off: usize) u64 {
    return @as(u64, bytes[off]) |
        (@as(u64, bytes[off + 1]) << 8) |
        (@as(u64, bytes[off + 2]) << 16) |
        (@as(u64, bytes[off + 3]) << 24) |
        (@as(u64, bytes[off + 4]) << 32) |
        (@as(u64, bytes[off + 5]) << 40) |
        (@as(u64, bytes[off + 6]) << 48) |
        (@as(u64, bytes[off + 7]) << 56);
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
