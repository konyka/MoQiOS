/// AHCI (Advanced Host Controller Interface) SATA driver.
///
/// Detects AHCI controllers via PCI class 01:06:01, initializes the HBA,
/// enumerates ports, and provides sector read/write operations.
///
/// Features:
///   - Interrupt-driven command completion (MSI or legacy PCI IRQ)
///   - NCQ (Native Command Queuing) with up to 32 concurrent tags
///   - TRIM (DATA SET MANAGEMENT) support
///   - FLUSH CACHE EXT for write barriers
///   - Graceful fallback to polling DMA when NCQ / MSI unavailable
///
/// QEMU exposes Intel ICH9 AHCI (8086:2922) at PCI 0:31.2.
const serial = @import("../arch/x86_64/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const pmm = @import("../mm/pmm.zig");
const pci = @import("pci.zig");
const main_mod = @import("../main.zig");
const fmt = @import("../lib/fmt.zig");

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
pub const PORT_SACT: u32 = 0x34;
pub const PORT_CI: u32 = 0x38;

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

// Port Interrupt Status bits
pub const PXIS_DHRS: u32 = 1 << 0; // Device to Host Register FIS
pub const PXIS_PSS: u32 = 1 << 1; // PIO Setup FIS
pub const PXIS_DSS: u32 = 1 << 2; // DMA Setup FIS
pub const PXIS_SDBS: u32 = 1 << 3; // Set Device Bits FIS (NCQ completion)
pub const PXIS_UFS: u32 = 1 << 4; // Unknown FIS
pub const PXIS_DMPS: u32 = 1 << 5; // Descriptor Processed
pub const PXIS_PCS: u32 = 1 << 6; // Port Connect Change
pub const PXIS_PRCS: u32 = 1 << 22; // PhyRdy Change Status
pub const PXIS_TFES: u32 = 1 << 30; // Task File Error Status
pub const PXIS_HBFS: u32 = 1 << 29; // Host Bus Fatal Error
pub const PXIS_HBDS: u32 = 1 << 28; // Host Bus Data Error
pub const PXIS_IFS: u32 = 1 << 27; // Interface Fatal Error
pub const PXIS_INFS: u32 = 1 << 26; // Interface Non-Fatal Error
pub const PXIS_OFS: u32 = 1 << 8; // Overflow Status

// Port Interrupt Enable bits
pub const PXIE_DHRE: u32 = 1 << 0;
pub const PXIE_PSE: u32 = 1 << 1;
pub const PXIE_DSE: u32 = 1 << 2;
pub const PXIE_SDBE: u32 = 1 << 3; // Set Device Bits (NCQ)
pub const PXIE_UFE: u32 = 1 << 4;
pub const PXIE_DPE: u32 = 1 << 5;
pub const PXIE_PCE: u32 = 1 << 6;
pub const PXIE_TFEE: u32 = 1 << 30; // Task File Error
pub const PXIE_HBFE: u32 = 1 << 29; // Host Bus Fatal Error

// Command FIS types
pub const FIS_TYPE_REG_H2D: u8 = 0x27;

// ATA commands
pub const ATA_READ_DMA_EXT: u8 = 0x25;
pub const ATA_WRITE_DMA_EXT: u8 = 0x35;
pub const ATA_IDENTIFY: u8 = 0xEC;
pub const ATA_READ_FPDMA_QUEUED: u8 = 0x60;
pub const ATA_WRITE_FPDMA_QUEUED: u8 = 0x61;
pub const ATA_DATA_SET_MANAGEMENT: u8 = 0x06;
pub const ATA_FLUSH_CACHE_EXT: u8 = 0xEA;

// DATA SET MANAGEMENT (TRIM) subcommands
pub const DSM_TRIM: u8 = 0x01;

// AHCI interrupt vector (allocated in IDT)
pub const AHCI_IRQ_VECTOR: u8 = 241;

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

/// Pending IO request tracked per-command-slot.
pub const AhciRequest = struct {
    lba: u64,
    sector_count: u32,
    buffer: [*]u8,
    is_write: bool,
    completed: bool,
    has_error: bool,
    tag: u8, // NCQ tag (0-31), same as command slot
};

/// Per-port AHCI state.
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
    // NCQ / interrupt state
    ncq_supported: bool,
    identify_data_phys: u64,
    identify_data_virt: u64,
    total_sectors: u64,
    lba48_supported: bool,
    trim_supported: bool,
    // Per-slot request tracking
    requests: [MAX_CMD_SLOTS]AhciRequest,
    // Tag bitmap: 1 = free, 0 = in use
    tag_bitmap: u32,
    // MSI interrupt state
    msi_enabled: bool,
    // PCI routing info
    pci_bus: u8,
    pci_dev: u8,
    pci_func: u8,
    irq_pin: u8,
    irq_line: u8,
};

var hba_base: u64 = 0;
var cap: u32 = 0;
var num_cmd_slots: u32 = 0;
var ncq_supported_global: bool = false;
var sncq_supported: bool = false;
var sss_supported: bool = false; // Staggered Spin-Up
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
    .ncq_supported = false,
    .identify_data_phys = 0,
    .identify_data_virt = 0,
    .total_sectors = 0,
    .lba48_supported = false,
    .trim_supported = false,
    .requests = @splat(.{
        .lba = 0,
        .sector_count = 0,
        .buffer = undefined,
        .is_write = false,
        .completed = false,
        .has_error = false,
        .tag = 0,
    }),
    .tag_bitmap = 0,
    .msi_enabled = false,
    .pci_bus = 0,
    .pci_dev = 0,
    .pci_func = 0,
    .irq_pin = 0,
    .irq_line = 0,
});
var active_port_count: u32 = 0;
// PCI BDF of the AHCI controller (saved for MSI setup)
var controller_bus: u8 = 0;
var controller_dev: u8 = 0;
var controller_func: u8 = 0;

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
            fmt.writeHex8(dev.bus);
            serial.writeString(":");
            fmt.writeHex8(dev.device);
            serial.writeString(".");
            fmt.writeHex8(dev.function);
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

    // Save PCI routing info for MSI / interrupt setup
    controller_bus = dev.bus;
    controller_dev = dev.device;
    controller_func = dev.function;

    // Enable bus mastering + memory space + I/O space
    const pci_cmd = pci.configRead32(dev.bus, dev.device, dev.function, 0x04);
    pci.configWrite32(dev.bus, dev.device, dev.function, 0x04, pci_cmd | 0x07);

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
    ncq_supported_global = (cap & (1 << 0)) != 0; // bit 0 = SNCQ
    sncq_supported = (cap & (1 << 0)) != 0;
    sss_supported = (cap & (1 << 14)) != 0; // Staggered Spin-Up
    const num_ports_impl = readReg(HBA_PI);

    serial.writeString("[ahci] CAP=0x");
    fmt.writeHex32(cap);
    serial.writeString(" cmd_slots=");
    fmt.writeDecimal(num_cmd_slots);
    serial.writeString(" NCQ=");
    if (ncq_supported_global) serial.writeString("yes") else serial.writeString("no");
    serial.writeString(" PI=0x");
    fmt.writeHex32(num_ports_impl);
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

    // Clear any pending HBA interrupts
    writeReg(HBA_IS, readReg(HBA_IS));

    // Enumerate ports
    active_port_count = 0;
    var port_idx: u32 = 0;
    while (port_idx < MAX_AHCI_PORTS and port_idx < 32) : (port_idx += 1) {
        if ((num_ports_impl & (@as(u32, 1) << @intCast(port_idx))) == 0) continue;

        const port_base = hba_base + 0x100 + @as(u64, port_idx) * 0x80;
        const ssts = readPort(port_base, PORT_SSTS);

        serial.writeString("[ahci] Port ");
        fmt.writeDecimal(port_idx);
        serial.writeString(": SSTS=0x");
        fmt.writeHex32(ssts);

        const det = ssts & 0xF;
        const ipm = (ssts >> 8) & 0xF;
        if (det == SSTS_DET_PRESENT and ipm == 1) {
            const sig = readPort(port_base, PORT_SIG);
            serial.writeString(" SIG=0x");
            fmt.writeHex32(sig);

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

    // Set up MSI or enable GHC interrupts
    setupInterrupts();

    serial.writeString("[ahci] ");
    fmt.writeDecimal(active_port_count);
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

    // Allocate Identify Device data buffer
    const id_phys = pmm.allocPage() orelse {
        var j: u32 = 0;
        while (j < allocated_slots) : (j += 1) {
            pmm.freePage(ports[idx].cmd_tables_phys[j]);
        }
        pmm.freePage(fis_phys);
        pmm.freePage(cmd_list_phys);
        return error.OutOfMemory;
    };
    const id_virt = hhdm.physToVirt(id_phys);

    ports[idx].port_base = port_base;
    ports[idx].port_idx = idx;
    ports[idx].cmd_list_phys = cmd_list_phys;
    ports[idx].cmd_list_virt = cmd_list_virt;
    ports[idx].fis_recv_phys = fis_phys;
    ports[idx].fis_recv_virt = fis_virt;
    ports[idx].cmd_count = num_cmd_slots;
    ports[idx].active = true;
    ports[idx].ncq_supported = false;
    ports[idx].identify_data_phys = id_phys;
    ports[idx].identify_data_virt = id_virt;
    ports[idx].total_sectors = 0;
    ports[idx].lba48_supported = false;
    ports[idx].trim_supported = false;
    ports[idx].tag_bitmap = 0; // All tags in use initially, will set after identify
    ports[idx].msi_enabled = false;
    ports[idx].pci_bus = controller_bus;
    ports[idx].pci_dev = controller_dev;
    ports[idx].pci_func = controller_func;
    ports[idx].irq_pin = 0;
    ports[idx].irq_line = 0;
    active_port_count += 1;

    // Start command engine
    startCmd(port_base);

    // Issue IDENTIFY DEVICE to query capabilities
    identifyDevice(idx);

    // Initialize tag bitmap: mark all slots as free
    if (ports[idx].ncq_supported) {
        var bm: u32 = 0;
        var s: u32 = 0;
        while (s < num_cmd_slots) : (s += 1) {
            bm |= @as(u32, 1) << @intCast(s);
        }
        ports[idx].tag_bitmap = bm;
    } else {
        ports[idx].tag_bitmap = 0; // Not used in non-NCQ mode
    }
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

/// Issue IDENTIFY DEVICE command and parse the result to detect NCQ, LBA48, TRIM, capacity.
fn identifyDevice(port_idx: u32) void {
    if (port_idx >= MAX_AHCI_PORTS or !ports[port_idx].active) return;

    const port_base = ports[port_idx].port_base;
    const id_virt = ports[port_idx].identify_data_virt;

    // Zero the identify buffer
    var id_ptr: [*]u8 = @ptrFromInt(id_virt);
    @memset(id_ptr[0..512], 0);

    // Find a free command slot
    const slot = findFreeSlot(port_base) orelse {
        serial.writeString("[ahci] identifyDevice: no free slot\n");
        return;
    };

    // Set up command table
    const ct_virt = ports[port_idx].cmd_tables_virt[slot];
    const ct_phys = ports[port_idx].cmd_tables_phys[slot];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    // Build H2D register FIS
    {
        const cfis_ptr: [*]u8 = @ptrCast(@volatileCast(&ct.cfis));
        @memset(cfis_ptr[0..64], 0);
    }
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // C=1
    ct.cfis[2] = ATA_IDENTIFY;

    // PRDT: one entry pointing to identify buffer (512 bytes)
    const id_phys = ports[port_idx].identify_data_phys;
    ct.prdt[0].dba = @truncate(id_phys);
    ct.prdt[0].dbau = @truncate(id_phys >> 32);
    ct.prdt[0].reserved = 0;
    ct.prdt[0].dw3 = (512 - 1) | (1 << 31); // Byte count + interrupt on completion

    // Command header
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

    // Wait for completion (polling — identify is a one-time init command)
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const ci = readPort(port_base, PORT_CI);
        if ((ci & (@as(u32, 1) << @intCast(slot))) == 0) break;
        asm volatile ("pause");
    }

    if (timeout == 0) {
        serial.writeString("[ahci] IDENTIFY timeout\n");
        return;
    }

    // Check for errors
    const tfd = readPort(port_base, PORT_TFD);
    if ((tfd & 0x01) != 0) {
        serial.writeString("[ahci] IDENTIFY error TFD=0x");
        fmt.writeHex32(tfd);
        serial.writeString("\n");
        return;
    }

    // Parse IDENTIFY data (16-bit words)
    const id_words: [*]const u16 = @ptrFromInt(id_virt);

    // Word 49: LBA48 support (bit 10)
    if ((id_words[49] & (1 << 10)) != 0) {
        ports[port_idx].lba48_supported = true;
    }

    // Word 76: NCQ support (bit 8) — only valid for ATA8-ACS
    if (ncq_supported_global and (id_words[76] & (1 << 8)) != 0) {
        ports[port_idx].ncq_supported = true;
    }

    // Word 69: DATA SET MANAGEMENT (TRIM) support (bit 14)
    if ((id_words[69] & (1 << 14)) != 0) {
        ports[port_idx].trim_supported = true;
    }

    // Total sectors (LBA48: words 100-103)
    if (ports[port_idx].lba48_supported) {
        const lo: u64 = @as(u64, id_words[100]) | (@as(u64, id_words[101]) << 16);
        const hi: u64 = @as(u64, id_words[102]) | (@as(u64, id_words[103]) << 16);
        ports[port_idx].total_sectors = (hi << 32) | lo;
    } else {
        // Fallback: LBA28 from words 60-61
        ports[port_idx].total_sectors = @as(u64, id_words[60]) | (@as(u64, id_words[61]) << 16);
    }

    serial.writeString("[ahci] Port ");
    fmt.writeDecimal(port_idx);
    serial.writeString(": LBA48=");
    if (ports[port_idx].lba48_supported) serial.writeString("yes") else serial.writeString("no");
    serial.writeString(" NCQ=");
    if (ports[port_idx].ncq_supported) serial.writeString("yes") else serial.writeString("no");
    serial.writeString(" TRIM=");
    if (ports[port_idx].trim_supported) serial.writeString("yes") else serial.writeString("no");
    serial.writeString(" sectors=");
    fmt.writeDecimal64(ports[port_idx].total_sectors);
    serial.writeString("\n");
}

// ─── MSI / Interrupt Setup ────────────────────────────────────────────

/// Set up MSI for the AHCI controller, or fall back to legacy PCI IRQ.
fn setupInterrupts() void {
    // Try to enable MSI
    if (enableMsi()) {
        serial.writeString("[ahci] MSI enabled on vector ");
        fmt.writeDecimal(AHCI_IRQ_VECTOR);
        serial.writeString("\n");
    } else {
        serial.writeString("[ahci] MSI not available, using polling fallback\n");
    }

    // Enable GHC interrupts
    writeReg(HBA_GHC, readReg(HBA_GHC) | GHC_IE);

    // Enable port interrupts for all active ports
    for (0..MAX_AHCI_PORTS) |i| {
        if (!ports[i].active) continue;
        const pb = ports[i].port_base;

        // Clear pending port interrupt status
        writePort(pb, PORT_IS, 0xFFFFFFFF);

        // Enable port interrupts: DHRS, SDBS (NCQ), TFES
        var ie: u32 = PXIE_DHRE | PXIE_SDBE | PXIE_TFEE | PXIE_HBFE;
        if (ports[i].ncq_supported) {
            ie |= PXIE_DSE; // DMA Setup FIS for NCQ
        }
        writePort(pb, PORT_IE, ie);
    }
}

/// Enable MSI for the AHCI controller by scanning PCI capability list.
/// Returns true if MSI was successfully enabled.
fn enableMsi() bool {
    const bus = controller_bus;
    const dev = controller_dev;
    const func = controller_func;

    // Read PCI status register to check capabilities bit
    const status = pci.configRead32(bus, dev, func, 0x06);
    if ((status & (1 << 20)) == 0) {
        // No capabilities list
        serial.writeString("[ahci] No PCI capabilities list\n");
        return false;
    }

    // Walk the capability list
    var cap_offset: u8 = @truncate(pci.configRead32(bus, dev, func, 0x34) & 0xFC);
    while (cap_offset != 0) {
        const cap_id: u8 = @truncate(pci.configRead32(bus, dev, func, cap_offset) & 0xFF);

        if (cap_id == 0x05) {
            // MSI capability found
            return enableMsiCapability(bus, dev, func, cap_offset);
        }

        // Next capability
        const next: u8 = @truncate((pci.configRead32(bus, dev, func, cap_offset) >> 8) & 0xFC);
        if (next == 0) break;
        cap_offset = next;
    }

    serial.writeString("[ahci] MSI capability not found in PCI caps\n");
    return false;
}

/// Enable a specific MSI capability.
fn enableMsiCapability(bus: u8, dev: u8, func: u8, cap_offset: u8) bool {
    // Read MSI control register
    const msi_ctrl = pci.configRead32(bus, dev, func, cap_offset + 0x02) & 0xFFFF;

    // 64-bit address capable?
    const is_64bit = (msi_ctrl & (1 << 7)) != 0;
    // Per-vector masking capable?
    const _per_vector = (msi_ctrl & (1 << 8)) != 0;
    _ = _per_vector;

    // Configure MSI address: LAPIC MMIO base (0xFEE00000)
    // This routes the MSI to the local APIC
    const msi_addr: u32 = 0xFEE00000;

    // Data word: delivery mode=fixed, vector=AHCI_IRQ_VECTOR
    const msi_data: u32 = AHCI_IRQ_VECTOR;

    // Write address (low 32 bits)
    pci.configWrite32(bus, dev, func, cap_offset + 0x04, msi_addr);

    if (is_64bit) {
        // Write address (high 32 bits) — 0 for now (within 4GB)
        pci.configWrite32(bus, dev, func, cap_offset + 0x08, 0);
        // Write data
        pci.configWrite32(bus, dev, func, cap_offset + 0x0C, msi_data);
    } else {
        // Write data (offset +0x08 for 32-bit MSI)
        pci.configWrite32(bus, dev, func, cap_offset + 0x08, msi_data);
    }

    // Enable MSI (bit 0 of control), set 1 message (0 encoded = 1 message)
    var new_ctrl: u32 = msi_ctrl | 0x0001; // Enable MSI
    new_ctrl &= ~@as(u32, 0x00E0); // MME = 000 (1 message)
    // Write back as 16-bit at cap_offset + 0x02
    // PCI config writes are 32-bit aligned, so read-modify-write
    const ctrl_reg = pci.configRead32(bus, dev, func, cap_offset);
    pci.configWrite32(bus, dev, func, cap_offset, (ctrl_reg & 0xFFFF0000) | (@as(u32, new_ctrl) & 0xFFFF));

    // Mark ports as MSI enabled
    for (0..MAX_AHCI_PORTS) |i| {
        if (ports[i].active) {
            ports[i].msi_enabled = true;
        }
    }

    return true;
}

/// AHCI interrupt handler — called from IDT dispatch when vector 241 fires.
pub fn handleInterrupt() void {
    // Read HBA Interrupt Status
    const hba_is = readReg(HBA_IS);
    if (hba_is == 0) return; // Spurious

    // Process each port that has a pending interrupt
    var port_idx: u32 = 0;
    while (port_idx < MAX_AHCI_PORTS) : (port_idx += 1) {
        if (!ports[port_idx].active) continue;
        if ((hba_is & (@as(u32, 1) << @intCast(port_idx))) == 0) continue;

        handlePortInterrupt(port_idx);
    }

    // Clear HBA interrupt status
    writeReg(HBA_IS, hba_is);
}

/// Handle interrupt for a specific port.
fn handlePortInterrupt(port_idx: u32) void {
    const port_base = ports[port_idx].port_base;
    const is = readPort(port_base, PORT_IS);

    // Check for errors
    if ((is & (PXIS_TFES | PXIS_HBFS | PXIS_HBDS | PXIS_IFS)) != 0) {
        // Error condition — mark any pending requests as errored
        handlePortError(port_idx, is);
    }

    // NCQ completion: SDBS (Set Device Bits FIS) indicates NCQ tag completion
    if ((is & PXIS_SDBS) != 0 and ports[port_idx].ncq_supported) {
        // SACT (Serial ATA Active) bits that cleared indicate completed tags
        const sact = readPort(port_base, PORT_SACT);
        // CI bits that cleared indicate completed commands
        const ci = readPort(port_base, PORT_CI);
        // Tags that were in use but are now free
        var slot: u32 = 0;
        while (slot < num_cmd_slots) : (slot += 1) {
            const mask = @as(u32, 1) << @intCast(slot);
            // Check if this slot had a request and is now complete
            if (ports[port_idx].requests[slot].tag == slot and
                !ports[port_idx].requests[slot].completed and
                (ci & mask) == 0 and (sact & mask) == 0)
            {
                // Verify no error
                const tfd = readPort(port_base, PORT_TFD);
                ports[port_idx].requests[slot].completed = true;
                if ((tfd & 0x01) != 0) {
                    ports[port_idx].requests[slot].has_error = true;
                }
                // Release the tag
                ports[port_idx].tag_bitmap |= mask;
            }
        }
    }

    // Non-NCQ completion: DHRS (Device to Host Register FIS)
    if ((is & PXIS_DHRS) != 0) {
        const ci = readPort(port_base, PORT_CI);
        var slot: u32 = 0;
        while (slot < num_cmd_slots) : (slot += 1) {
            const mask = @as(u32, 1) << @intCast(slot);
            if (ports[port_idx].requests[slot].tag == slot and
                !ports[port_idx].requests[slot].completed and
                (ci & mask) == 0)
            {
                const tfd = readPort(port_base, PORT_TFD);
                ports[port_idx].requests[slot].completed = true;
                if ((tfd & 0x01) != 0) {
                    ports[port_idx].requests[slot].has_error = true;
                }
                // Release tag for NCQ
                if (ports[port_idx].ncq_supported) {
                    ports[port_idx].tag_bitmap |= mask;
                }
            }
        }
    }

    // Clear port interrupt status (write 1 to clear)
    writePort(port_base, PORT_IS, is);
}

/// Handle port error interrupt.
fn handlePortError(port_idx: u32, is: u32) void {
    const port_base = ports[port_idx].port_base;
    const tfd = readPort(port_base, PORT_TFD);

    serial.writeString("[ahci] Port ");
    fmt.writeDecimal(port_idx);
    serial.writeString(" error: IS=0x");
    fmt.writeHex32(is);
    serial.writeString(" TFD=0x");
    fmt.writeHex32(tfd);
    serial.writeString("\n");

    // Mark all pending requests on this port as errored
    var slot: u32 = 0;
    while (slot < num_cmd_slots) : (slot += 1) {
        if (ports[port_idx].requests[slot].tag == slot and !ports[port_idx].requests[slot].completed) {
            ports[port_idx].requests[slot].has_error = true;
            ports[port_idx].requests[slot].completed = true;
        }
    }

    // Release all tags
    if (ports[port_idx].ncq_supported) {
        var bm: u32 = 0;
        var s: u32 = 0;
        while (s < num_cmd_slots) : (s += 1) {
            bm |= @as(u32, 1) << @intCast(s);
        }
        ports[port_idx].tag_bitmap = bm;
    }

    // Clear SERR
    writePort(port_base, PORT_SERR, readPort(port_base, PORT_SERR));

    // Clear error in TFD by clearing CLO
    var cmd = readPort(port_base, PORT_CMD);
    cmd |= CMD_CLO;
    writePort(port_base, PORT_CMD, cmd);
    // Wait for CLO to clear
    var timeout: u32 = 500_000;
    while (timeout > 0) : (timeout -= 1) {
        if ((readPort(port_base, PORT_CMD) & CMD_CLO) == 0) break;
        asm volatile ("pause");
    }
}

// ─── NCQ Tag Allocation ───────────────────────────────────────────────

/// Allocate a free NCQ tag. Returns tag number (0-31) or null if all busy.
fn allocTag(port_idx: u32) ?u8 {
    var tag: u8 = 0;
    while (tag < num_cmd_slots) : (tag += 1) {
        const mask = @as(u32, 1) << @intCast(tag);
        if ((ports[port_idx].tag_bitmap & mask) != 0) {
            ports[port_idx].tag_bitmap &= ~mask;
            return tag;
        }
    }
    return null;
}

/// Release an NCQ tag.
fn freeTag(port_idx: u32, tag: u8) void {
    if (tag >= MAX_CMD_SLOTS) return;
    const mask = @as(u32, 1) << @intCast(tag);
    ports[port_idx].tag_bitmap |= mask;
}

// ─── NCQ Read / Write ─────────────────────────────────────────────────

/// Read sectors from the first active SATA disk using NCQ if available.
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

    if (ports[port_idx].ncq_supported) {
        return readNcq(port_idx, lba, count, buf);
    }

    // Non-NCQ fallback: legacy DMA polling
    const slot = findFreeSlot(port_base) orelse return -1;

    const ct_virt = ports[port_idx].cmd_tables_virt[slot];
    const ct_phys = ports[port_idx].cmd_tables_phys[slot];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    {
        const cfis_ptr: [*]u8 = @ptrCast(@volatileCast(&ct.cfis));
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

    // Wait for completion (polling fallback)
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const ci = readPort(port_base, PORT_CI);
        if ((ci & (@as(u32, 1) << @intCast(slot))) == 0) break;
        asm volatile ("pause");
    }

    if (timeout == 0) {
        serial.writeString("[ahci] Read timeout at LBA ");
        fmt.writeHex64(lba);
        serial.writeString("\n");
        return -1;
    }

    // Check for errors
    const tfd = readPort(port_base, PORT_TFD);
    if ((tfd & 0x01) != 0) {
        serial.writeString("[ahci] Read error TFD=0x");
        fmt.writeHex32(tfd);
        serial.writeString("\n");
        return -1;
    }

    return @intCast(count * SECTOR_SIZE);
}

/// NCQ read: uses READ FPDMA QUEUED command.
fn readNcq(port_idx: u32, lba: u64, count: u32, buf: [*]u8) i64 {
    const port_base = ports[port_idx].port_base;

    // Allocate NCQ tag
    const tag = allocTag(port_idx) orelse return -1;

    const ct_virt = ports[port_idx].cmd_tables_virt[tag];
    const ct_phys = ports[port_idx].cmd_tables_phys[tag];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    // Build H2D FIS for READ FPDMA QUEUED
    {
        const cfis_ptr: [*]u8 = @ptrCast(@volatileCast(&ct.cfis));
        @memset(cfis_ptr[0..64], 0);
    }
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // C=1
    ct.cfis[2] = ATA_READ_FPDMA_QUEUED;

    // LBA (48-bit) — lower 24 bits in features, upper 24 bits in LBA fields
    ct.cfis[4] = @truncate(lba); // LBA[7:0]
    ct.cfis[5] = @truncate(lba >> 8); // LBA[15:8]
    ct.cfis[6] = @truncate(lba >> 16); // LBA[23:16]
    ct.cfis[7] = 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)); // LBA[31:24] + LBA mode
    ct.cfis[8] = @truncate(lba >> 24); // LBA[31:24]
    ct.cfis[9] = @truncate(lba >> 32); // LBA[39:32]
    ct.cfis[10] = @truncate(lba >> 40); // LBA[47:40]

    // Sector count in features field (for NCQ)
    ct.cfis[12] = @truncate(count); // Count[7:0]
    ct.cfis[13] = @truncate(count >> 8); // Count[15:8]

    // NCQ tag in features upper byte
    ct.cfis[3] = tag << 3; // Tag field in features[5:3]

    // PRDT
    const buf_phys = virtToPhys(@intFromPtr(buf));
    ct.prdt[0].dba = @truncate(buf_phys);
    ct.prdt[0].dbau = @truncate(buf_phys >> 32);
    ct.prdt[0].reserved = 0;
    ct.prdt[0].dw3 = (count * SECTOR_SIZE - 1) | (1 << 31);

    // Command header — must not set W bit for reads
    const ch: *volatile CmdHeader = @ptrFromInt(ports[port_idx].cmd_list_virt + tag * @sizeOf(CmdHeader));
    ch.dw0 = (5 << 0) | (1 << 16); // CFL=5, PRDTL=1
    ch.dw1 = 0;
    ch.dw2 = @truncate(ct_phys);
    ch.dw3 = @truncate(ct_phys >> 32);
    ch.dw4 = 0;

    // Track the request
    ports[port_idx].requests[tag] = .{
        .lba = lba,
        .sector_count = count,
        .buffer = buf,
        .is_write = false,
        .completed = false,
        .has_error = false,
        .tag = @intCast(tag),
    };

    // Clear port IS
    writePort(port_base, PORT_IS, 0xFFFFFFFF);

    // Issue NCQ command: set SACT (bit in SACT) and CI
    writePort(port_base, PORT_SACT, @as(u32, 1) << @intCast(tag));
    writePort(port_base, PORT_CI, @as(u32, 1) << @intCast(tag));

    // Wait for completion
    const result = waitCompletion(port_idx, tag);

    return result;
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

    if (ports[port_idx].ncq_supported) {
        return writeNcq(port_idx, lba, count, @ptrCast(buf));
    }

    // Non-NCQ fallback: legacy DMA polling
    const slot = findFreeSlot(port_base) orelse return -1;

    const ct_virt = ports[port_idx].cmd_tables_virt[slot];
    const ct_phys = ports[port_idx].cmd_tables_phys[slot];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    {
        const cfis_ptr: [*]u8 = @ptrCast(@volatileCast(&ct.cfis));
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

/// NCQ write: uses WRITE FPDMA QUEUED command.
fn writeNcq(port_idx: u32, lba: u64, count: u32, buf: [*]u8) i64 {
    const port_base = ports[port_idx].port_base;

    // Allocate NCQ tag
    const tag = allocTag(port_idx) orelse return -1;

    const ct_virt = ports[port_idx].cmd_tables_virt[tag];
    const ct_phys = ports[port_idx].cmd_tables_phys[tag];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    // Build H2D FIS for WRITE FPDMA QUEUED
    {
        const cfis_ptr: [*]u8 = @ptrCast(@volatileCast(&ct.cfis));
        @memset(cfis_ptr[0..64], 0);
    }
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // C=1
    ct.cfis[2] = ATA_WRITE_FPDMA_QUEUED;

    // LBA (48-bit)
    ct.cfis[4] = @truncate(lba);
    ct.cfis[5] = @truncate(lba >> 8);
    ct.cfis[6] = @truncate(lba >> 16);
    ct.cfis[7] = 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F));
    ct.cfis[8] = @truncate(lba >> 24);
    ct.cfis[9] = @truncate(lba >> 32);
    ct.cfis[10] = @truncate(lba >> 40);

    // Sector count in features
    ct.cfis[12] = @truncate(count);
    ct.cfis[13] = @truncate(count >> 8);

    // NCQ tag
    ct.cfis[3] = tag << 3;

    // PRDT
    const buf_phys = virtToPhys(@intFromPtr(buf));
    ct.prdt[0].dba = @truncate(buf_phys);
    ct.prdt[0].dbau = @truncate(buf_phys >> 32);
    ct.prdt[0].reserved = 0;
    ct.prdt[0].dw3 = (count * SECTOR_SIZE - 1) | (1 << 31);

    // Command header — W=1 for writes
    const ch: *volatile CmdHeader = @ptrFromInt(ports[port_idx].cmd_list_virt + tag * @sizeOf(CmdHeader));
    ch.dw0 = (5 << 0) | (1 << 16) | (1 << 6); // CFL=5, PRDTL=1, W=1
    ch.dw1 = 0;
    ch.dw2 = @truncate(ct_phys);
    ch.dw3 = @truncate(ct_phys >> 32);
    ch.dw4 = 0;

    // Track the request
    ports[port_idx].requests[tag] = .{
        .lba = lba,
        .sector_count = count,
        .buffer = buf,
        .is_write = true,
        .completed = false,
        .has_error = false,
        .tag = @intCast(tag),
    };

    // Clear port IS
    writePort(port_base, PORT_IS, 0xFFFFFFFF);

    // Issue NCQ command
    writePort(port_base, PORT_SACT, @as(u32, 1) << @intCast(tag));
    writePort(port_base, PORT_CI, @as(u32, 1) << @intCast(tag));

    // Wait for completion
    const result = waitCompletion(port_idx, tag);

    return result;
}

/// Wait for a command to complete (used for synchronous NCQ operations).
/// In the interrupt-driven model, this polls the request's completed flag
/// which is set by the interrupt handler. Falls back to hardware polling
/// if interrupts are not working.
fn waitCompletion(port_idx: u32, tag: u8) i64 {
    const port_base = ports[port_idx].port_base;
    const mask = @as(u32, 1) << @intCast(tag);

    // First, try interrupt-driven wait (poll the completed flag set by ISR)
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        // Check if the interrupt handler marked it complete
        if (ports[port_idx].requests[tag].completed) break;

        // Also check hardware directly as a fast path / fallback
        if (ports[port_idx].msi_enabled) {
            // Give interrupts a chance to fire
            asm volatile ("pause");
        } else {
            // Polling fallback: check CI and SACT
            const ci = readPort(port_base, PORT_CI);
            const sact = readPort(port_base, PORT_SACT);
            if ((ci & mask) == 0 and (sact & mask) == 0) {
                // Command completed via polling
                const tfd = readPort(port_base, PORT_TFD);
                ports[port_idx].requests[tag].completed = true;
                if ((tfd & 0x01) != 0) {
                    ports[port_idx].requests[tag].has_error = true;
                }
                ports[port_idx].tag_bitmap |= mask;
                break;
            }
            // Check for pending interrupts and service them
            const is = readPort(port_base, PORT_IS);
            if (is != 0) {
                handlePortInterrupt(port_idx);
            }
        }
    }

    if (timeout == 0) {
        serial.writeString("[ahci] NCQ timeout at LBA ");
        fmt.writeHex64(ports[port_idx].requests[tag].lba);
        serial.writeString(" tag=");
        fmt.writeDecimal(tag);
        serial.writeString("\n");
        // Clean up
        ports[port_idx].requests[tag].completed = true;
        ports[port_idx].requests[tag].has_error = true;
        freeTag(port_idx, tag);
        return -1;
    }

    if (ports[port_idx].requests[tag].has_error) {
        serial.writeString("[ahci] NCQ error at LBA ");
        fmt.writeHex64(ports[port_idx].requests[tag].lba);
        serial.writeString("\n");
        freeTag(port_idx, tag);
        return -1;
    }

    const sector_count = ports[port_idx].requests[tag].sector_count;
    freeTag(port_idx, tag);
    return @intCast(sector_count * SECTOR_SIZE);
}

// ─── TRIM Support ─────────────────────────────────────────────────────

/// TRIM a range of LBAs. Each LBA range is 8 bytes:
///   [0:1] = sector count (0 = 65536), [2:7] = starting LBA
/// Returns 0 on success, -1 on error.
pub fn trim(lba_ranges: []const u64, range_count: u32) i32 {
    var port_idx: u32 = 0;
    while (port_idx < MAX_AHCI_PORTS) : (port_idx += 1) {
        if (ports[port_idx].active and ports[port_idx].trim_supported) {
            return trimPort(port_idx, lba_ranges, range_count);
        }
    }
    return -1;
}

fn trimPort(port_idx: u32, lba_ranges: []const u64, range_count: u32) i32 {
    if (port_idx >= MAX_AHCI_PORTS or !ports[port_idx].active) return -1;
    if (range_count == 0) return 0;

    const port_base = ports[port_idx].port_base;

    // Allocate a buffer for the TRIM data (each range = 8 bytes)
    const trim_bytes = range_count * 8;
    const buf_phys = pmm.allocPage() orelse return -1;
    const buf_virt = hhdm.physToVirt(buf_phys);
    var buf_ptr: [*]u8 = @ptrFromInt(buf_virt);
    @memset(buf_ptr[0..paging.PAGE_SIZE], 0);

    // Fill TRIM data: each entry is 8 bytes (LE)
    for (0..range_count) |i| {
        const range_val = lba_ranges[i];
        const entry_offset = i * 8;
        // Write 8 bytes (little-endian u64)
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            buf_ptr[entry_offset + j] = @truncate(range_val >> @intCast(j * 8));
        }
    }

    // Find free slot
    const slot = findFreeSlot(port_base) orelse {
        pmm.freePage(buf_phys);
        return -1;
    };

    const ct_virt = ports[port_idx].cmd_tables_virt[slot];
    const ct_phys = ports[port_idx].cmd_tables_phys[slot];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    // Build H2D FIS for DATA SET MANAGEMENT
    {
        const cfis_ptr: [*]u8 = @ptrCast(@volatileCast(&ct.cfis));
        @memset(cfis_ptr[0..64], 0);
    }
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // C=1
    ct.cfis[2] = ATA_DATA_SET_MANAGEMENT;

    // Features: TRIM subcommand
    ct.cfis[3] = DSM_TRIM; // Subcommand: TRIM
    // Sector count: number of 512-byte blocks of TRIM data
    const trim_blocks = (trim_bytes + 511) / 512;
    if (trim_blocks > 128) {
        pmm.freePage(buf_phys);
        return -1;
    }
    ct.cfis[12] = @truncate(trim_blocks);

    // PRDT pointing to TRIM data buffer
    ct.prdt[0].dba = @truncate(buf_phys);
    ct.prdt[0].dbau = @truncate(buf_phys >> 32);
    ct.prdt[0].reserved = 0;
    ct.prdt[0].dw3 = (trim_bytes - 1) | (1 << 31);

    // Command header — W=1 because TRIM is a data-out command
    const ch: *volatile CmdHeader = @ptrFromInt(ports[port_idx].cmd_list_virt + slot * @sizeOf(CmdHeader));
    ch.dw0 = (5 << 0) | (1 << 16) | (1 << 6); // CFL=5, PRDTL=1, W=1
    ch.dw1 = 0;
    ch.dw2 = @truncate(ct_phys);
    ch.dw3 = @truncate(ct_phys >> 32);
    ch.dw4 = 0;

    // Clear port IS and issue command
    writePort(port_base, PORT_IS, 0xFFFFFFFF);
    writePort(port_base, PORT_CI, @as(u32, 1) << @intCast(slot));

    // Wait for completion (polling)
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const ci = readPort(port_base, PORT_CI);
        if ((ci & (@as(u32, 1) << @intCast(slot))) == 0) break;
        asm volatile ("pause");
    }

    pmm.freePage(buf_phys);

    if (timeout == 0) {
        serial.writeString("[ahci] TRIM timeout\n");
        return -1;
    }

    const tfd = readPort(port_base, PORT_TFD);
    if ((tfd & 0x01) != 0) {
        serial.writeString("[ahci] TRIM error TFD=0x");
        fmt.writeHex32(tfd);
        serial.writeString("\n");
        return -1;
    }

    return 0;
}

// ─── FLUSH Support ────────────────────────────────────────────────────

/// Flush the volatile write cache (FLUSH CACHE EXT command).
/// Returns 0 on success, -1 on error.
pub fn flushCache() i32 {
    var port_idx: u32 = 0;
    while (port_idx < MAX_AHCI_PORTS) : (port_idx += 1) {
        if (ports[port_idx].active) {
            return flushCachePort(port_idx);
        }
    }
    return -1;
}

fn flushCachePort(port_idx: u32) i32 {
    if (port_idx >= MAX_AHCI_PORTS or !ports[port_idx].active) return -1;

    const port_base = ports[port_idx].port_base;
    const slot = findFreeSlot(port_base) orelse return -1;

    const ct_virt = ports[port_idx].cmd_tables_virt[slot];
    const ct_phys = ports[port_idx].cmd_tables_phys[slot];
    const ct: *volatile CmdTable = @ptrFromInt(ct_virt);

    // Build H2D FIS for FLUSH CACHE EXT
    {
        const cfis_ptr: [*]u8 = @ptrCast(@volatileCast(&ct.cfis));
        @memset(cfis_ptr[0..64], 0);
    }
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // C=1
    ct.cfis[2] = ATA_FLUSH_CACHE_EXT;

    // Command header — no PRDT (no data transfer)
    const ch: *volatile CmdHeader = @ptrFromInt(ports[port_idx].cmd_list_virt + slot * @sizeOf(CmdHeader));
    ch.dw0 = (5 << 0); // CFL=5, PRDTL=0
    ch.dw1 = 0;
    ch.dw2 = @truncate(ct_phys);
    ch.dw3 = @truncate(ct_phys >> 32);
    ch.dw4 = 0;

    // Clear port IS and issue command
    writePort(port_base, PORT_IS, 0xFFFFFFFF);
    writePort(port_base, PORT_CI, @as(u32, 1) << @intCast(slot));

    // Wait for completion (polling)
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const ci = readPort(port_base, PORT_CI);
        if ((ci & (@as(u32, 1) << @intCast(slot))) == 0) break;
        asm volatile ("pause");
    }

    if (timeout == 0) {
        serial.writeString("[ahci] FLUSH CACHE timeout\n");
        return -1;
    }

    const tfd = readPort(port_base, PORT_TFD);
    if ((tfd & 0x01) != 0) {
        serial.writeString("[ahci] FLUSH CACHE error TFD=0x");
        fmt.writeHex32(tfd);
        serial.writeString("\n");
        return -1;
    }

    return 0;
}

// ─── Helper Functions ─────────────────────────────────────────────────

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

/// Get total sectors of the first active AHCI port.
pub fn getTotalSectors() u64 {
    for (0..MAX_AHCI_PORTS) |i| {
        if (ports[i].active) return ports[i].total_sectors;
    }
    return 0;
}

/// Check if NCQ is supported on the first active port.
pub fn isNcqSupported() bool {
    for (0..MAX_AHCI_PORTS) |i| {
        if (ports[i].active) return ports[i].ncq_supported;
    }
    return false;
}

/// Check if TRIM is supported on the first active port.
pub fn isTrimSupported() bool {
    for (0..MAX_AHCI_PORTS) |i| {
        if (ports[i].active) return ports[i].trim_supported;
    }
    return false;
}
