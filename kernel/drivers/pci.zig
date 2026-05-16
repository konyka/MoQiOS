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

const serial = @import("../arch/x86_64/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const hhdm = @import("../mm/hhdm.zig");
const acpi = @import("../acpi/acpi_parser.zig");

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
var devices: [MAX_PCI_DEVICES]PciDevice = undefined;
var device_count: u32 = 0;

/// PCIe MMIO base address (from MCFG). 0 means use legacy I/O ports.
var pcie_ecam_base: u64 = 0;

/// Initialize PCI subsystem.
pub fn init() void {
    pcie_ecam_base = acpi.info.mcfg_base;
    if (pcie_ecam_base != 0) {
        serial.writeString("[PCI] Using PCIe ECAM at 0x");
        writeHex(pcie_ecam_base);
        serial.writeString("\n");
    } else {
        serial.writeString("[PCI] Using legacy I/O port configuration\n");
    }

    device_count = 0;
    enumerateBuses();
    serial.writeString("[PCI] Found ");
    writeDecimal(device_count);
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
            writeDecimal(secondary_bus);
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

/// Print device information.
fn printDevice(dev: *const PciDevice) void {
    serial.writeString("  [PCI] ");
    writeDecimal(dev.bus);
    serial.writeString(":");
    writeDecimal(dev.device);
    serial.writeString(".");
    writeDecimal(dev.function);
    serial.writeString(" ");
    writeHex16(dev.vendor_id);
    serial.writeString(":");
    writeHex16(dev.device_id);
    serial.writeString(" class=");
    writeHex8(dev.class_code);
    serial.writeString(":");
    writeHex8(dev.subclass);
    if (dev.irq_pin != 0) {
        serial.writeString(" irq=");
        writeDecimal(dev.irq_line);
    }
    // Print BAR info
    for (0..6) |i| {
        if (dev.bars[i] != 0) {
            serial.writeString(" bar");
            serial.writeString(&[_]u8{ '0' + @as(u8, @intCast(i)) });
            serial.writeString("=0x");
            writeHex(dev.bars[i]);
        }
    }
    serial.writeString("\n");
}

// Formatting helpers — write directly to serial
fn writeHex(value: u64) void {
    var buf: [16]u8 = @splat('0');
    var v = value;
    var start: usize = 0;
    // Find first non-zero nibble (or use last position if value is 0)
    if (value != 0) {
        const tmp = value;
        var leading = true;
        for (0..16) |idx| {
            const shift_amt: u6 = @intCast((15 - idx) * 4);
            const nibble: u8 = @intCast((tmp >> shift_amt) & 0xF);
            if (leading and nibble == 0) continue;
            leading = false;
            start = idx;
            break;
        }
    }
    // Fill from end
    var i: usize = 15;
    while (true) : (i -= 1) {
        const nibble: u8 = @intCast(v & 0xF);
        buf[i] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
        v >>= 4;
        if (i == 0) break;
    }
    serial.writeString(buf[start..16]);
}

fn writeHex16(value: u16) void {
    var buf: [4]u8 = @splat('0');
    var v = value;
    var i: usize = 3;
    while (true) : (i -= 1) {
        const nibble: u8 = @intCast(v & 0xF);
        buf[i] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
        v >>= 4;
        if (i == 0) break;
    }
    serial.writeString(&buf);
}

fn writeHex8(value: u8) void {
    const hi: u8 = value >> 4;
    const lo: u8 = value & 0xF;
    const buf = [2]u8{
        if (hi < 10) '0' + hi else 'a' + hi - 10,
        if (lo < 10) '0' + lo else 'a' + lo - 10,
    };
    serial.writeString(&buf);
}

fn writeDecimal(value: u32) void {
    if (value == 0) {
        serial.writeString("0");
        return;
    }
    var buf: [10]u8 = undefined;
    var v = value;
    var i: usize = 0;
    while (v > 0 and i < 10) : (i += 1) {
        buf[i] = @intCast(v % 10 + '0');
        v /= 10;
    }
    // Reverse in place
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    serial.writeString(buf[0..i]);
}
