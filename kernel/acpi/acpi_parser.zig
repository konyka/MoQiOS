/// ACPI parser — RSDP/XSDT/MADT/MCFG parsing.
const builtin = @import("builtin");
const hhdm = @import("../mm/hhdm.zig");
const serial = @import("../arch/arch.zig").serial;
const tables = @import("acpi_tables.zig");
const fmt = @import("../lib/fmt.zig");
const str = @import("../lib/str.zig");
const bo = @import("../lib/byte_order.zig");
const cpu_capacity = @import("../arch/cpu_capacity.zig");
const madt_iso = @import("madt_iso.zig");

/// Map a physical page for ACPI table access. x86_64 uses Limine HHDM helpers
/// in `main.zig`; other arches no-op (SK-10: avoid pulling Limine `main`).
fn mapAcpiPage(phys_addr: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    @import("../main.zig").mapAcpiPage(phys_addr);
}

pub const AcpiInfo = struct {
    rsdp: ?*const tables.RSDP,
    lapic_address: u64,
    cpu_count: u32,
    cpu_apic_ids: [cpu_capacity.MAX_CPUS]u32,
    ioapic_address: u64,
    ioapic_gsi_base: u32,
    /// MADT Interrupt Source Override (type 2) entries — consulted by
    /// ioapic.routeGsi for firmware-declared trigger/polarity.
    isos: madt_iso.IsoTable,
    mcfg_base: u64,
    mcfg_segment: u16,
    mcfg_start_bus: u8,
    mcfg_end_bus: u8,
};

pub var info: AcpiInfo = .{
    .rsdp = null,
    .lapic_address = 0,
    .cpu_count = 0,
    .cpu_apic_ids = .{0} ** cpu_capacity.MAX_CPUS,
    .ioapic_address = 0,
    .ioapic_gsi_base = 0,
    .isos = .{},
    .mcfg_base = 0,
    .mcfg_segment = 0,
    .mcfg_start_bus = 0,
    .mcfg_end_bus = 0,
};

pub fn init(rsdp_phys: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) {
        serial.writeString("[ACPI] non-x86: stub (no RSDP path)\n");
    } else {
        initX86(rsdp_phys);
    }
}

fn initX86(rsdp_phys: u64) void {
    if (rsdp_phys == 0) {
        serial.writeString("[ACPI] No RSDP provided\n");
        return;
    }

    // Ensure the RSDP page is mapped (may be in BIOS ROM area)
    mapAcpiPage(rsdp_phys);

    const rsdp: *const tables.RSDP = hhdm.physToPtr(tables.RSDP, rsdp_phys);
    info.rsdp = rsdp;

    if (!str.eql(rsdp.signature[0..], "RSD PTR ")) {
        serial.writeString("[ACPI] Invalid RSDP signature\n");
        return;
    }

    serial.writeString("[ACPI] RSDP found, revision: ");
    fmt.writeDecimal(rsdp.revision);
    serial.writeString("\n");

    const rsdt_addr = rsdp.rsdt_address;

    if (rsdp.revision >= 2 and rsdp.xsdt_address != 0) {
        // ACPI 2.0+: use XSDT (64-bit entries)
        mapAcpiPage(rsdp.xsdt_address);
        parseXsdt(rsdp.xsdt_address);
    } else if (rsdt_addr != 0) {
        // ACPI 1.0: use RSDT (32-bit entries)
        parseRsdt(rsdt_addr);
    }
}

/// Parse RSDT (ACPI 1.0) — 32-bit entry pointers.
fn parseRsdt(rsdt_phys: u64) void {
    // Map the page containing the RSDT first
    mapAcpiPage(rsdt_phys);

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

    mapAcpiPage(rsdt_phys);

    // Read entries using byte array
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const off = @sizeOf(tables.SdtHeader) + i * 4;
        const raw_entry: u32 = bo.readU32Le(bytes[off .. off + 4]);
        if (raw_entry == 0) continue;
        const entry_phys: u64 = raw_entry;

        // Map page containing this table
        mapAcpiPage(entry_phys);

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

    // Trusting the firmware length field: if length < header size the u32
    // subtraction below underflows to ~4G and the loop walks entries far
    // past the mapped table (same guard as parseRsdt).
    if (xsdt.length < @sizeOf(tables.SdtHeader)) return;

    const entry_count = (xsdt.length - @sizeOf(tables.SdtHeader)) / 8;
    const entries: [*]const u64 = @ptrFromInt(@intFromPtr(xsdt) + @sizeOf(tables.SdtHeader));

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const entry_phys = entries[i];
        if (entry_phys == 0) continue;
        // Ensure ACPI table page is mapped (may be in firmware area)
        mapAcpiPage(entry_phys);
        const header: *const tables.SdtHeader = hhdm.physToPtr(tables.SdtHeader, entry_phys);

        if (str.eql(header.signature[0..], "APIC")) {
            parseMadt(entry_phys);
        } else if (str.eql(header.signature[0..], "MCFG")) {
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
    const raw_len: u32 = @as(u32, bytes[4]) | (@as(u32, bytes[5]) << 8) |
        (@as(u32, bytes[6]) << 16) | (@as(u32, bytes[7]) << 24);

    // Clamp the firmware length to the mapped window — only one 2MiB huge
    // page is mapped per table (mapAcpiPage), so a corrupt length must not
    // walk entries past the mapped region.
    const window: u32 = 0x200000 - @as(u32, @intCast(madt_phys & 0x1FFFFF));
    const hdr_len: u32 = @min(raw_len, window);

    var warned_x2apic = false;
    var offset: u32 = @sizeOf(tables.Madt);
    while (offset + 2 <= hdr_len) {
        const entry_type = bytes[offset];
        const entry_len: u32 = bytes[offset + 1];

        if (entry_len < 2 or offset + entry_len > hdr_len) {
            serial.writeString("[ACPI] WARN: malformed MADT entry; stopping parse\n");
            break;
        }

        if (entry_type == 0) {
            // MADT LAPIC entry: type(1) + len(1) + acpi_proc_id(1) + apic_id(1) + flags(4)
            if (offset + 8 <= hdr_len) {
                const apic_id: u32 = bytes[offset + 3];
                const flags: u32 = @as(u32, bytes[offset + 4]) | (@as(u32, bytes[offset + 5]) << 8) |
                    (@as(u32, bytes[offset + 6]) << 16) | (@as(u32, bytes[offset + 7]) << 24);
                if (flags & 1 != 0) {
                    var duplicate = false;
                    for (info.cpu_apic_ids[0..info.cpu_count]) |known_id| {
                        if (known_id == apic_id) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate and info.cpu_count < cpu_capacity.MAX_CPUS) {
                        info.cpu_apic_ids[info.cpu_count] = apic_id;
                        info.cpu_count += 1;
                    }
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
        } else if (entry_type == 2) {
            // MADT ISO entry: type(1) + len(1) + bus(1) + source_irq(1) + gsi(4) + flags(2)
            if (offset + 10 <= hdr_len) {
                const gsi: u32 = @as(u32, bytes[offset + 4]) | (@as(u32, bytes[offset + 5]) << 8) |
                    (@as(u32, bytes[offset + 6]) << 16) | (@as(u32, bytes[offset + 7]) << 24);
                const flags: u16 = @as(u16, bytes[offset + 8]) | (@as(u16, bytes[offset + 9]) << 8);
                if (!info.isos.add(.{
                    .bus = bytes[offset + 2],
                    .irq = bytes[offset + 3],
                    .gsi = gsi,
                    .flags = flags,
                })) {
                    serial.writeString("[ACPI] WARN: ISO table full; dropping MADT type-2 entry\n");
                }
            }
        } else if (entry_type == 9 and !warned_x2apic) {
            serial.writeString("[ACPI] WARN: skipping unsupported MADT x2APIC entries\n");
            warned_x2apic = true;
        }

        offset += entry_len;
    }

    serial.writeString("[ACPI] MADT: ");
    fmt.writeDecimal(info.cpu_count);
    serial.writeString(" CPUs, LAPIC=0x");
    fmt.writeHex(info.lapic_address);
    serial.writeString(", IOAPIC=0x");
    fmt.writeHex(info.ioapic_address);
    serial.writeString("\n");
}

fn parseMcfg(mcfg_phys: u64) void {
    const virt = hhdm.physToVirt(mcfg_phys);
    const bytes: [*]const u8 = @ptrFromInt(virt);

    // Read header.length
    const raw_len: u32 = @as(u32, bytes[4]) | (@as(u32, bytes[5]) << 8) |
        (@as(u32, bytes[6]) << 16) | (@as(u32, bytes[7]) << 24);

    // Clamp the firmware length to the mapped window — only one 2MiB huge
    // page is mapped per table (mapAcpiPage), so a corrupt length must not
    // walk entries past the mapped region.
    const window: u32 = 0x200000 - @as(u32, @intCast(mcfg_phys & 0x1FFFFF));
    const hdr_len: u32 = @min(raw_len, window);

    var offset: u32 = @sizeOf(tables.Mcfg);
    while (offset + @sizeOf(tables.McfgAllocation) <= hdr_len) {
        // Read MCFG allocation entry fields manually
        const base_addr = bo.readU64At(bytes, offset);
        const seg_group = bo.readU16Le(bytes[offset + 8 .. offset + 10]);
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
    fmt.writeHex(info.mcfg_base);
    serial.writeString("\n");
}
