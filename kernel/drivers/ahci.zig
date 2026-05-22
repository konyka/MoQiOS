/// AHCI (Advanced Host Controller Interface) SATA driver.
///
/// Detects AHCI controllers via PCI class 01:06:01, initializes the HBA,
/// enumerates ports, and provides sector read/write operations.
///
/// QEMU exposes Intel ICH9 AHCI (8086:2922) at PCI 0:31.2.

const serial = @import("../arch/x86_64/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const pmm = @import("../mm/pmm.zig");
const pci = @import("pci.zig");
const main_mod = @import("../main.zig");

// AHCI port register offsets (relative to port base)
pub const PORT_CLB: u32 = 0x00;
pub const PORT_CLBU: u32 = 0x04;
pub const PORT_FB: u32 = 0x08;
pub const PORT_FBU: u32 = 0x0C;
pub const PORT_IS: u32 = 0x10;
pub const PORT_IE: u32 = 0x14;
pub const PORT_CMD: u32 = 0x18;
pub const PORT_TFD: u32 = 0x20;
pub const PORT_SIG: u32 = 0x24;
pub const PORT_SSTS: u32 = 0x28;
pub const PORT_SCTL: u32 = 0x2C;
pub const PORT_SERR: u32 = 0x30;
pub const PORT_CI: u32 = 0x38;
pub const PORT_SACT: u32 = 0x34;

// HBA global register offsets
pub const HBA_CAP: u32 = 0x00;
pub const HBA_GHC: u32 = 0x04;
pub const HBA_IS: u32 = 0x08;
pub const HBA_PI: u32 = 0x0C;
pub const HBA_VS: u32 = 0x10;

// GHC bits
pub const GHC_AE: u32 = 1 << 31;
pub const GHC_IE: u32 = 1 << 1;
pub const GHC_HR: u32 = 1 << 0;

// CMD bits
pub const CMD_ST: u32 = 1 << 0;
pub const CMD_SUD: u32 = 1 << 1;
pub const CMD_POD: u32 = 1 << 2;
pub const CMD_CLO: u32 = 1 << 3;
pub const CMD_FRE: u32 = 1 << 4;
pub const CMD_FR: u32 = 1 << 14;
pub const CMD_CR: u32 = 1 << 15;

// SSTS device detection
pub const SSTS_DET_PRESENT: u32 = 0x3;

// Command FIS types
pub const FIS_TYPE_REG_H2D: u8 = 0x27;

// ATA commands
pub const ATA_READ_DMA_EXT: u8 = 0x25;
pub const ATA_WRITE_DMA_EXT: u8 = 0x35;
pub const ATA_IDENTIFY: u8 = 0xEC;

pub const MAX_AHCI_PORTS: u32 = 32;
pub const MAX_CMD_SLOTS: u32 = 32;
pub const SECTOR_SIZE: u32 = 512;

/// Command header (in command list).
pub const CmdHeader = extern struct {
    dw0: u32,
    dw1: u32,
    dw2: u32,
    dw3: u32,
    dw4: u32,
    reserved: [4]u32,
};

/// Physical Region Descriptor Table entry.
pub const PrdtEntry = extern struct {
    dba: u32,
    dbau: u32,
    reserved: u32,
    dw3: u32,
};

/// Command table (per slot).
pub const CmdTable = extern struct {
    cfis: [64]u8,
    atapi: [16]u8,
    reserved: [48]u8,
    prdt: [256]PrdtEntry,
};

/// Received FIS structure.
pub const RcvdFis = extern struct {
    dsfis: [28]u8,
    reserved0: [4]u8,
    psfis: [24]u8,
    reserved1: [8]u8,
    rfis: [24]u8,
    reserved2: [4]u8,
    sdbfis: [12]u8,
    reserved3: [116]u8,
};

comptime {
    // CmdTable must be 128 bytes for cfis+atapi+reserved, then PRDT follows
    // Total: 4096 bytes max (with 256 PRDT entries)
}

const AhciPort = struct {
    port_base: u64,
    port_idx: u32,
    cmd_list_phys: u64,
    cmd_list_virt: u64,
    fis_recv_phys: u64,
    fis_recv_virt: u64,
    cmd_tables_phys: [MAX_CMD_SLOTS]u64,
    cmd_tables_virt: [MAX_CMD_SLOTS]u64,
    cmd_count: u32,
    active: bool,
};

var hba_base: u64 = 0;
var cap: u32 = 0;
var num_cmd_slots: u32 = 0;
var ports: [MAX_AHCI_PORTS]AhciPort = @splat(.{
    .port_base = 0,
    .port_idx = 0,
    .cmd_list_phys = 0,
    .cmd_list_virt = 0,
    .fis_recv_phys = 0,
    .fis_recv_virt = 0,
    .cmd_tables_phys = @splat(0),
    .cmd_tables_virt = @splat(0),
    .cmd_count = 0,
    .active = false,
});
var active_port_count: u32 = 0;

fn readReg(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(hba_base + offset);
    return addr.*;
}

fn writeReg(offset: u32, value: u32) void {
    const addr: *volatile u32 = @ptrFromInt(hba_base + offset);
    addr.* = value;
}

fn readPort(port_base: u64, offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(port_base + offset);
    return addr.*;
}

fn writePort(port_base: u64, offset: u32, value: u32) void {
    const addr: *volatile u32 = @ptrFromInt(port_base + offset);
    addr.* = value;
}

pub fn init() void {
    serial.writeString("[ahci] Scanning for AHCI controllers...\n");

    var found = false;
    for (0..pci.device_count) |i| {
        const dev = pci.devices[i];
        if (dev.class_code == 0x01 and dev.subclass == 0x06 and dev.prog_if == 0x01) {
            serial.writeString("[ahci] Found AHCI controller at ");
            writeHex8(dev.bus);
            serial.writeString(":");
            writeHex8(dev.device);
            serial.writeString(".");
            writeHex8(dev.function);
            serial.writeString("\n");
            initController(&dev) catch |err| {
                serial.writeString("[ahci] Controller init failed: ");
                serial.writeString(@errorName(err));
                serial.writeString("\n");
            };
            found = true;
            break;
        }
    }

    if (!found) {
        serial.writeString("[ahci] No AHCI controller found\n");
    }
}

fn initController(dev: *const pci.PciDevice) !void {
    const abar = dev.bars[5];
    if (abar == 0) {
        serial.writeString("[ahci] ABAR (BAR5) is null\n");
        return error.NoABAR;
    }

    // Map ABAR region (typically 2KB for AHCI)
    const abar_phys = abar & 0xFFFFFFFFFFFFF000;
    const abar_size: u64 = 0x2000;
    const abar_virt = hhdm.physToVirt(abar_phys);

    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
        .write_through = true,
        .cache_disable = true,
    };

    // Map all pages of the ABAR region
    var offset: u64 = 0;
    while (offset < abar_size) : (offset += paging.PAGE_SIZE) {
        paging.mapPage(pml4, abar_virt + offset, abar_phys + offset, flags) catch {};
    }

    hba_base = abar_virt;

    cap = readReg(HBA_CAP);
    num_cmd_slots = ((cap >> 8) & 0x1F) + 1;
    const num_ports_impl = readReg(HBA_PI);

    serial.writeString("[ahci] CAP=0x");
    writeHex32(cap);
    serial.writeString(" cmd_slots=");
    writeDecimal(num_cmd_slots);
    serial.writeString(" PI=0x");
    writeHex32(num_ports_impl);
    serial.writeString("\n");

    // Enable AHCI
    var ghc = readReg(HBA_GHC);
    ghc |= GHC_AE;
    writeReg(HBA_GHC, ghc);

    // Reset the HBA
    writeReg(HBA_GHC, ghc | GHC_HR);
    var timeout: u32 = 1_000_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((readReg(HBA_GHC) & GHC_HR) == 0) break;
        asm volatile ("pause");
    }
    if (timeout == 0) {
        serial.writeString("[ahci] HBA reset timed out\n");
        return error.ResetTimeout;
    }

    // Re-enable AE after reset
    ghc = readReg(HBA_GHC);
    ghc |= GHC_AE;
    writeReg(HBA_GHC, ghc);

    // Disable interrupts for now (polling mode)
    writeReg(HBA_GHC, readReg(HBA_GHC) & ~GHC_IE);

    // Enumerate ports
    active_port_count = 0;
    var port_idx: u32 = 0;
    while (port_idx < MAX_AHCI_PORTS and port_idx < 32) : (port_idx += 1) {
        if ((num_ports_impl & (@as(u32, 1) << @intCast(port_idx))) == 0) continue;

        const port_base = hba_base + 0x100 + @as(u64, port_idx) * 0x80;
        const ssts = readPort(port_base, PORT_SSTS);

        serial.writeString("[ahci] Port ");
        writeDecimal(port_idx);
        serial.writeString(": SSTS=0x");
        writeHex32(ssts);

        const det = ssts & 0xF;
        const ipm = (ssts >> 8) & 0xF;
        if (det == SSTS_DET_PRESENT and ipm == 1) {
            const sig = readPort(port_base, PORT_SIG);
            serial.writeString(" SIG=0x");
            writeHex32(sig);

            if (sig == 0x00000101) {
                serial.writeString(" (SATA disk)");
                initPort(port_idx, port_base) catch |err| {
                    serial.writeString(" INIT FAILED: ");
                    serial.writeString(@errorName(err));
                };
            } else if (sig == 0xFFFFFFFF) {
                serial.writeString(" (initializing...)");
                initPort(port_idx, port_base) catch |err| {
                    serial.writeString(" INIT FAILED: ");
                    serial.writeString(@errorName(err));
                };
            }
        }
        serial.writeString("\n");
    }

    serial.writeString("[ahci] ");
    writeDecimal(active_port_count);
    serial.writeString(" active port(s)\n");
}

fn initPort(idx: u32, port_base: u64) !void {
    // Stop command engine
    stopCmd(port_base);

    // Allocate command list (1 page: holds up to 32 CmdHeaders × 32 bytes = 1024 bytes)
    const cmd_list_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const cmd_list_virt = hhdm.physToVirt(cmd_list_phys);

    // Zero the command list
    var cl_ptr: [*]u8 = @ptrFromInt(cmd_list_virt);
    @memset(cl_ptr[0..paging.PAGE_SIZE], 0);

    // Allocate FIS receive area (256 bytes, 1 page)
    const fis_phys = pmm.allocPage() orelse {
        pmm.freePage(cmd_list_phys);
        return error.OutOfMemory;
    };
    const fis_virt = hhdm.physToVirt(fis_phys);
    var fis_ptr: [*]u8 = @ptrFromInt(fis_virt);
    @memset(fis_ptr[0..paging.PAGE_SIZE], 0);

    // Set CLB and FB
    writePort(port_base, PORT_CLB, @truncate(cmd_list_phys));
    writePort(port_base, PORT_CLBU, @truncate(cmd_list_phys >> 32));
    writePort(port_base, PORT_FB, @truncate(fis_phys));
    writePort(port_base, PORT_FBU, @truncate(fis_phys >> 32));

    // Allocate command tables (one page per slot, up to num_cmd_slots)
    var slot: u32 = 0;
    var allocated_slots: u32 = 0;
    while (slot < num_cmd_slots) : (slot += 1) {
        const ct_phys = pmm.allocPage() orelse {
            // Rollback previously allocated tables
            var j: u32 = 0;
            while (j < allocated_slots) : (j += 1) {
                pmm.freePage(ports[idx].cmd_tables_phys[j]);
            }
            pmm.freePage(fis_phys);
            pmm.freePage(cmd_list_phys);
            return error.OutOfMemory;
        };
        const ct_virt = hhdm.physToVirt(ct_phys);
        var ct_ptr: [*]u8 = @ptrFromInt(ct_virt);
        @memset(ct_ptr[0..paging.PAGE_SIZE], 0);

        ports[idx].cmd_tables_phys[slot] = ct_phys;
        ports[idx].cmd_tables_virt[slot] = ct_virt;
        allocated_slots += 1;

        // Set up the command header to point to this command table
        const ch: *volatile CmdHeader = @ptrFromInt(cmd_list_virt + slot * @sizeOf(CmdHeader));
        ch.dw0 = (5 << 0); // CFL = 5 DWs (size of H2D register FIS)
        ch.dw1 = 0;
        ch.dw2 = @truncate(ct_phys);
        ch.dw3 = @truncate(ct_phys >> 32);
        ch.dw4 = 0;
    }

    ports[idx].port_base = port_base;
    ports[idx].port_idx = idx;
    ports[idx].cmd_list_phys = cmd_list_phys;
    ports[idx].cmd_list_virt = cmd_list_virt;
    ports[idx].fis_recv_phys = fis_phys;
    ports[idx].fis_recv_virt = fis_virt;
    ports[idx].cmd_count = num_cmd_slots;
    ports[idx].active = true;
    active_port_count += 1;

    // Start command engine
    startCmd(port_base);
}

fn stopCmd(port_base: u64) void {
    var cmd = readPort(port_base, PORT_CMD);
    cmd &= ~CMD_ST;
    writePort(port_base, PORT_CMD, cmd);
    cmd &= ~CMD_FRE;
    writePort(port_base, PORT_CMD, cmd);

    // Wait for CR and FR to clear
    var timeout: u32 = 500_000;
    while (timeout > 0) : (timeout -= 1) {
        const c = readPort(port_base, PORT_CMD);
        if ((c & (CMD_CR | CMD_FR)) == 0) break;
        asm volatile ("pause");
    }
}

fn startCmd(port_base: u64) void {
    // Set FRE first
    var cmd = readPort(port_base, PORT_CMD);
    cmd |= CMD_FRE;
    writePort(port_base, PORT_CMD, cmd);

    // Wait for FR
    var timeout: u32 = 500_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((readPort(port_base, PORT_CMD) & CMD_FR) != 0) break;
        asm volatile ("pause");
    }

    // Set ST
    cmd = readPort(port_base, PORT_CMD);
    cmd |= CMD_ST;
    writePort(port_base, PORT_CMD, cmd);
}

/// Read sectors from the first active SATA disk.
/// Returns number of bytes read, or -1 on error.
pub fn readSectors(lba: u64, count: u32, buf: [*]u8) i64 {
    var port_idx: u32 = 0;
    while (port_idx < MAX_AHCI_PORTS) : (port_idx += 1) {
        if (ports[port_idx].active) {
            return readSectorsFromPort(port_idx, lba, count, buf);
        }
    }
    return -1;
}

fn readSectorsFromPort(port_idx: u32, lba: u64, count: u32, buf: [*]u8) i64 {
    if (port_idx >= MAX_AHCI_PORTS or !ports[port_idx].active) return -1;
    if (count == 0 or count > 128) return -1;

    const port_base = ports[port_idx].port_base;

    // Find a free command slot
    const slot = findFreeSlot(port_base) orelse return -1;

    // Set up command table
    const ct_virt = ports[port_idx].cmd_tables_virt[slot];
    const ct_phys = ports[port_idx].cmd_tables_phys[slot];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    // Build H2D register FIS
    {
        const cfis_ptr: [*]u8 = @volatileCast(@ptrCast(&ct.cfis));
        @memset(cfis_ptr[0..64], 0);
    }
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // C=1 (command)
    ct.cfis[2] = ATA_READ_DMA_EXT;

    // LBA (48-bit)
    ct.cfis[4] = @truncate(lba);
    ct.cfis[5] = @truncate(lba >> 8);
    ct.cfis[6] = @truncate(lba >> 16);
    ct.cfis[7] = 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)); // LBA mode + high bits
    ct.cfis[8] = @truncate(lba >> 24);
    ct.cfis[9] = @truncate(lba >> 32);
    ct.cfis[10] = @truncate(lba >> 40);

    // Sector count
    ct.cfis[12] = @truncate(count);
    ct.cfis[13] = @truncate(count >> 8);

    // Set up PRDT — one entry for the entire buffer
    const buf_phys = virtToPhys(@intFromPtr(buf));
    ct.prdt[0].dba = @truncate(buf_phys);
    ct.prdt[0].dbau = @truncate(buf_phys >> 32);
    ct.prdt[0].reserved = 0;
    ct.prdt[0].dw3 = (count * SECTOR_SIZE - 1) | (1 << 31); // Byte count + interrupt on completion

    // Set up command header
    const ch: *volatile CmdHeader = @ptrFromInt(ports[port_idx].cmd_list_virt + slot * @sizeOf(CmdHeader));
    ch.dw0 = (5 << 0) | (1 << 16); // CFL=5, PRDTL=1
    ch.dw1 = 0;
    ch.dw2 = @truncate(ct_phys);
    ch.dw3 = @truncate(ct_phys >> 32);
    ch.dw4 = 0;

    // Clear port IS
    writePort(port_base, PORT_IS, 0xFFFFFFFF);

    // Issue command
    writePort(port_base, PORT_CI, @as(u32, 1) << @intCast(slot));

    // Wait for completion (polling)
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const ci = readPort(port_base, PORT_CI);
        if ((ci & (@as(u32, 1) << @intCast(slot))) == 0) break;
        asm volatile ("pause");
    }

    if (timeout == 0) {
        serial.writeString("[ahci] Read timeout at LBA ");
        writeHex64(lba);
        serial.writeString("\n");
        return -1;
    }

    // Check for errors
    const tfd = readPort(port_base, PORT_TFD);
    if ((tfd & 0x01) != 0) {
        serial.writeString("[ahci] Read error TFD=0x");
        writeHex32(tfd);
        serial.writeString("\n");
        return -1;
    }

    return @intCast(count * SECTOR_SIZE);
}

/// Write sectors to the first active SATA disk.
pub fn writeSectors(lba: u64, count: u32, buf: [*]const u8) i64 {
    var port_idx: u32 = 0;
    while (port_idx < MAX_AHCI_PORTS) : (port_idx += 1) {
        if (ports[port_idx].active) {
            return writeSectorsToPort(port_idx, lba, count, buf);
        }
    }
    return -1;
}

fn writeSectorsToPort(port_idx: u32, lba: u64, count: u32, buf: [*]const u8) i64 {
    if (port_idx >= MAX_AHCI_PORTS or !ports[port_idx].active) return -1;
    if (count == 0 or count > 128) return -1;

    const port_base = ports[port_idx].port_base;
    const slot = findFreeSlot(port_base) orelse return -1;

    const ct_virt = ports[port_idx].cmd_tables_virt[slot];
    const ct_phys = ports[port_idx].cmd_tables_phys[slot];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    {
        const cfis_ptr: [*]u8 = @volatileCast(@ptrCast(&ct.cfis));
        @memset(cfis_ptr[0..64], 0);
    }
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80;
    ct.cfis[2] = ATA_WRITE_DMA_EXT;

    ct.cfis[4] = @truncate(lba);
    ct.cfis[5] = @truncate(lba >> 8);
    ct.cfis[6] = @truncate(lba >> 16);
    ct.cfis[7] = 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F));
    ct.cfis[8] = @truncate(lba >> 24);
    ct.cfis[9] = @truncate(lba >> 32);
    ct.cfis[10] = @truncate(lba >> 40);
    ct.cfis[12] = @truncate(count);
    ct.cfis[13] = @truncate(count >> 8);

    const buf_phys = virtToPhys(@intFromPtr(buf));
    ct.prdt[0].dba = @truncate(buf_phys);
    ct.prdt[0].dbau = @truncate(buf_phys >> 32);
    ct.prdt[0].reserved = 0;
    ct.prdt[0].dw3 = (count * SECTOR_SIZE - 1) | (1 << 31);

    const ch: *volatile CmdHeader = @ptrFromInt(ports[port_idx].cmd_list_virt + slot * @sizeOf(CmdHeader));
    ch.dw0 = (5 << 0) | (1 << 16) | (1 << 6); // CFL=5, PRDTL=1, W=1 (write)
    ch.dw1 = 0;
    ch.dw2 = @truncate(ct_phys);
    ch.dw3 = @truncate(ct_phys >> 32);
    ch.dw4 = 0;

    writePort(port_base, PORT_IS, 0xFFFFFFFF);
    writePort(port_base, PORT_CI, @as(u32, 1) << @intCast(slot));

    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const ci = readPort(port_base, PORT_CI);
        if ((ci & (@as(u32, 1) << @intCast(slot))) == 0) break;
        asm volatile ("pause");
    }

    if (timeout == 0) return -1;

    const tfd = readPort(port_base, PORT_TFD);
    if ((tfd & 0x01) != 0) return -1;

    return @intCast(count * SECTOR_SIZE);
}

fn findFreeSlot(port_base: u64) ?u32 {
    const ci = readPort(port_base, PORT_CI);
    const sact = readPort(port_base, PORT_SACT);
    const busy = ci | sact;
    var slot: u32 = 0;
    while (slot < num_cmd_slots) : (slot += 1) {
        if ((busy & (@as(u32, 1) << @intCast(slot))) == 0) return slot;
    }
    return null;
}

fn virtToPhys(virt: u64) u64 {
    return hhdm.virtToPhys(virt);
}

pub fn hasActiveDisk() bool {
    return active_port_count > 0;
}

pub fn getSectorSize() u32 {
    return SECTOR_SIZE;
}

fn writeHex8(v: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[(v >> 4) & 0xF];
    buf[1] = hex[v & 0xF];
    serial.writeString(&buf);
}

fn writeHex32(v: u32) void {
    const hex = "0123456789abcdef";
    var buf: [8]u8 = undefined;
    var i: usize = 8;
    var val = v;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[val & 0xF];
        val >>= 4;
    }
    serial.writeString(&buf);
}

fn writeHex64(v: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    var val = v;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(val & 0xF))];
        val >>= 4;
    }
    serial.writeString(&buf);
}

fn writeDecimal(v: u32) void {
    if (v == 0) {
        serial.writeString("0");
        return;
    }
    var buf: [10]u8 = undefined;
    var val = v;
    var i: usize = 0;
    while (val > 0) : (val /= 10) {
        buf[i] = @intCast(val % 10 + '0');
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
