/// Intel e1000 NIC driver for QEMU.
///
/// Provides basic packet send/receive via the e1000 MMIO interface.
/// Interrupt-driven RX: packets are processed in the IRQ handler.
const serial = @import("../arch/x86_64/serial.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const pmm = @import("../mm/pmm.zig");
const pci = @import("pci.zig");
const fmt = @import("../lib/fmt.zig");

// e1000 MMIO register offsets
const REG_CTRL: u32 = 0x0000;
const REG_STATUS: u32 = 0x0008;
const REG_EEPROM: u32 = 0x0014;
const REG_IMASK: u32 = 0x00D0;
const REG_ICR: u32 = 0x00C0; // Interrupt Cause Read
const REG_ITR: u32 = 0x00C4; // Interrupt Throttling Rate
const REG_RCTRL: u32 = 0x0100;
const REG_RXDESCLO: u32 = 0x2800;
const REG_RXDESCHI: u32 = 0x2804;
const REG_RXDESCLEN: u32 = 0x2808;
const REG_RXDESCHEAD: u32 = 0x2810;
const REG_RXDESCTAIL: u32 = 0x2818;
const REG_TCTRL: u32 = 0x0400;
const REG_TXDESCLO: u32 = 0x3800;
const REG_TXDESCHI: u32 = 0x3804;
const REG_TXDESCLEN: u32 = 0x3808;
const REG_TXDESCHEAD: u32 = 0x3810;
const REG_TXDESCTAIL: u32 = 0x3818;
const REG_TIPG: u32 = 0x0410;
const REG_RAL: u32 = 0x5400;
const REG_RAH: u32 = 0x5404;
const REG_MTA: u32 = 0x5200;

// CTRL bits
const CTRL_RST: u32 = 1 << 26;
const CTRL_SLU: u32 = 1 << 6;

// RCTRL bits
const RCTRL_EN: u32 = 1 << 1;
const RCTRL_BAM: u32 = 1 << 15;
const RCTRL_BSIZE_2048: u32 = 0;
const RCTRL_SECRC: u32 = 1 << 26;

// TCTRL bits
const TCTRL_EN: u32 = 1 << 1;
const TCTRL_PSP: u32 = 1 << 3;

// Descriptor status bits
const RX_DESC_DD: u16 = 0x01;
const TX_DESC_DD: u8 = 0x01;
const TX_DESC_EOP: u8 = 0x01;
const TX_DESC_IFCS: u8 = 0x02;
const TX_DESC_RS: u8 = 0x08;

// IMASK bits
const IMS_TXDW: u32 = 1 << 0; // Transmit Descriptor Writeback
const IMS_TXQE: u32 = 1 << 1; // Transmit Queue Empty
const IMS_LSC: u32 = 1 << 2; // Link Status Change
const IMS_RXO: u32 = 1 << 6; // Receiver Overrun
const IMS_RXT0: u32 = 1 << 7; // Receiver Timer Interrupt

const NUM_RX_DESC: u32 = 32;
const NUM_TX_DESC: u32 = 32;

/// Legacy RX descriptor (16 bytes).
pub const RxDesc = extern struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};
comptime {
    if (@sizeOf(RxDesc) != 16) @compileError("RxDesc must be 16 bytes");
}

/// Legacy TX descriptor (16 bytes).
pub const TxDesc = extern struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};
comptime {
    if (@sizeOf(TxDesc) != 16) @compileError("TxDesc must be 16 bytes");
}

var mmio_base: u64 = 0;
var mac_addr: [6]u8 = @splat(0);

var rx_desc_phys: u64 = 0;
var rx_desc_virt: u64 = 0;
var rx_buf_phys: [NUM_RX_DESC]u64 = @splat(0);
var rx_buf_virt: [NUM_RX_DESC]u64 = @splat(0);
var rx_tail: u32 = 0;

var tx_desc_phys: u64 = 0;
var tx_desc_virt: u64 = 0;
var tx_buf_phys: [NUM_TX_DESC]u64 = @splat(0);
var tx_buf_virt: [NUM_TX_DESC]u64 = @splat(0);
var tx_tail: u32 = 0;

var initialized: bool = false;
var irq_line: u8 = 0; // PCI IRQ line for this device

fn readReg(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    return addr.*;
}

fn writeReg(offset: u32, value: u32) void {
    const addr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    addr.* = value;
}

pub fn init() void {
    serial.writeString("[e1000] Scanning for e1000 NIC...\n");

    for (0..pci.device_count) |i| {
        const dev = pci.devices[i];
        if (dev.vendor_id == pci.VENDOR_INTEL and (dev.device_id == 0x100E or dev.device_id == 0x10D3)) {
            serial.writeString("[e1000] Found at ");
            fmt.writeHex8(dev.bus);
            serial.writeString(":");
            fmt.writeHex8(dev.device);
            serial.writeString(".");
            fmt.writeHex8(dev.function);
            serial.writeString("\n");
            initDevice(&dev) catch |err| {
                serial.writeString("[e1000] Init failed: ");
                serial.writeString(@errorName(err));
                serial.writeString("\n");
            };
            return;
        }
    }
    serial.writeString("[e1000] No device found\n");
}

fn initDevice(dev: *const pci.PciDevice) !void {
    // Enable bus mastering (bit 2) in PCI command register, keep INTx enabled
    const cmd = pci.configRead32(dev.bus, dev.device, dev.function, 0x04);
    pci.configWrite32(dev.bus, dev.device, dev.function, 0x04, (cmd & ~@as(u32, 0x400)) | 0x04);

    // Read IRQ line from PCI config
    irq_line = @truncate(pci.configRead32(dev.bus, dev.device, dev.function, 0x3C));

    // Map BAR0 (MMIO)
    const bar0 = dev.bars[0];
    if (bar0 == 0) return error.NoBAR;
    const bar_phys = bar0 & 0xFFFF_FFFF_FFFF_FFF0;
    const bar_virt = hhdm.physToVirt(bar_phys);

    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
        .write_through = true,
        .cache_disable = true,
    };

    // Map enough pages for e1000 MMIO (128KB typically)
    var off: u64 = 0;
    while (off < 0x20000) : (off += paging.PAGE_SIZE) {
        paging.mapPage(pml4, bar_virt + off, bar_phys + off, flags) catch {};
    }

    mmio_base = bar_virt;

    // Reset the NIC
    writeReg(REG_CTRL, readReg(REG_CTRL) | CTRL_RST);
    var timeout: u32 = 1_000_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((readReg(REG_CTRL) & CTRL_RST) == 0) break;
        asm volatile ("pause");
    }
    if (timeout == 0) {
        serial.writeString("[e1000] Reset timed out\n");
        return error.ResetTimeout;
    }

    // Set Set Link Up
    writeReg(REG_CTRL, readReg(REG_CTRL) | CTRL_SLU);

    // Enable RX/TX interrupts
    writeReg(REG_IMASK, IMS_RXT0 | IMS_RXO | IMS_TXQE | IMS_TXDW | IMS_LSC);
    // Clear any pending interrupts
    _ = readReg(REG_ICR);

    // Read MAC address from EEPROM
    readMAC();

    serial.writeString("[e1000] MAC: ");
    for (0..6) |i| {
        if (i > 0) serial.writeByte(':');
        fmt.writeHex8(mac_addr[i]);
    }
    serial.writeString("\n");

    // Program Receive Address Register (RAL/RAH) with our MAC + AV bit
    const ral: u32 = @as(u32, mac_addr[0]) | (@as(u32, mac_addr[1]) << 8) |
        (@as(u32, mac_addr[2]) << 16) | (@as(u32, mac_addr[3]) << 24);
    const rah: u32 = @as(u32, mac_addr[4]) | (@as(u32, mac_addr[5]) << 8) | 0x80000000;
    writeReg(REG_RAL, ral);
    writeReg(REG_RAH, rah);

    // Clear Multicast Table Array (128 entries)
    for (0..128) |i| {
        writeReg(REG_MTA + @as(u32, @intCast(i)) * 4, 0);
    }

    // Setup RX and TX descriptor rings
    try setupRX();
    try setupTX();

    // Enable receive: EN | BAM | BSIZE_2048 | SECRC
    writeReg(REG_RCTRL, readReg(REG_RCTRL) | RCTRL_EN | RCTRL_BAM | RCTRL_BSIZE_2048 | RCTRL_SECRC);

    // Enable transmit: EN | PSP
    writeReg(REG_TCTRL, readReg(REG_TCTRL) | TCTRL_EN | TCTRL_PSP);

    // Program TX Inter-Packet Gap
    writeReg(REG_TIPG, 10 | (4 << 10) | (6 << 20));

    initialized = true;
    serial.writeString("[e1000] Initialized\n");
}

fn readMAC() void {
    // Try EEPROM first
    var mac_ok = false;
    writeReg(REG_EEPROM, 1); // Start EEPROM read
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((readReg(REG_EEPROM) & (1 << 4)) != 0) {
            mac_ok = true;
            break;
        }
        asm volatile ("pause");
    }

    if (mac_ok) {
        for (0..3) |i| {
            writeReg(REG_EEPROM, 1 | (@as(u32, @intCast(i)) << 8));
            timeout = 100_000;
            while (timeout > 0) : (timeout -= 1) {
                if ((readReg(REG_EEPROM) & (1 << 4)) != 0) break;
                asm volatile ("pause");
            }
            const word: u16 = @truncate(readReg(REG_EEPROM) >> 16);
            mac_addr[i * 2] = @truncate(word);
            mac_addr[i * 2 + 1] = @truncate(word >> 8);
        }
    } else {
        // Read from RAL/RAH registers
        const ral = readReg(REG_RAL);
        const rah = readReg(REG_RAH);
        mac_addr[0] = @truncate(ral);
        mac_addr[1] = @truncate(ral >> 8);
        mac_addr[2] = @truncate(ral >> 16);
        mac_addr[3] = @truncate(ral >> 24);
        mac_addr[4] = @truncate(rah);
        mac_addr[5] = @truncate(rah >> 8);
    }
}

fn setupRX() !void {
    // Allocate RX descriptor ring
    const desc_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const desc_virt = hhdm.physToVirt(desc_phys);
    var dptr: [*]u8 = @ptrFromInt(desc_virt);
    @memset(dptr[0..paging.PAGE_SIZE], 0);
    rx_desc_phys = desc_phys;
    rx_desc_virt = desc_virt;

    // Allocate packet buffers
    for (0..NUM_RX_DESC) |i| {
        const buf_phys = pmm.allocPage() orelse return error.OutOfMemory;
        const buf_virt = hhdm.physToVirt(buf_phys);
        var bptr: [*]u8 = @ptrFromInt(buf_virt);
        @memset(bptr[0..paging.PAGE_SIZE], 0);
        rx_buf_phys[i] = buf_phys;
        rx_buf_virt[i] = buf_virt;

        // Set up descriptor
        const desc: *volatile RxDesc = @ptrFromInt(desc_virt + i * @sizeOf(RxDesc));
        desc.addr = buf_phys;
        desc.status = 0;
    }

    // Program registers
    writeReg(REG_RXDESCLO, @truncate(desc_phys));
    writeReg(REG_RXDESCHI, @truncate(desc_phys >> 32));
    writeReg(REG_RXDESCLEN, NUM_RX_DESC * @sizeOf(RxDesc));
    writeReg(REG_RXDESCHEAD, 0);
    writeReg(REG_RXDESCTAIL, NUM_RX_DESC - 1);

    rx_tail = NUM_RX_DESC - 1;
}

fn setupTX() !void {
    const desc_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const desc_virt = hhdm.physToVirt(desc_phys);
    var dptr: [*]u8 = @ptrFromInt(desc_virt);
    @memset(dptr[0..paging.PAGE_SIZE], 0);
    tx_desc_phys = desc_phys;
    tx_desc_virt = desc_virt;

    for (0..NUM_TX_DESC) |i| {
        const buf_phys = pmm.allocPage() orelse return error.OutOfMemory;
        const buf_virt = hhdm.physToVirt(buf_phys);
        var bptr: [*]u8 = @ptrFromInt(buf_virt);
        @memset(bptr[0..paging.PAGE_SIZE], 0);
        tx_buf_phys[i] = buf_phys;
        tx_buf_virt[i] = buf_virt;

        const desc: *volatile TxDesc = @ptrFromInt(desc_virt + i * @sizeOf(TxDesc));
        desc.addr = buf_phys;
        desc.status = TX_DESC_DD; // Mark as done (available)
    }

    writeReg(REG_TXDESCLO, @truncate(desc_phys));
    writeReg(REG_TXDESCHI, @truncate(desc_phys >> 32));
    writeReg(REG_TXDESCLEN, NUM_TX_DESC * @sizeOf(TxDesc));
    writeReg(REG_TXDESCHEAD, 0);
    writeReg(REG_TXDESCTAIL, 0);

    tx_tail = 0;
}

/// Receive a packet. Returns packet length or 0 if no packet available.
pub fn receivePacket(buf: [*]u8, max_len: u32) u32 {
    if (!initialized) return 0;

    const next = (rx_tail + 1) % NUM_RX_DESC;
    const desc: *volatile RxDesc = @ptrFromInt(rx_desc_virt + next * @sizeOf(RxDesc));

    if ((desc.status & RX_DESC_DD) == 0) return 0;

    const len = @min(desc.length, max_len);
    const src: [*]const u8 = @ptrFromInt(rx_buf_virt[next]);
    @memcpy(buf[0..len], src[0..len]);

    // Re-arm descriptor
    desc.status = 0;
    rx_tail = next;
    writeReg(REG_RXDESCTAIL, rx_tail);

    return len;
}

/// Send a raw packet.
pub fn sendPacket(data: [*]const u8, len: u32) bool {
    if (!initialized or len == 0 or len > 2048) return false;

    const desc: *volatile TxDesc = @ptrFromInt(tx_desc_virt + tx_tail * @sizeOf(TxDesc));

    // Wait for descriptor to be available
    if ((desc.status & TX_DESC_DD) == 0) {
        return false;
    }

    // Copy data to TX buffer
    const dst: [*]u8 = @ptrFromInt(tx_buf_virt[tx_tail]);
    @memcpy(dst[0..len], data[0..len]);

    desc.addr = tx_buf_phys[tx_tail];
    desc.length = @intCast(len);
    desc.cso = 0;
    desc.cmd = TX_DESC_EOP | TX_DESC_IFCS | TX_DESC_RS;
    desc.status = 0;
    desc.css = 0;
    desc.special = 0;

    tx_tail = (tx_tail + 1) % NUM_TX_DESC;
    writeReg(REG_TXDESCTAIL, tx_tail);

    return true;
}

pub fn isActive() bool {
    return initialized;
}

pub fn getMAC() [6]u8 {
    return mac_addr;
}

pub fn getIrqLine() u8 {
    return irq_line;
}

/// IRQ handler — called from idt.zig when e1000 raises an interrupt.
/// Reads ICR to clear interrupts, processes received packets,
/// and feeds them into the network stack.
pub fn handleInterrupt() void {
    if (!initialized) return;

    // Read and clear interrupt cause
    const icr = readReg(REG_ICR);
    if (icr == 0) return;

    // Process all available received packets
    const net = @import("../net/mod.zig");
    var rx_tmp: [2048]u8 = undefined;
    var count: u32 = 0;
    while (count < NUM_RX_DESC) : (count += 1) {
        const n = receivePacket(&rx_tmp, 2048);
        if (n == 0) break;
        net.handleRxPacket(&rx_tmp, n);
    }
}
