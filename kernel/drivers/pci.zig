/// PCI/PCIe enumeration and configuration.
///
/// Supports both:
///   - Legacy PCI configuration via I/O ports (0xCF8/0xCFC)
///   - PCIe Enhanced Configuration via MMIO (MCFG base)
///
/// Provides:
///   - Bus/device/function scanning
///   - Vendor/device ID, class code extraction
///   - BAR (Base Address Register) detection
///   - Device listing for driver matching
const builtin = @import("builtin");
const serial = @import("../arch/arch.zig").serial;
const io = @import("../arch/arch.zig").io;
const hhdm = @import("../mm/hhdm.zig");
const acpi = @import("../acpi/acpi_parser.zig");
const fmt = @import("../lib/fmt.zig");
const pci_msix = @import("pci_msix.zig");

pub const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
pub const PCI_CONFIG_DATA: u16 = 0xCFC;

pub const PCI_MAX_BUSES: u8 = 32; // Limit scan for performance
pub const PCI_MAX_DEVICES: u8 = 32;
pub const PCI_MAX_FUNCTIONS: u8 = 8;

pub const MAX_PCI_DEVICES: u32 = 64;

/// PCI device class codes (partial).
pub const ClassCode = enum(u8) {
    legacy = 0x00,
    mass_storage = 0x01,
    network = 0x02,
    display = 0x03,
    multimedia = 0x04,
    memory = 0x05,
    bridge = 0x06,
    comm = 0x07,
    peripheral = 0x08,
    input = 0x09,
    docking = 0x0A,
    processor = 0x0B,
    serial_bus = 0x0C,
    wireless = 0x0D,
    intelligent = 0x0E,
    satellite = 0x0F,
    encryption = 0x10,
    signal = 0x11,
    _,
};

/// Known PCI vendor IDs.
pub const VENDOR_INTEL: u16 = 0x8086;
pub const VENDOR_AMD: u16 = 0x1022;
pub const VENDOR_QEMU_VIRTIO: u16 = 0x1AF4;
pub const VENDOR_REDHAT: u16 = 0x1B36;
pub const VENDOR_INVALID: u16 = 0xFFFF;

/// PCI device information.
pub const PciDevice = struct {
    bus: u8,
    device: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    header_type: u8,
    irq_pin: u8,
    irq_line: u8,
    bars: [6]u64,
    bar_sizes: [6]u64,
};

/// List of discovered PCI devices.
pub var devices: [MAX_PCI_DEVICES]PciDevice = undefined;
pub var device_count: u32 = 0;

/// PCIe MMIO base address (from MCFG). 0 means use legacy I/O ports.
var pcie_ecam_base: u64 = 0;

/// Initialize PCI subsystem.
pub fn init() void {
    if (comptime builtin.cpu.arch != .x86_64) {
        device_count = 0;
        serial.writeString("[PCI] non-x86: enumeration stub\n");
    } else {
        initX86();
    }
}

fn initX86() void {
    pcie_ecam_base = acpi.info.mcfg_base;
    if (pcie_ecam_base != 0) {
        serial.writeString("[PCI] Using PCIe ECAM at 0x");
        fmt.writeHex(pcie_ecam_base);
        serial.writeString("\n");
    } else {
        serial.writeString("[PCI] Using legacy I/O port configuration\n");
    }

    device_count = 0;
    enumerateBuses();
    serial.writeString("[PCI] Found ");
    fmt.writeDecimal(device_count);
    serial.writeString(" devices\n");
}

/// Read a 32-bit value from PCI configuration space.
pub fn configRead32(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    if (pcie_ecam_base != 0) {
        return configReadMMIO(bus, dev, func, offset);
    }
    return configReadIO(bus, dev, func, offset);
}

/// Write a 32-bit value to PCI configuration space.
pub fn configWrite32(bus: u8, dev: u8, func: u8, offset: u8, value: u32) void {
    if (pcie_ecam_base != 0) {
        configWriteMMIO(bus, dev, func, offset, value);
        return;
    }
    configWriteIO(bus, dev, func, offset, value);
}

/// Legacy I/O port PCI config read.
fn configReadIO(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    const addr: u32 = (@as(u32, bus) << 16) |
        (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC) |
        0x8000_0000;
    io.outl(PCI_CONFIG_ADDRESS, addr);
    io.ioWait();
    return io.inl(PCI_CONFIG_DATA);
}

/// Legacy I/O port PCI config write.
fn configWriteIO(bus: u8, dev: u8, func: u8, offset: u8, value: u32) void {
    const addr: u32 = (@as(u32, bus) << 16) |
        (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC) |
        0x8000_0000;
    io.outl(PCI_CONFIG_ADDRESS, addr);
    io.ioWait();
    io.outl(PCI_CONFIG_DATA, value);
}

/// PCIe ECAM MMIO config read.
fn configReadMMIO(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    const base_bus = acpi.info.mcfg_start_bus;
    const virt = pcie_ecam_base +
        (@as(u64, bus - base_bus) << 20) |
        (@as(u64, dev) << 15) |
        (@as(u64, func) << 12) |
        (@as(u64, offset) & 0xFC);
    // Map the page if not already mapped — for now assume it's identity-mapped via HHDM
    const ptr: *const volatile u32 = @ptrFromInt(hhdm.physToVirt(virt));
    return ptr.*;
}

/// PCIe ECAM MMIO config write.
fn configWriteMMIO(bus: u8, dev: u8, func: u8, offset: u8, value: u32) void {
    const base_bus = acpi.info.mcfg_start_bus;
    const virt = pcie_ecam_base +
        (@as(u64, bus - base_bus) << 20) |
        (@as(u64, dev) << 15) |
        (@as(u64, func) << 12) |
        (@as(u64, offset) & 0xFC);
    const ptr: *volatile u32 = @ptrFromInt(hhdm.physToVirt(virt));
    ptr.* = value;
}

/// Enumerate all PCI buses.
fn enumerateBuses() void {
    var bus: u8 = 0;
    while (bus < PCI_MAX_BUSES) : (bus += 1) {
        enumerateBus(bus);
    }
}

/// Scan a single bus for devices.
fn enumerateBus(bus: u8) void {
    var dev: u8 = 0;
    while (dev < PCI_MAX_DEVICES) : (dev += 1) {
        scanDevice(bus, dev);
    }
}

/// Check a device and enumerate its functions.
fn scanDevice(bus: u8, dev: u8) void {
    const vendor = getVendorId(bus, dev, 0);
    if (vendor == VENDOR_INVALID) return;

    const header_type = getHeaderType(bus, dev, 0);
    if (header_type & 0x80 != 0) {
        // Multi-function device
        var func: u8 = 0;
        while (func < PCI_MAX_FUNCTIONS) : (func += 1) {
            if (getVendorId(bus, dev, func) != VENDOR_INVALID) {
                probeFunction(bus, dev, func);
            }
        }
    } else {
        probeFunction(bus, dev, 0);
    }
}

/// Probe a single function and add it to the device list.
fn probeFunction(bus: u8, dev: u8, func: u8) void {
    if (device_count >= MAX_PCI_DEVICES) return;

    const vendor_id = getVendorId(bus, dev, func);
    const device_id = getDeviceId(bus, dev, func);
    const class_reg = configRead32(bus, dev, func, 0x08);
    const revision: u8 = @truncate(class_reg);
    const prog_if: u8 = @truncate(class_reg >> 8);
    const subclass: u8 = @truncate(class_reg >> 16);
    const class_code: u8 = @truncate(class_reg >> 24);
    const header_type = getHeaderType(bus, dev, func);

    var irq_pin: u8 = 0;
    var irq_line: u8 = 0;
    if (header_type & 0x7F == 0) {
        const irq_reg = configRead32(bus, dev, func, 0x3C);
        irq_pin = @truncate(irq_reg >> 8);
        irq_line = @truncate(irq_reg);
    }

    var pci_dev = PciDevice{
        .bus = bus,
        .device = dev,
        .function = func,
        .vendor_id = vendor_id,
        .device_id = device_id,
        .class_code = class_code,
        .subclass = subclass,
        .prog_if = prog_if,
        .revision = revision,
        .header_type = header_type,
        .irq_pin = irq_pin,
        .irq_line = irq_line,
        .bars = .{0} ** 6,
        .bar_sizes = .{0} ** 6,
    };

    // Read BARs (only for type 0 headers)
    if ((header_type & 0x7F) == 0) {
        readBars(&pci_dev);
    }

    // Print device info
    printDevice(&pci_dev);

    devices[device_count] = pci_dev;
    device_count += 1;

    // If this is a PCI-to-PCI bridge, recursively scan secondary bus
    if (class_code == 0x06 and subclass == 0x04) {
        const bridge_reg = configRead32(bus, dev, func, 0x18);
        const secondary_bus: u8 = @truncate(bridge_reg >> 8);
        if (secondary_bus > bus and secondary_bus < PCI_MAX_BUSES) {
            serial.writeString("[PCI] Bridge to secondary bus ");
            fmt.writeDecimal(secondary_bus);
            serial.writeString("\n");
            enumerateBus(secondary_bus);
        }
    }
}

/// Read all BARs for a device and determine sizes.
fn readBars(dev: *PciDevice) void {
    for (0..6) |i| {
        const bar_offset: u8 = @intCast(0x10 + i * 4);
        const bar_orig = configRead32(dev.bus, dev.device, dev.function, bar_offset);

        if (bar_orig == 0) {
            dev.bars[i] = 0;
            dev.bar_sizes[i] = 0;
            continue;
        }

        // Determine if memory or I/O space
        const is_io = (bar_orig & 1) != 0;
        const is_64bit = !is_io and (bar_orig & 0x6) == 0x4;

        // Write all 1s to get size
        configWrite32(dev.bus, dev.device, dev.function, bar_offset, 0xFFFF_FFFF);
        const bar_size_raw = configRead32(dev.bus, dev.device, dev.function, bar_offset);

        // Restore original BAR value
        configWrite32(dev.bus, dev.device, dev.function, bar_offset, bar_orig);

        if (bar_size_raw == 0) continue;

        if (is_io) {
            const size = ~(bar_size_raw & 0xFFFC) +% 1;
            dev.bars[i] = bar_orig & 0xFFFC;
            dev.bar_sizes[i] = size & 0xFFFF;
        } else {
            const prefetchable = (bar_orig & 0x8) != 0;
            _ = prefetchable;
            if (is_64bit and i < 5) {
                // Read upper 32 bits
                const bar_upper = configRead32(dev.bus, dev.device, dev.function, bar_offset + 4);
                const bar_full: u64 = @as(u64, bar_upper) << 32 | (bar_orig & 0xFFFF_FFF0);

                // Size upper
                configWrite32(dev.bus, dev.device, dev.function, bar_offset + 4, 0xFFFF_FFFF);
                const size_upper = configRead32(dev.bus, dev.device, dev.function, bar_offset + 4);
                configWrite32(dev.bus, dev.device, dev.function, bar_offset + 4, bar_upper);

                const size_full = ~(@as(u64, size_upper) << 32 | (bar_size_raw & 0xFFFF_FFF0)) +% 1;
                dev.bars[i] = bar_full;
                dev.bar_sizes[i] = size_full;
            } else {
                const size = ~(bar_size_raw & 0xFFFF_FFF0) +% 1;
                dev.bars[i] = bar_orig & 0xFFFF_FFF0;
                dev.bar_sizes[i] = size & 0xFFFF_FFFF;
            }
        }
    }
}

/// Helper functions to extract common fields.
fn getVendorId(bus: u8, dev: u8, func: u8) u16 {
    return @truncate(configRead32(bus, dev, func, 0x00));
}

fn getDeviceId(bus: u8, dev: u8, func: u8) u16 {
    return @truncate(configRead32(bus, dev, func, 0x00) >> 16);
}

fn getHeaderType(bus: u8, dev: u8, func: u8) u8 {
    return @truncate(configRead32(bus, dev, func, 0x0C) >> 16);
}

/// Get number of discovered devices.
pub fn getDeviceCount() u32 {
    return device_count;
}

/// Get device by index.
pub fn getDevice(idx: u32) ?*const PciDevice {
    if (idx >= device_count) return null;
    return &devices[idx];
}

/// Find device by vendor/device ID.
pub fn findByVendorDevice(vendor: u16, device_id: u16) ?*const PciDevice {
    for (0..device_count) |i| {
        if (devices[i].vendor_id == vendor and devices[i].device_id == device_id) {
            return &devices[i];
        }
    }
    return null;
}

/// Find device by class code.
pub fn findByClass(class: u8, subclass: u8) ?*const PciDevice {
    for (0..device_count) |i| {
        if (devices[i].class_code == class and devices[i].subclass == subclass) {
            return &devices[i];
        }
    }
    return null;
}

// ─── MSI-X Support ───────────────────────────────────────────────────────

/// Walk a device's PCI capability list and return the offset of capability
/// `cap_id`, or null if absent. Thin config-space wrapper over the pure
/// parsing helpers in pci_msix.zig (host-tested there).
pub fn findCapability(bus: u8, dev: u8, func: u8, cap_id: u8) ?u8 {
    // Status register (upper half of the dword at 0x04), bit 4: caps list.
    const status_cmd = configRead32(bus, dev, func, 0x04);
    if ((status_cmd & (1 << 20)) == 0) return null;

    var off: u8 = @truncate(configRead32(bus, dev, func, 0x34) & 0xFC);
    var steps: u32 = 0;
    while (off != 0 and steps < 48) : (steps += 1) {
        const reg = configRead32(bus, dev, func, off);
        if (@as(u8, @truncate(reg)) == cap_id) return off;
        off = @truncate((reg >> 8) & 0xFC);
    }
    return null;
}

/// A located MSI-X capability with its table mapped into kernel space.
pub const MsixTable = struct {
    info: pci_msix.MsixInfo,
    cap_offset: u8,
    /// HHDM virtual address of the first table entry.
    table_virt: u64,
};

/// Locate the device's MSI-X capability and map the table BAR through the
/// HHDM (same mapping approach as other MMIO in the tree). Returns null when
/// the device has no MSI-X capability or the table BAR is unassigned.
pub fn msixLocate(dev: *const PciDevice) ?MsixTable {
    const cap_offset = findCapability(dev.bus, dev.device, dev.function, pci_msix.CAP_ID_MSIX) orelse
        return null;

    const msg_control: u16 = @truncate(configRead32(dev.bus, dev.device, dev.function, cap_offset) >> 16);
    const table_reg = configRead32(dev.bus, dev.device, dev.function, cap_offset + 4);
    const pba_reg = configRead32(dev.bus, dev.device, dev.function, cap_offset + 8);
    const info = pci_msix.parseMsixRegs(msg_control, table_reg, pba_reg);
    if (info.table_size == 0 or info.table_bir > 5) return null;

    const bar_phys = dev.bars[info.table_bir];
    if (bar_phys == 0) return null;
    const table_phys = bar_phys + info.table_offset;

    // Map the table page(s) into the kernel address space via HHDM.
    // mapPage fails harmlessly when the page is already HHDM-mapped.
    const paging = @import("../arch/arch.zig").paging;
    const kernel_pml4 = paging.getKernelPml4();
    const map_flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    const table_bytes = @as(u64, info.table_size) * 16;
    const map_pages = @max((table_bytes + (table_phys & 0xFFF) + 4095) / 4096, 1);
    const base_phys = table_phys & ~@as(u64, 0xFFF);
    for (0..map_pages) |i| {
        paging.mapPage(kernel_pml4, hhdm.physToVirt(base_phys + i * 4096), base_phys + i * 4096, map_flags) catch {};
    }

    return .{
        .info = info,
        .cap_offset = cap_offset,
        .table_virt = hhdm.physToVirt(table_phys),
    };
}

/// Program one MSI-X table entry with a message address/data pair and
/// unmask it (vector control bit 0 = 0).
pub fn msixProgramVector(table: *const MsixTable, index: u16, msg_addr: u64, msg_data: u32) void {
    if (index >= table.info.table_size) return;
    const entry = table.table_virt + @as(u64, index) * 16;
    const lo: *volatile u32 = @ptrFromInt(entry);
    const hi: *volatile u32 = @ptrFromInt(entry + 4);
    const data: *volatile u32 = @ptrFromInt(entry + 8);
    const ctrl: *volatile u32 = @ptrFromInt(entry + 12);
    lo.* = @truncate(msg_addr);
    hi.* = @truncate(msg_addr >> 32);
    data.* = msg_data;
    ctrl.* = 0; // unmask
}

/// Enable MSI-X delivery: set the enable bit and clear the function mask in
/// the capability message control, then disable legacy INTx (command bit 10)
/// so the device cannot raise both interrupt flavours at once.
pub fn msixEnable(dev: *const PciDevice, table: *const MsixTable) void {
    const reg = configRead32(dev.bus, dev.device, dev.function, table.cap_offset);
    var ctrl = reg & 0xFFFF_0000;
    ctrl |= 0x8000_0000; // MSI-X Enable (bit 15 of message control)
    ctrl &= ~@as(u32, 0x4000_0000); // Function Mask = 0
    configWrite32(dev.bus, dev.device, dev.function, table.cap_offset, ctrl);

    const cmd = configRead32(dev.bus, dev.device, dev.function, 0x04);
    configWrite32(dev.bus, dev.device, dev.function, 0x04, cmd | (1 << 10)); // INTx disable
}

/// Print device information.
fn printDevice(dev: *const PciDevice) void {
    serial.writeString("  [PCI] ");
    fmt.writeDecimal(dev.bus);
    serial.writeString(":");
    fmt.writeDecimal(dev.device);
    serial.writeString(".");
    fmt.writeDecimal(dev.function);
    serial.writeString(" ");
    fmt.writeHex16(dev.vendor_id);
    serial.writeString(":");
    fmt.writeHex16(dev.device_id);
    serial.writeString(" class=");
    fmt.writeHex8(dev.class_code);
    serial.writeString(":");
    fmt.writeHex8(dev.subclass);
    if (dev.irq_pin != 0) {
        serial.writeString(" irq=");
        fmt.writeDecimal(dev.irq_line);
    }
    // Print BAR info
    for (0..6) |i| {
        if (dev.bars[i] != 0) {
            serial.writeString(" bar");
            serial.writeString(&[_]u8{'0' + @as(u8, @intCast(i))});
            serial.writeString("=0x");
            fmt.writeHex(dev.bars[i]);
        }
    }
    serial.writeString("\n");
}
