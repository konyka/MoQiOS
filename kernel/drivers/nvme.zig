/// NVMe PCIe driver — NVM Express host controller interface.
///
/// Implements:
///   - PCI enumeration for NVMe controllers (class 0x01/0x08/0x02)
///   - Controller initialization (CC, AQA, ASQ, ACQ registers)
///   - Admin Queue + I/O Submission/Completion Queue pairs (depth 64)
///   - Identify Controller / Identify Namespace
///   - NVMe Read/Write commands using PRP entries
///   - Integration with block_dev abstraction layer
///
/// Limitations:
///   - Up to 4 I/O queue pairs (configurable via MAX_IO_QUEUES)
///   - PRP only (no SGL)
///   - Polling mode (no MSI-X interrupt for completion yet)
const serial = @import("../arch/x86_64/serial.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const pci = @import("pci.zig");
const block_dev = @import("block_dev.zig");
const fmt = @import("../lib/fmt.zig");

// ─── NVMe Controller Register Offsets (via BAR0 MMIO) ────────────────────

const NVME_CAP = 0x00; // Controller Capabilities (64-bit)
const NVME_VS = 0x08; // Version
const NVME_INTMS = 0x0C; // Interrupt Mask Set
const NVME_INTMC = 0x10; // Interrupt Mask Clear
const NVME_CC = 0x14; // Controller Configuration
const NVME_CSTS = 0x1C; // Controller Status
const NVME_NSSR = 0x20; // NVM Subsystem Reset
const NVME_AQA = 0x24; // Admin Queue Attributes
const NVME_ASQ = 0x28; // Admin Submission Queue Base Address (64-bit)
const NVME_ACQ = 0x30; // Admin Completion Queue Base Address (64-bit)

// ─── NVMe Command Definitions ────────────────────────────────────────────

const NVME_CMD_DELETE_SQ = 0x00;
const NVME_CMD_CREATE_SQ = 0x01;
const NVME_CMD_DELETE_CQ = 0x04;
const NVME_CMD_CREATE_CQ = 0x05;
const NVME_CMD_IDENTIFY = 0x06;
const NVME_CMD_WRITE = 0x01;
const NVME_CMD_READ = 0x02;

// ─── NVMe Queue Constants ────────────────────────────────────────────────

const QUEUE_DEPTH = 64;

/// Maximum I/O queue pairs for parallel throughput (v52.0 multi-queue).
const MAX_IO_QUEUES = 4;

// ─── NVMe Command Structure (64 bytes) ───────────────────────────────────

const NvmeCommand = extern struct {
    opcode: u8,
    flags: u8, // PRP or SGL, CID high
    cid: u16, // Command Identifier
    nsid: u32, // Namespace ID
    cdw2: u32,
    cdw3: u32,
    mptr: u64, // Metadata Pointer
    prp1: u64, // PRP Entry 1
    prp2: u64, // PRP Entry 2
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
};

// ─── NVMe Completion Structure (16 bytes) ────────────────────────────────

const NvmeCompletion = extern struct {
    cdw0: u32, // Command Specific
    rsvd: u32,
    sq_head: u16, // SQ Head Pointer
    sq_id: u16, // SQ Identifier
    cid: u16, // Command Identifier
    status: u16, // Phase + Status Field
};

// ─── NVMe Identify Controller Data (partial, first 512 bytes) ────────────

const IdentifyController = extern struct {
    vid: u16, // PCI Vendor ID
    ssvid: u16, // PCI Subsystem Vendor ID
    sn: [20]u8, // Serial Number
    mn: [40]u8, // Model Number
    fr: [8]u8, // Firmware Revision
    rab: u8, // Recommended Arbitration Burst
    ieee: [3]u8, // IEEE OUI Identifier
    cmic: u8, // Controller Multi-Path I/O and Sharing
    mdts: u8, // Maximum Data Transfer Size
    rsvd1: [178]u8, // bytes 78-255 (v52.6: was [257], off by 79)
    oacs: u16, // Optional Admin Command Support (byte 256)
    acl: u8, // Abort Command Limit
    aerl: u8, // Asynchronous Event Request Limit
    frmw: u8, // Firmware Updates
    lpa: u8, // Log Page Attributes
    elpe: u8, // Error Log Page Entries
    npss: u8, // Number of Power States
    rsvd2: [248]u8, // bytes 264-511 (v52.6: was [246], off by 2)
    sqes: u8, // SQ Entry Size (bits 7:4 = max, 3:0 = min)
    cqes: u8, // CQ Entry Size (bits 7:4 = max, 3:0 = min)
    rsvd3: [2]u8,
    nn: u32, // Number of Namespaces
    rsvd4: [156]u8,
};

// ─── NVMe Identify Namespace Data (partial) ──────────────────────────────

const IdentifyNamespace = extern struct {
    nsze: u64, // Namespace Size (total LBAs)
    ncap: u64, // Namespace Capacity
    nuse: u64, // Namespace Utilization
    nsfeat: u8, // Namespace Features
    nlbaf: u8, // Number of LBA Formats (0-based)
    flbas: u8, // Formatted LBA Size
    mc: u8, // Metadata Capabilities
    dpc: u8, // End-to-end Data Protection Capabilities
    dps: u8, // End-to-end Data Protection Type Settings
    nmic: u8, // Namespace Multi-path I/O and Sharing
    rescap: u8, // Reservation Capabilities
    fpi: u8, // Format Progress Indicator
    rsvd1: [95]u8, // bytes 33-127 (v53.0: was [298], off by 203)
    lbaf: [16]LbaFormat, // bytes 128-191
    rsvd2: [320]u8, // bytes 192-511 (v53.1: was [256], off by 64)
};

const LbaFormat = extern struct {
    ms: u16, // Metadata Size
    lbads: u8, // LBA Data Size (2^n)
    rp: u8, // Relative Performance
};

// ─── NVMe Controller State ───────────────────────────────────────────────

var controller: ?*volatile u8 = null; // MMIO base (BAR0)
var controller_phys: u64 = 0;
var enabled: bool = false;

// Queue memory (physically contiguous)
var admin_sq_phys: u64 = 0; // Admin Submission Queue
var admin_cq_phys: u64 = 0; // Admin Completion Queue
var io_sq_phys: [MAX_IO_QUEUES]u64 = @splat(0); // I/O Submission Queues
var io_cq_phys: [MAX_IO_QUEUES]u64 = @splat(0); // I/O Completion Queues
var prp_list_phys: [MAX_IO_QUEUES]u64 = @splat(0); // PRP list pages per queue

var admin_sq_tail: u16 = 0;
var admin_cq_head: u16 = 0;
var admin_cq_phase: bool = true; // Phase bit for admin CQ (v52.4)
var admin_sq_doorbell: u64 = 0;
var admin_cq_doorbell: u64 = 0;

var io_sq_tail: [MAX_IO_QUEUES]u16 = @splat(0);
var io_cq_head: [MAX_IO_QUEUES]u16 = @splat(0);
var io_cq_phase: [MAX_IO_QUEUES]bool = @splat(true); // Phase bit per CQ (v52.3)
var io_sq_doorbell: [MAX_IO_QUEUES]u64 = @splat(0);
var io_cq_doorbell: [MAX_IO_QUEUES]u64 = @splat(0);
var num_io_queues: u32 = 0; // Actual number of I/O queues created
var io_queue_rr: u32 = 0; // Round-robin queue selector

var nsid: u32 = 1; // Active namespace ID
var lba_size: u32 = 512; // Logical Block Size
var total_lbas: u64 = 0; // Total LBAs in namespace
var doorbell_stride: u32 = 0; // Doorbell stride (in bytes)
var sq_entry_size: u32 = 64; // SQES
var cq_entry_size: u32 = 16; // CQES

// ─── MMIO Read/Write Helpers ─────────────────────────────────────────────

inline fn mmioRead32(offset: u64) u32 {
    const addr: u64 = @intFromPtr(controller.?) + offset;
    const ptr: *const volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

inline fn mmioWrite32(offset: u64, value: u32) void {
    const addr: u64 = @intFromPtr(controller.?) + offset;
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

inline fn mmioRead64(offset: u64) u64 {
    const addr: u64 = @intFromPtr(controller.?) + offset;
    const ptr: *const volatile u64 = @ptrFromInt(addr);
    return ptr.*;
}

inline fn mmioWrite64(offset: u64, value: u64) void {
    const addr: u64 = @intFromPtr(controller.?) + offset;
    const ptr: *volatile u64 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Write to a doorbell register (updates SQ/CQ tail/head).
inline fn writeDoorbell(doorbell_offset: u64, value: u32) void {
    mmioWrite32(doorbell_offset, value);
}

// ─── Initialization ──────────────────────────────────────────────────────

pub fn init() void {
    serial.writeString("[NVMe] Searching for NVMe controller...\n");

    // Search PCI devices for NVMe controller (class 0x01, subclass 0x08, prog_if 0x02)
    const nvme_pci = pci.findByClass(0x01, 0x08) orelse {
        serial.writeString("[NVMe] No NVMe controller found\n");
        return;
    };

    serial.writeString("[NVMe] Found controller at ");
    fmt.writeDecimal(nvme_pci.bus);
    serial.writeString(":");
    fmt.writeDecimal(nvme_pci.device);
    serial.writeString(".");
    fmt.writeDecimal(nvme_pci.function);
    serial.writeString("\n");

    // BAR0 contains the NVMe controller registers (64-bit MMIO)
    controller_phys = nvme_pci.bars[0];
    if (controller_phys == 0) {
        serial.writeString("[NVMe] BAR0 not present\n");
        return;
    }

    // Map BAR0 into kernel virtual address space via HHDM
    const bar0_size = nvme_pci.bar_sizes[0];
    const map_pages = @max((bar0_size + 4095) / 4096, 2); // At least 8KB
    const bar0_virt = hhdm.physToVirt(controller_phys);

    // For large BARs, ensure all pages are mapped in kernel PML4
    const kernel_pml4 = paging.getKernelPml4();
    const map_flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    for (0..map_pages) |i| {
        const page_phys = controller_phys + i * 4096;
        const page_virt = bar0_virt + i * 4096;
        // mapPage may fail if already mapped (HHDM), that's OK
        paging.mapPage(kernel_pml4, page_virt, page_phys, map_flags) catch {};
    }

    controller = @ptrFromInt(bar0_virt);

    // Enable PCI bus master and memory space access
    const cmd_reg = pci.configRead32(nvme_pci.bus, nvme_pci.device, nvme_pci.function, 0x04);
    pci.configWrite32(nvme_pci.bus, nvme_pci.device, nvme_pci.function, 0x04, cmd_reg | 0x06); // Bus Master + Memory Space

    // Read CAP register
    const cap = mmioRead64(NVME_CAP);
    const to: u32 = @intCast((cap >> 24) & 0xFF); // Timeout
    const dstrd: u32 = @intCast((cap >> 32) & 0xF); // Doorbell Stride
    const mpsmin: u32 = @intCast((cap >> 48) & 0xF); // Minimum Page Size
    _ = to;
    _ = mpsmin;

    doorbell_stride = @as(u32, 1) << @intCast(dstrd + 2); // 2^(dstrd+2) bytes

    serial.writeString("[NVMe] CAP=0x");
    fmt.writeHex(cap);
    serial.writeString(" dstrd=");
    fmt.writeDecimal(doorbell_stride);
    serial.writeString("\n");

    // Read version
    const vs = mmioRead32(NVME_VS);
    serial.writeString("[NVMe] Version ");
    fmt.writeDecimal((vs >> 16) & 0xFF);
    serial.writeString(".");
    fmt.writeDecimal((vs >> 8) & 0xFF);
    serial.writeString("\n");

    // Disable controller first (CC.EN = 0), wait for CSTS.RDY = 0
    mmioWrite32(NVME_CC, 0);
    var timeout: u32 = 500000;
    while (timeout > 0) : (timeout -= 1) {
        const csts = mmioRead32(NVME_CSTS);
        if ((csts & 0x1) == 0) break;
        asm volatile ("pause");
    }
    if (timeout == 0) {
        serial.writeString("[NVMe] Controller failed to disable\n");
        return;
    }

    // Allocate admin queue memory (physically contiguous)
    admin_sq_phys = pmm.allocPage() orelse return; // 4KB = 64 entries × 64 bytes
    admin_cq_phys = pmm.allocPage() orelse return; // 4KB = 64 entries × 16 bytes × 4 (padded)

    // v52.0: Allocate multiple I/O queue pairs for parallel throughput
    for (0..MAX_IO_QUEUES) |q| {
        io_sq_phys[q] = pmm.allocPage() orelse break;
        io_cq_phys[q] = pmm.allocPage() orelse {
            pmm.freePage(io_sq_phys[q]);
            io_sq_phys[q] = 0;
            break;
        };
        prp_list_phys[q] = pmm.allocPage() orelse {
            pmm.freePage(io_cq_phys[q]);
            pmm.freePage(io_sq_phys[q]);
            io_cq_phys[q] = 0;
            io_sq_phys[q] = 0;
            break;
        };
    }
    // Count successfully allocated queues (at least 1 required)
    for (0..MAX_IO_QUEUES) |q| {
        if (io_sq_phys[q] != 0 and io_cq_phys[q] != 0) {
            num_io_queues = @intCast(q + 1);
        }
    }
    if (num_io_queues == 0) {
        serial.writeString("[NVMe] Failed to allocate I/O queues\n");
        return;
    }

    // Zero out queue memory
    const admin_sq: [*]u8 = @ptrFromInt(hhdm.physToVirt(admin_sq_phys));
    const admin_cq: [*]u8 = @ptrFromInt(hhdm.physToVirt(admin_cq_phys));
    @memset(admin_sq[0..4096], 0);
    @memset(admin_cq[0..4096], 0);
    for (0..num_io_queues) |q| {
        const sq: [*]u8 = @ptrFromInt(hhdm.physToVirt(io_sq_phys[q]));
        const cq: [*]u8 = @ptrFromInt(hhdm.physToVirt(io_cq_phys[q]));
        @memset(sq[0..4096], 0);
        @memset(cq[0..4096], 0);
    }

    // Configure Admin Queue
    const aqa: u32 = (QUEUE_DEPTH - 1) | ((QUEUE_DEPTH - 1) << 16); // ASQS | ACQS
    mmioWrite32(NVME_AQA, aqa);
    mmioWrite64(NVME_ASQ, admin_sq_phys);
    mmioWrite64(NVME_ACQ, admin_cq_phys);

    // Doorbell base: 1000h offset from BAR0
    admin_sq_doorbell = 0x1000;
    admin_cq_doorbell = 0x1000 + doorbell_stride;

    // Enable controller: CC.EN=1, CC.MPS=0 (4KB page), CC.CSS=0 (NVM I/O Command Set)
    // AMS=0 (Round Robin), MPS=0 (2^(12+0)=4KB), CSS=0 (NVM)
    mmioWrite32(NVME_CC, (1 << 0)); // CC.EN = 1

    // Wait for CSTS.RDY = 1
    timeout = 500000;
    while (timeout > 0) : (timeout -= 1) {
        const csts = mmioRead32(NVME_CSTS);
        if ((csts & 0x1) != 0) break;
        asm volatile ("pause");
    }
    if (timeout == 0) {
        serial.writeString("[NVMe] Controller failed to enable\n");
        return;
    }

    serial.writeString("[NVMe] Controller enabled\n");

    // Identify Controller
    const id_ctrl = identifyController() orelse {
        serial.writeString("[NVMe] Identify Controller failed\n");
        return;
    };

    // Determine SQ/CQ entry sizes
    sq_entry_size = @as(u32, 1) << @intCast((id_ctrl.sqes >> 4) & 0xF); // max SQES
    cq_entry_size = @as(u32, 1) << @intCast((id_ctrl.cqes >> 4) & 0xF); // max CQES
    // For most controllers, SQES=6 (64 bytes), CQES=4 (16 bytes)

    serial.writeString("[NVMe] Model: ");
    var mn_len: usize = 40;
    while (mn_len > 0 and id_ctrl.mn[mn_len - 1] == ' ') : (mn_len -= 1) {}
    serial.writeString(id_ctrl.mn[0..mn_len]);
    serial.writeString("\n");
    serial.writeString("[NVMe] Namespaces: ");
    fmt.writeDecimal(id_ctrl.nn);
    serial.writeString("\n");

    // Create I/O queue pairs (v52.4: negotiate via Set Features first)
    // NVMe spec requires Set Features (Feature ID 0x07) to request queue count
    var requested_queues: u32 = num_io_queues;
    // Check OACS bit 1: Set Features support (v52.4)
    if ((id_ctrl.oacs & 0x2) != 0) {
        var cmd_sf = zeroCommand();
        cmd_sf.opcode = 0x09; // Set Features
        cmd_sf.cdw10 = 0x07; // Feature ID: Number of Queues
        cmd_sf.cdw11 = (@as(u32, requested_queues - 1) << 16) | (requested_queues - 1); // NSQR | NCQR (0-based)
        if (submitAdminCmd(&cmd_sf)) |sf_cpl| {
            if (((sf_cpl.status >> 1) & 0x7FF) == 0) {
                const granted = @min(
                    ((sf_cpl.cdw0 >> 16) & 0xFFFF) + 1,
                    (sf_cpl.cdw0 & 0xFFFF) + 1,
                );
                if (granted < requested_queues) {
                    serial.writeString("[NVMe] Controller granted ");
                    fmt.writeDecimal(granted);
                    serial.writeString(" queues (requested ");
                    fmt.writeDecimal(requested_queues);
                    serial.writeString(")\n");
                }
                requested_queues = @min(granted, MAX_IO_QUEUES);
            } else {
                requested_queues = 1;
            }
        } else {
            serial.writeString("[NVMe] Set Features # queues failed, falling back to 1 queue\n");
            requested_queues = 1;
        }
    } else {
        serial.writeString("[NVMe] Controller does not support Set Features, using 1 queue\n");
        requested_queues = 1;
    }
    num_io_queues = requested_queues;

    // v52.4: Free excess queue pages that were allocated but not needed
    for (requested_queues..MAX_IO_QUEUES) |q| {
        if (io_sq_phys[q] != 0) {
            pmm.freePage(io_sq_phys[q]);
            io_sq_phys[q] = 0;
        }
        if (io_cq_phys[q] != 0) {
            pmm.freePage(io_cq_phys[q]);
            io_cq_phys[q] = 0;
        }
        if (prp_list_phys[q] != 0) {
            pmm.freePage(prp_list_phys[q]);
            prp_list_phys[q] = 0;
        }
    }

    var created_queues: u32 = 0;
    for (0..num_io_queues) |q| {
        const qid: u16 = @intCast(q + 1); // Queue IDs are 1-based
        // Create I/O Completion Queue
        if (!createCompletionQueue(qid, io_cq_phys[q], QUEUE_DEPTH)) {
            serial.writeString("[NVMe] Failed to create I/O CQ ");
            fmt.writeDecimal(qid);
            serial.writeString("\n");
            break;
        }
        // Create I/O Submission Queue (mapped to corresponding CQ)
        if (!createSubmissionQueue(qid, io_sq_phys[q], QUEUE_DEPTH, qid)) {
            serial.writeString("[NVMe] Failed to create I/O SQ ");
            fmt.writeDecimal(qid);
            serial.writeString("\n");
            // v52.6: Delete the orphaned CQ before breaking
            _ = deleteCompletionQueue(qid);
            break;
        }
        // Set I/O doorbell addresses
        // SQ doorbell: 0x1000 + (2 * qid) * stride
        // CQ doorbell: 0x1000 + (2 * qid + 1) * stride
        io_sq_doorbell[q] = 0x1000 + @as(u64, @as(u32, qid) * 2) * doorbell_stride;
        io_cq_doorbell[q] = 0x1000 + @as(u64, @as(u32, qid) * 2 + 1) * doorbell_stride;
        created_queues = @intCast(q + 1);
    }
    num_io_queues = created_queues;

    // v52.5: Free pages for queues that failed to create
    for (created_queues..MAX_IO_QUEUES) |q| {
        if (io_sq_phys[q] != 0) {
            pmm.freePage(io_sq_phys[q]);
            io_sq_phys[q] = 0;
        }
        if (io_cq_phys[q] != 0) {
            pmm.freePage(io_cq_phys[q]);
            io_cq_phys[q] = 0;
        }
        if (prp_list_phys[q] != 0) {
            pmm.freePage(prp_list_phys[q]);
            prp_list_phys[q] = 0;
        }
    }

    if (num_io_queues == 0) {
        serial.writeString("[NVMe] Failed to create any I/O queues\n");
        return;
    }

    serial.writeString("[NVMe] Created ");
    fmt.writeDecimal(num_io_queues);
    serial.writeString(" I/O queue pair(s)\n");

    // Identify Namespace 1
    if (!identifyNamespace(1)) {
        serial.writeString("[NVMe] Identify Namespace 1 failed\n");
        return;
    }

    // Register with block_dev
    var nvme_name: [16]u8 = @splat(0);
    nvme_name[0] = 'n';
    nvme_name[1] = 'v';
    nvme_name[2] = 'm';
    nvme_name[3] = 'e';
    nvme_name[4] = '0';
    _ = block_dev.registerDevice(.{
        .dev_type = .nvme,
        .sector_size = lba_size,
        .total_sectors = total_lbas,
        .name = nvme_name,
        .name_len = 5,
        .supports_flush = true,
        .max_transfer_sectors = 128, // 64KB / 512B
    }, 0);

    enabled = true;
    serial.writeString("[NVMe] Initialized: ");
    fmt.writeDecimal64(total_lbas);
    serial.writeString(" sectors × ");
    fmt.writeDecimal(lba_size);
    serial.writeString(" bytes\n");
}

pub fn isEnabled() bool {
    return enabled;
}

// ─── Admin Queue Commands ────────────────────────────────────────────────

fn submitAdminCmd(cmd: *const NvmeCommand) ?NvmeCompletion {
    const sq: [*]NvmeCommand = @ptrFromInt(hhdm.physToVirt(admin_sq_phys));
    const tail = admin_sq_tail;
    sq[tail] = cmd.*;

    admin_sq_tail = (admin_sq_tail + 1) % QUEUE_DEPTH;
    writeDoorbell(admin_sq_doorbell, admin_sq_tail);

    // Poll for completion using phase bit (v52.4)
    var timeout: u32 = 2000000;
    const expected_phase = admin_cq_phase;
    while (timeout > 0) : (timeout -= 1) {
        const cq: [*]NvmeCompletion = @ptrFromInt(hhdm.physToVirt(admin_cq_phys));
        const cpl = cq[admin_cq_head];
        const phase = (cpl.status & 0x1) != 0;
        if (phase == expected_phase) {
            admin_cq_head = (admin_cq_head + 1) % QUEUE_DEPTH;
            if (admin_cq_head == 0) {
                admin_cq_phase = !admin_cq_phase;
            }
            writeDoorbell(admin_cq_doorbell, admin_cq_head);
            return cpl;
        }
        asm volatile ("pause");
    }
    return null;
}

fn zeroCommand() NvmeCommand {
    var cmd: NvmeCommand = undefined;
    const bytes: [*]u8 = @ptrCast(&cmd);
    @memset(bytes[0..@sizeOf(NvmeCommand)], 0);
    return cmd;
}

fn identifyController() ?IdentifyController {
    const id_buf_phys = pmm.allocPage() orelse return null;
    defer pmm.freePage(id_buf_phys);

    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_IDENTIFY;
    cmd.nsid = 0;
    cmd.prp1 = id_buf_phys;
    cmd.cdw10 = 1; // CNS=1 (Identify Controller)

    _ = submitAdminCmd(&cmd) orelse return null;

    const buf: *IdentifyController = @ptrFromInt(hhdm.physToVirt(id_buf_phys));
    return buf.*;
}

fn identifyNamespace(ns: u32) bool {
    const id_buf_phys = pmm.allocPage() orelse return false;
    defer pmm.freePage(id_buf_phys);

    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_IDENTIFY;
    cmd.nsid = ns;
    cmd.prp1 = id_buf_phys;
    cmd.cdw10 = 0; // CNS=0 (Identify Namespace)

    const cpl = submitAdminCmd(&cmd) orelse return false;
    const status = (cpl.status >> 1) & 0x7FF;
    if (status != 0) return false;

    const ns_data: *IdentifyNamespace = @ptrFromInt(hhdm.physToVirt(id_buf_phys));
    total_lbas = ns_data.nsze;
    nsid = ns;

    // Determine LBA size from flbas
    const lbaf_idx = ns_data.flbas & 0xF;
    // v53.1: lbads==0 means unused/unsupported LBA format
    if (ns_data.lbaf[lbaf_idx].lbads == 0) return false;
    lba_size = @as(u32, 1) << @as(u5, @intCast(ns_data.lbaf[lbaf_idx].lbads));

    return true;
}

fn createCompletionQueue(cq_id: u16, phys: u64, depth: u16) bool {
    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_CREATE_CQ;
    cmd.prp1 = phys;
    cmd.cdw10 = (@as(u32, depth - 1) << 16) | @as(u32, cq_id); // NCQR + CQID
    cmd.cdw11 = 1; // PC=1 (Physically Contiguous), IEN=1

    const cpl = submitAdminCmd(&cmd) orelse return false;
    return (cpl.status >> 1) & 0x7FF == 0;
}

fn createSubmissionQueue(sq_id: u16, phys: u64, depth: u16, cq_id: u16) bool {
    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_CREATE_SQ;
    cmd.prp1 = phys;
    cmd.cdw10 = (@as(u32, depth - 1) << 16) | @as(u32, sq_id); // NSQR + SQID
    cmd.cdw11 = (1 << 0) | (@as(u32, cq_id) << 16); // PC=1, CQID

    const cpl = submitAdminCmd(&cmd) orelse return false;
    return (cpl.status >> 1) & 0x7FF == 0;
}

/// Delete an I/O Completion Queue from the controller (v52.6)
fn deleteCompletionQueue(cq_id: u16) bool {
    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_DELETE_CQ;
    cmd.cdw10 = cq_id; // CQID
    const cpl = submitAdminCmd(&cmd) orelse return false;
    return (cpl.status >> 1) & 0x7FF == 0;
}

// ─── I/O Commands ────────────────────────────────────────────────────────

fn submitIoCmd(queue_idx: u32, cmd: *const NvmeCommand) ?NvmeCompletion {
    const q = queue_idx;
    const sq: [*]NvmeCommand = @ptrFromInt(hhdm.physToVirt(io_sq_phys[q]));
    const tail = io_sq_tail[q];
    sq[tail] = cmd.*;

    io_sq_tail[q] = (io_sq_tail[q] + 1) % QUEUE_DEPTH;
    writeDoorbell(io_sq_doorbell[q], io_sq_tail[q]);

    // Poll for completion using phase bit (v52.3 fix)
    var timeout: u32 = 5000000;
    const expected_phase = io_cq_phase[q];
    while (timeout > 0) : (timeout -= 1) {
        const cq: [*]NvmeCompletion = @ptrFromInt(hhdm.physToVirt(io_cq_phys[q]));
        const cpl = cq[io_cq_head[q]];
        const phase = (cpl.status & 0x1) != 0;
        if (phase == expected_phase) {
            io_cq_head[q] = (io_cq_head[q] + 1) % QUEUE_DEPTH;
            // Phase toggles when CQ wraps around
            if (io_cq_head[q] == 0) {
                io_cq_phase[q] = !io_cq_phase[q];
            }
            writeDoorbell(io_cq_doorbell[q], io_cq_head[q]);
            return cpl;
        }
        asm volatile ("pause");
    }
    return null;
}

/// Select next I/O queue via round-robin (v52.0).
inline fn selectQueue() u32 {
    if (num_io_queues <= 1) return 0;
    // v52.6: atomic increment for SMP safety (.acq_rel for proper ordering)
    const old = @atomicRmw(u32, &io_queue_rr, .Add, 1, .acq_rel);
    return old % num_io_queues;
}

/// Read sectors from NVMe device.
/// Returns number of sectors read, or negative error.
pub fn readSectors(lba: u64, count: u32, buf: [*]u8) i32 {
    if (!enabled) return -1;
    const q = selectQueue();

    // Determine buffer physical address
    const buf_phys = hhdm.virtToPhys(@intFromPtr(buf));

    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_READ;
    cmd.nsid = nsid;
    cmd.prp1 = buf_phys;
    cmd.cdw10 = @truncate(lba); // SLBA low
    cmd.cdw11 = @truncate(lba >> 32); // SLBA high
    cmd.cdw12 = (count - 1) & 0xFFFF; // NLB (0-based)

    // For transfers crossing a page boundary, set PRP2
    const bytes = @as(u64, count) * lba_size;
    const page_offset = buf_phys & 0xFFF;
    if (page_offset + bytes > 4096) {
        // Need PRP2 for second page
        const page2_phys = (buf_phys + 4096) & ~@as(u64, 0xFFF);
        cmd.prp2 = page2_phys;
    }

    // For larger transfers (crossing >2 pages), use PRP list
    // v52.5 fix: use page_offset+bytes instead of bytes alone for non-page-aligned buffers
    if (page_offset + bytes > 8192) {
        const prp_list: [*]u64 = @ptrFromInt(hhdm.physToVirt(prp_list_phys[q]));
        @memset(@as([*]u8, @ptrCast(prp_list))[0..4096], 0);
        var prp_count: u32 = 0;
        var cur_phys = (buf_phys + 4096) & ~@as(u64, 0xFFF);
        while (cur_phys < buf_phys + bytes and prp_count < 512) : (prp_count += 1) {
            prp_list[prp_count] = cur_phys;
            cur_phys += 4096;
        }
        cmd.prp2 = prp_list_phys[q];
    }

    const cpl = submitIoCmd(q, &cmd) orelse return -1;
    const status = (cpl.status >> 1) & 0x7FF;
    if (status != 0) {
        serial.writeString("[NVMe] Read error: status=0x");
        fmt.writeHex32(status);
        serial.writeString("\n");
        return -1;
    }
    return @intCast(count);
}

/// Write sectors to NVMe device.
/// Returns number of sectors written, or negative error.
pub fn writeSectors(lba: u64, count: u32, buf: [*]const u8) i32 {
    if (!enabled) return -1;
    const q = selectQueue();

    const buf_phys = hhdm.virtToPhys(@intFromPtr(buf));

    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_WRITE;
    cmd.nsid = nsid;
    cmd.prp1 = buf_phys;
    cmd.cdw10 = @truncate(lba);
    cmd.cdw11 = @truncate(lba >> 32);
    cmd.cdw12 = (count - 1) & 0xFFFF;

    const bytes = @as(u64, count) * lba_size;
    const page_offset = buf_phys & 0xFFF;
    if (page_offset + bytes > 4096) {
        const page2_phys = (buf_phys + 4096) & ~@as(u64, 0xFFF);
        cmd.prp2 = page2_phys;
    }
    // v52.5 fix: use page_offset+bytes for non-page-aligned buffers
    if (page_offset + bytes > 8192) {
        const prp_list: [*]u64 = @ptrFromInt(hhdm.physToVirt(prp_list_phys[q]));
        @memset(@as([*]u8, @ptrCast(prp_list))[0..4096], 0);
        var prp_count: u32 = 0;
        var cur_phys = (buf_phys + 4096) & ~@as(u64, 0xFFF);
        while (cur_phys < buf_phys + bytes and prp_count < 512) : (prp_count += 1) {
            prp_list[prp_count] = cur_phys;
            cur_phys += 4096;
        }
        cmd.prp2 = prp_list_phys[q];
    }

    const cpl = submitIoCmd(q, &cmd) orelse return -1;
    const status = (cpl.status >> 1) & 0x7FF;
    if (status != 0) {
        return -1;
    }
    return @intCast(count);
}
