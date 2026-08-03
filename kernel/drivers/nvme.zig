/// NVMe PCIe driver — NVM Express host controller interface.
///
/// Implements:
///   - PCI enumeration for NVMe controllers (class 0x01/0x08/0x02)
///   - Controller initialization (CC, AQA, ASQ, ACQ registers)
///   - Admin Queue + I/O Submission/Completion Queue pairs (depth 64)
///   - Identify Controller / Identify Namespace
///   - NVMe Read/Write commands using PRP entries
///   - Dataset Management (TRIM/deallocate) when ONCS bit 2 is set
///   - Integration with block_dev abstraction layer
///   - Per-CPU I/O queue selection (I3): submitters prefer
///     `cpu_id % num_io_queues`, falling back to round-robin when the
///     preferred channel is busy (policy in nvme_queue.zig, host-tested)
///
/// Limitations:
///   - Up to 4 I/O queue pairs (configurable via MAX_IO_QUEUES)
///   - PRP only (no SGL)
///   - Admin queue is polled (init-time only); I/O queues complete via MSI-X
///     interrupts when the capability is present, with a bounded-wait +
///     direct-harvest fallback and a full polling fallback when MSI-X setup
///     fails (behavior then identical to the pre-MSI-X driver).
const builtin = @import("builtin");
const serial = @import("../arch/arch.zig").serial;
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/arch.zig").paging;
const pci = @import("pci.zig");
const pci_msix = @import("pci_msix.zig");
const block_dev = @import("block_dev.zig");
const fmt = @import("../lib/fmt.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const arch_syscall = @import("../arch/arch.zig").syscall;
const nvme_queue = @import("nvme_queue.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

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
const NVME_CMD_DSM = 0x09; // Dataset Management (NVM I/O command)

// ─── NVMe Queue Constants ────────────────────────────────────────────────

const QUEUE_DEPTH = 64;

/// Maximum I/O queue pairs for parallel throughput (v52.0 multi-queue).
pub const MAX_IO_QUEUES = 4;

/// First IDT vector allocated to NVMe MSI-X (242..242+MAX_IO_QUEUES-1).
/// Sits above the LAPIC timer (240) and AHCI (241) vectors and below the
/// yield trap (252) / reschedule / TLB-shootdown IPIs (253/254).
pub const NVME_IRQ_VECTOR_BASE: u8 = 242;

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
    oncs: u16, // Optional NVM Command Support (byte 520; bit 2 = Dataset Mgmt)
    rsvd4: [154]u8,
};

// ─── NVMe Dataset Management Range (16 bytes, NVM spec fig. "Dataset ──────
// Management — Range Definition") ─────────────────────────────────────────

const DsmRange = extern struct {
    cattr: u32, // Context Attributes (0 = no attribute)
    len: u32, // Length in logical blocks
    slba: u64, // Starting LBA
};

const DSM_ATTR_DEALLOCATE: u32 = 1 << 2; // CDW11 bit 2 (AD)
const ONCS_DSM: u16 = 1 << 2; // ONCS bit 2: Dataset Management command

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
// One lock per I/O queue (SMP fix): covers submit+poll+PRP-list rebuild.
// Two CPUs landing on the same queue would otherwise interleave the
// io_sq_tail/io_cq_head read-modify-write and rebuild prp_list_phys[q]
// while the other CPU's DMA reads it.
var io_locks: [MAX_IO_QUEUES]IrqSpinlock = @splat(.{});
var num_io_queues: u32 = 0; // Actual number of I/O queues created
var io_queue_rr: u32 = 0; // Round-robin fallback counter (busy preferred queue)

// ─── Interrupt-driven completion (MSI-X) ─────────────────────────────────
//
// Lock ordering: io_locks[q] → task.zig's task_lock (via unblockTask).
// io_locks[q] protects SQ/CQ pointers, the PRP list rebuild, in-flight
// channel ownership and the wait lists. It is never held while sleeping:
// waiters link their WaitNode under it, release it, then park. The ISR
// takes only io_locks[q], so IRQ-off sections stay short and cannot
// deadlock with a blocked submitter (which holds no locks while parked).

/// Located MSI-X table (null when the controller has no MSI-X capability).
var msix_table: ?pci.MsixTable = null;
/// Number of MSI-X vectors programmed (0 = polling fallback).
var msix_vectors: u32 = 0;
/// MSI-X table index each I/O queue's CQ raises: the queue index when
/// per-queue vectors were granted, shared indexes when fewer vectors were
/// available than queues.
var iv_of_queue: [MAX_IO_QUEUES]u16 = @splat(0);

/// Channel ownership: exactly one command in flight per I/O queue, so the
/// per-queue PRP list page is never rebuilt while a DMA still references it.
/// (Replaces the old whole-operation io_locks[q] hold, which would have
/// prevented the ISR from taking the lock while a submitter sleeps.)
var io_in_flight: [MAX_IO_QUEUES]bool = @splat(false);
/// Completion handoff ISR → submitter (all protected by io_locks[q]).
var io_done: [MAX_IO_QUEUES]bool = @splat(false);
var io_result: [MAX_IO_QUEUES]NvmeCompletion = @splat(undefined);
var io_cpl_wait: [MAX_IO_QUEUES]?*task.WaitNode = @splat(null);
var io_chan_wait: [MAX_IO_QUEUES]?*task.WaitNode = @splat(null);

// Serializes admin queue submission. Admin commands only run during
// single-threaded init today, but the queue registers (admin_sq_tail,
// admin_cq_head, admin_cq_phase) are global: any future post-boot admin
// command (namespace mgmt, sanitize, log pages) would corrupt an in-flight
// submission without this lock.
var admin_lock: IrqSpinlock = .{};

var nsid: u32 = 1; // Active namespace ID
var lba_size: u32 = 512; // Logical Block Size
var total_lbas: u64 = 0; // Total LBAs in namespace
var trim_supported: bool = false; // ONCS bit 2: Dataset Management (TRIM)
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

// ─── Resource Management ─────────────────────────────────────────────────

/// Release all allocated I/O queue resources (idempotent).
fn releaseIOQueueResources() void {
    for (0..MAX_IO_QUEUES) |q| {
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
        io_sq_tail[q] = 0;
        io_cq_head[q] = 0;
        io_cq_phase[q] = true;
        io_sq_doorbell[q] = 0;
        io_cq_doorbell[q] = 0;
    }
    num_io_queues = 0;
    io_queue_rr = 0;
}

/// Release admin queue resources (idempotent).
fn releaseAdminQueueResources() void {
    if (admin_sq_phys != 0) {
        pmm.freePage(admin_sq_phys);
        admin_sq_phys = 0;
    }
    if (admin_cq_phys != 0) {
        pmm.freePage(admin_cq_phys);
        admin_cq_phys = 0;
    }
    admin_sq_tail = 0;
    admin_cq_head = 0;
    admin_cq_phase = true;
    admin_sq_doorbell = 0;
    admin_cq_doorbell = 0;
}

/// Rollback initialization on failure. Only safe before controller enable
/// or after controller disable; never free device-owned pages while DMA active.
fn rollbackInitialization() void {
    enabled = false;
    releaseIOQueueResources();
    releaseAdminQueueResources();
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
    admin_cq_phys = pmm.allocPage() orelse {
        rollbackInitialization();
        return;
    };

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
        rollbackInitialization();
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
    // IOSQES=6 (64-byte SQ entries, bits 19:16), IOCQES=4 (16-byte CQ
    // entries, bits 23:20) — QEMU 10+ rejects Create CQ/SQ with
    // "Invalid Queue Size" (0x102) when these are left at 0.
    mmioWrite32(NVME_CC, (1 << 0) | (6 << 16) | (4 << 20));

    // Wait for CSTS.RDY = 1
    timeout = 500000;
    while (timeout > 0) : (timeout -= 1) {
        const csts = mmioRead32(NVME_CSTS);
        if ((csts & 0x1) != 0) break;
        asm volatile ("pause");
    }
    if (timeout == 0) {
        serial.writeString("[NVMe] Controller failed to enable\n");
        // Controller did not become ready; disable and release resources
        mmioWrite32(NVME_CC, 0);
        timeout = 500000;
        while (timeout > 0) : (timeout -= 1) {
            const csts = mmioRead32(NVME_CSTS);
            if ((csts & 0x1) == 0) break;
            asm volatile ("pause");
        }
        rollbackInitialization();
        return;
    }

    serial.writeString("[NVMe] Controller enabled\n");

    // Interrupt-driven completion: try MSI-X (one vector per I/O queue,
    // shared-vector fallback, polling fallback when unavailable). Must run
    // before Create I/O Completion Queue so the CQ can be bound to its
    // interrupt vector (IEN + IV).
    msix_vectors = setupMsix(nvme_pci, MAX_IO_QUEUES);

    // Identify Controller
    const id_ctrl = identifyController() orelse {
        serial.writeString("[NVMe] Identify Controller failed\n");
        // Disable controller before freeing queue memory
        mmioWrite32(NVME_CC, 0);
        timeout = 500000;
        while (timeout > 0) : (timeout -= 1) {
            const csts = mmioRead32(NVME_CSTS);
            if ((csts & 0x1) == 0) break;
            asm volatile ("pause");
        }
        rollbackInitialization();
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

    // Dataset Management (TRIM/deallocate) support: ONCS bit 2 (G5).
    trim_supported = (id_ctrl.oncs & ONCS_DSM) != 0;
    if (trim_supported) {
        serial.writeString("[NVMe] TRIM supported\n");
    }

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

    // Bind each queue's CQ to an MSI-X table index: one vector per queue
    // when enough were granted, otherwise queues share vectors evenly.
    if (msix_vectors > 0) {
        for (0..MAX_IO_QUEUES) |q| {
            iv_of_queue[q] = @intCast(q % msix_vectors);
        }
    }

    var created_queues: u32 = 0;
    for (0..num_io_queues) |q| {
        const qid: u16 = @intCast(q + 1); // Queue IDs are 1-based
        // Create I/O Completion Queue
        const iv: ?u16 = if (msix_vectors > 0) iv_of_queue[q] else null;
        if (!createCompletionQueue(qid, io_cq_phys[q], QUEUE_DEPTH, iv)) {
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
        // Disable controller before freeing resources
        mmioWrite32(NVME_CC, 0);
        timeout = 500000;
        while (timeout > 0) : (timeout -= 1) {
            const csts = mmioRead32(NVME_CSTS);
            if ((csts & 0x1) == 0) break;
            asm volatile ("pause");
        }
        rollbackInitialization();
        return;
    }

    serial.writeString("[NVMe] Created ");
    fmt.writeDecimal(num_io_queues);
    serial.writeString(" I/O queue pair(s)\n");

    if (msix_vectors > 0) {
        // Unmask all interrupt vectors at the controller (INTMC: 0 = unmasked).
        mmioWrite32(NVME_INTMC, 0xFFFFFFFF);
        serial.writeString("[NVMe] MSI-X interrupts enabled (");
        fmt.writeDecimal(@min(msix_vectors, num_io_queues));
        serial.writeString(" vectors)\n");
    } else {
        serial.writeString("[NVMe] MSI-X not available, using polling fallback\n");
    }

    // Identify Namespace 1
    if (!identifyNamespace(1)) {
        serial.writeString("[NVMe] Identify Namespace 1 failed\n");
        // Disable controller before freeing resources
        mmioWrite32(NVME_CC, 0);
        timeout = 500000;
        while (timeout > 0) : (timeout -= 1) {
            const csts = mmioRead32(NVME_CSTS);
            if ((csts & 0x1) == 0) break;
            asm volatile ("pause");
        }
        rollbackInitialization();
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
        // Flush command submission is not implemented yet; do not advertise
        // persistence support through the block layer.
        .supports_flush = false,
        .max_transfer_sectors = 128, // 64KB / 512B
    }, 0);

    enabled = true;
    serial.writeString("[NVMe] Initialized: ");
    fmt.writeDecimal64(total_lbas);
    serial.writeString(" sectors × ");
    fmt.writeDecimal(lba_size);
    serial.writeString(" bytes\n");

    // Prove the interrupt-driven path end to end at boot: one sector read
    // whose completion is delivered by the ISR (no scheduler needed — the
    // pre-task wait path parks with hlt). qemu_run.sh stamps the first
    // sector of its scratch image with a known pattern.
    if (msix_vectors > 0) {
        bootIoSelfTest();
    }
}

pub fn isEnabled() bool {
    return enabled;
}

// ─── Admin Queue Commands ────────────────────────────────────────────────

fn submitAdminCmd(cmd: *const NvmeCommand) ?NvmeCompletion {
    const lock_flags = admin_lock.acquire();
    defer admin_lock.release(lock_flags);

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

fn createCompletionQueue(cq_id: u16, phys: u64, depth: u16, iv: ?u16) bool {
    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_CREATE_CQ;
    cmd.prp1 = phys;
    cmd.cdw10 = (@as(u32, depth - 1) << 16) | @as(u32, cq_id); // NCQR + CQID
    cmd.cdw11 = 1; // PC=1 (Physically Contiguous)
    if (iv) |v| {
        cmd.cdw11 |= (1 << 1) | (@as(u32, v) << 16); // IEN=1, Interrupt Vector
    }

    const cpl = submitAdminCmd(&cmd) orelse return false;
    const status = (cpl.status >> 1) & 0x7FF;
    if (status != 0) {
        serial.writeString("[NVMe] Create CQ status=0x");
        fmt.writeHex32(status);
        serial.writeString(" cdw11=0x");
        fmt.writeHex32(cmd.cdw11);
        serial.writeString("\n");
        return false;
    }
    return true;
}

// ─── MSI-X Setup ─────────────────────────────────────────────────────────

/// Locate the controller's MSI-X capability, program up to `max_vecs` table
/// entries (fixed delivery to the BSP LAPIC, vectors NVME_IRQ_VECTOR_BASE+i)
/// and enable MSI-X. Returns the number of vectors programmed; 0 means the
/// driver stays in polling mode (behavior identical to pre-MSI-X).
fn setupMsix(nvme_pci: *const pci.PciDevice, max_vecs: u32) u32 {
    // MSI-X delivery targets the LAPIC/IDT — x86_64 only. Other
    // architectures keep the polling path (they find no PCI device anyway).
    if (comptime builtin.cpu.arch != .x86_64) return 0;

    const table = pci.msixLocate(nvme_pci) orelse return 0;
    const n = @min(@as(u32, table.info.table_size), max_vecs);
    if (n == 0) return 0;

    // Fixed delivery to the BSP local APIC (APIC ID 0), one IDT vector per
    // table entry.
    const lapic_base: u64 = 0xFEE0_0000;
    for (0..n) |i| {
        const vector: u8 = NVME_IRQ_VECTOR_BASE + @as(u8, @intCast(i));
        pci.msixProgramVector(&table, @intCast(i), pci_msix.composeMessageAddress(lapic_base, 0), pci_msix.composeMessageData(vector));
    }
    pci.msixEnable(nvme_pci, &table);
    msix_table = table;
    return n;
}

// ─── Boot-time interrupt path self-test ──────────────────────────────────

/// Pattern qemu_run.sh stamps into the first sector of its scratch image.
const BOOT_PATTERN = "MoQiNVMe";

/// One interrupt-driven sector read at boot, validating the data against the
/// known image pattern when present. A failure here means the ISR completion
/// path is broken even though MSI-X setup reported success.
fn bootIoSelfTest() void {
    const buf_phys = pmm.allocPage() orelse return;
    defer pmm.freePage(buf_phys);
    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(buf_phys));
    @memset(buf[0..512], 0);

    if (readSectors(0, 1, buf) != 1) {
        serial.writeString("[NVMe] interrupt-driven read FAILED\n");
        return;
    }
    var matches = true;
    for (BOOT_PATTERN, 0..) |ch, i| {
        if (buf[i] != ch) matches = false;
    }
    if (matches) {
        serial.writeString("[NVMe] interrupt-driven read verified (pattern match)\n");
    } else {
        serial.writeString("[NVMe] interrupt-driven read OK (no pattern)\n");
    }
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

/// LAPIC timer period in milliseconds (~100 Hz tick; epoll.zig uses the same).
const TICK_MS: u64 = 10;
/// Bounded wait for one I/O completion. Only hit when an interrupt is lost
/// or the controller wedges; the wait loop harvests the CQ directly on every
/// wake, so a lost interrupt degrades to tick-granularity polling, never a
/// hang. Matches the spirit of the old 5M-pause polling timeout.
const NVME_WAIT_TIMEOUT_MS: u64 = 500;

/// Harvest one completion from CQ `q` if the phase bit shows one pending.
/// Caller holds io_locks[q].
fn harvestCqLocked(q: u32) ?NvmeCompletion {
    const cq: [*]NvmeCompletion = @ptrFromInt(hhdm.physToVirt(io_cq_phys[q]));
    const cpl = cq[io_cq_head[q]];
    const phase = (cpl.status & 0x1) != 0;
    if (phase != io_cq_phase[q]) return null;
    io_cq_head[q] = (io_cq_head[q] + 1) % QUEUE_DEPTH;
    // Phase toggles when CQ wraps around
    if (io_cq_head[q] == 0) {
        io_cq_phase[q] = !io_cq_phase[q];
    }
    writeDoorbell(io_cq_doorbell[q], io_cq_head[q]);
    return cpl;
}

/// Unlink a wait node from a queue-local wait list. Caller holds io_locks[q].
fn unlinkWaitLocked(queue: *?*task.WaitNode, node: *task.WaitNode) void {
    var prev: ?*task.WaitNode = null;
    var cur = queue.*;
    while (cur) |n| {
        if (n == node) {
            if (prev) |p| {
                p.next = n.next;
            } else {
                queue.* = n.next;
            }
            n.next = null;
            return;
        }
        prev = n;
        cur = n.next;
    }
}

/// Pop the head waiter from a queue-local wait list and wake its task.
/// Caller holds io_locks[q].
fn wakeOneLocked(queue: *?*task.WaitNode) void {
    const node = queue.* orelse return;
    queue.* = node.next;
    node.next = null;
    @atomicStore(bool, &node.granted, true, .release);
    task.unblockTask(node.task_idx);
}

inline fn tickNow() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return @import("../arch/x86_64/idt.zig").getTickCount();
    }
    // Unreachable: the interrupt-driven wait is only entered when MSI-X was
    // enabled, which setupMsix restricts to x86_64.
    return 0;
}

inline fn parkUntilInterrupt() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("sti; hlt");
    } else if (comptime builtin.cpu.arch == .riscv64) {
        asm volatile ("wfi");
    } else if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("wfi");
    } else {
        unreachable;
    }
}

/// Acquire exclusive ownership of queue `q`'s command channel (one command
/// in flight per queue). Parks on io_chan_wait[q] while another submitter
/// owns the channel; spins when called before the scheduler exists.
fn acquireChannel(q: u32) void {
    const my_idx = sched.currentTaskIndex();
    var node: task.WaitNode = .{ .task_idx = 0 };
    var linked = false;
    while (true) {
        const flags = io_locks[q].acquire();
        if (!io_in_flight[q]) {
            io_in_flight[q] = true;
            // Our node may still be linked from a previous park iteration
            // (we won the channel before the waker popped us) — unlink it so
            // no later wake writes through a stale stack pointer.
            if (linked) unlinkWaitLocked(&io_chan_wait[q], &node);
            io_locks[q].release(flags);
            // Restore the .blocked state we set while parked (no-op if the
            // waker already did).
            if (linked) task.unblockTask(my_idx.?);
            return;
        }
        if (my_idx == null) {
            // Pre-scheduler boot path: single-threaded, so the channel is
            // always free; spin defensively.
            io_locks[q].release(flags);
            asm volatile ("pause");
            continue;
        }
        // Link (once) while holding the lock — lost-wake safe against
        // releaseChannel, which pops waiters under the same lock.
        if (!linked) {
            node.task_idx = my_idx.?;
            node.next = io_chan_wait[q];
            io_chan_wait[q] = &node;
            linked = true;
        }
        if (task.getTask(my_idx.?)) |t| t.state = .blocked;
        io_locks[q].release(flags);
        parkUntilInterrupt();
    }
}

/// Release queue `q`'s command channel and wake the next parked submitter.
fn releaseChannel(q: u32) void {
    const flags = io_locks[q].acquire();
    io_in_flight[q] = false;
    wakeOneLocked(&io_chan_wait[q]);
    io_locks[q].release(flags);
}

/// Submit a command on an I/O queue and wait for completion.
/// The caller owns the queue channel (acquireChannel).
///
/// MSI-X mode: park until the ISR harvests the CQ and wakes us. The wait is
/// bounded (NVME_WAIT_TIMEOUT_MS) and every wake re-harvests the CQ
/// directly, so a lost interrupt falls back to tick-granularity polling
/// instead of hanging.
///
/// Polling mode (MSI-X unavailable): the pre-MSI-X spin loop, unchanged.
fn submitIoCmd(queue_idx: u32, cmd: *const NvmeCommand) ?NvmeCompletion {
    const q = queue_idx;

    {
        const flags = io_locks[q].acquire();
        const sq: [*]NvmeCommand = @ptrFromInt(hhdm.physToVirt(io_sq_phys[q]));
        const tail = io_sq_tail[q];
        sq[tail] = cmd.*;
        io_sq_tail[q] = (io_sq_tail[q] + 1) % QUEUE_DEPTH;
        writeDoorbell(io_sq_doorbell[q], io_sq_tail[q]);
        io_locks[q].release(flags);
    }

    if (msix_vectors == 0) {
        return pollCompletion(q);
    }
    return waitCompletionIrq(q);
}

/// Legacy spin-poll completion (pre-MSI-X behavior, polling fallback).
fn pollCompletion(q: u32) ?NvmeCompletion {
    var timeout: u32 = 5000000;
    while (timeout > 0) : (timeout -= 1) {
        const flags = io_locks[q].acquire();
        const cpl = harvestCqLocked(q);
        io_locks[q].release(flags);
        if (cpl) |c| return c;
        asm volatile ("pause");
    }
    return null;
}

/// Interrupt-driven completion wait: park until the ISR hands over a
/// completion, harvesting the CQ directly on every wake as the
/// missed-interrupt fallback. Returns null on timeout (I/O error).
fn waitCompletionIrq(q: u32) ?NvmeCompletion {
    const my_idx = sched.currentTaskIndex();
    var node: task.WaitNode = .{ .task_idx = 0 };

    // Fast path + waiter link under the queue lock (lost-wake safe: the ISR
    // harvests and wakes under the same lock).
    var flags = io_locks[q].acquire();
    if (harvestCqLocked(q)) |cpl| {
        io_locks[q].release(flags);
        return cpl;
    }
    io_done[q] = false;
    if (my_idx) |idx| {
        node.task_idx = idx;
        node.next = io_cpl_wait[q];
        io_cpl_wait[q] = &node;
        if (task.getTask(idx)) |t| t.state = .blocked;
    }
    io_locks[q].release(flags);

    const start = tickNow();
    var result: ?NvmeCompletion = null;
    while (true) {
        flags = io_locks[q].acquire();
        if (io_done[q]) {
            result = io_result[q];
            io_locks[q].release(flags);
            break;
        }
        // Missed/delayed interrupt fallback: harvest the CQ ourselves.
        if (harvestCqLocked(q)) |cpl| {
            unlinkWaitLocked(&io_cpl_wait[q], &node);
            io_locks[q].release(flags);
            result = cpl;
            break;
        }
        if ((tickNow() - start) * TICK_MS >= NVME_WAIT_TIMEOUT_MS) {
            unlinkWaitLocked(&io_cpl_wait[q], &node);
            io_locks[q].release(flags);
            serial.writeString("[NVMe] IRQ wait timeout on queue ");
            fmt.writeDecimal(q);
            serial.writeString("\n");
            break; // null — caller reports an I/O error
        }
        io_locks[q].release(flags);
        parkUntilInterrupt();
    }

    // If we left the loop without the ISR waking us (self-harvest or
    // timeout), restore the .blocked state we set above. No-op otherwise.
    if (my_idx) |idx| task.unblockTask(idx);
    return result;
}

/// MSI-X interrupt handler — called from IDT dispatch (vectors
/// NVME_IRQ_VECTOR_BASE .. NVME_IRQ_VECTOR_BASE+MAX_IO_QUEUES-1) with the
/// table index that fired. The caller has already sent the LAPIC EOI, so the
/// next interrupt can be delivered while this runs. Takes only io_locks[q];
/// never allocates, never sleeps.
pub fn handleInterrupt(table_index: u32) void {
    if (msix_vectors == 0) return;
    for (0..num_io_queues) |q| {
        if (iv_of_queue[q] != table_index) continue;
        const flags = io_locks[q].acquire();
        var completed = false;
        while (harvestCqLocked(@intCast(q))) |cpl| {
            io_result[q] = cpl;
            completed = true;
        }
        if (completed) {
            io_done[q] = true;
            wakeOneLocked(&io_cpl_wait[q]);
        }
        io_locks[q].release(flags);
    }
}

/// Select the I/O queue for one submission (I3: per-CPU affinity).
///
/// Prefers the submitting CPU's own queue (`cpu_id % num_io_queues`) so a
/// task's consecutive submissions land on the same queue — no cross-CPU
/// `io_locks[q]` contention, and the MSI-X interrupt fires on the vector of
/// the CPU that submitted. When the preferred queue's channel is busy
/// (`io_in_flight`), falls back to the round-robin counter so submitters
/// spread instead of parking behind one queue while others idle. The pure
/// policy lives in nvme_queue.pickQueue (host-tested in tests/main.zig).
inline fn selectQueue() u32 {
    if (num_io_queues <= 1) return 0;
    const cpu_id = affinityCpuId();
    const q = nvme_queue.pickQueue(cpu_id, num_io_queues, busyChannelMask(), @atomicLoad(u32, &io_queue_rr, .acquire));
    if (q != cpu_id % num_io_queues) {
        // Fallback path taken — advance the counter for the next busy hit.
        _ = @atomicRmw(u32, &io_queue_rr, .Add, 1, .acq_rel);
    }
    return q;
}

/// CPU id used for queue affinity. Kernel threads — notably the writeback
/// daemon (vfs.startWritebackThread), whose flushes reach us via
/// writeback.flushExpiredByFs → FS write callback → block_dev →
/// writeSectors — are pinned to 0 (→ queue 0): it is a single thread, and
/// binding it keeps it from disturbing the per-CPU spread of user-task
/// submissions on whichever CPU the scheduler happened to place it. The
/// busy fallback above still lets it use other queues when queue 0 is
/// occupied. Returns 0 as well before the per-CPU block exists (early
/// boot: x86_64 GS base unset — getPerCpuOrNull() == null).
inline fn affinityCpuId() u32 {
    if (sched.currentTaskIndex()) |idx| {
        if (task.getTask(idx)) |t| {
            if (!t.is_user) return 0;
        }
    }
    if (arch_syscall.getPerCpuOrNull()) |pc| return pc.cpu_id;
    return 0;
}

/// Snapshot of owned queue channels (bit q ⇔ io_in_flight[q]). Lock-free
/// heuristic for queue selection only: a stale bit steers one submission to
/// a suboptimal queue but never corrupts state — channel ownership itself
/// is still serialized by acquireChannel.
inline fn busyChannelMask() u32 {
    var mask: u32 = 0;
    for (0..num_io_queues) |q| {
        if (@atomicLoad(bool, &io_in_flight[q], .acquire))
            mask |= @as(u32, 1) << @intCast(q);
    }
    return mask;
}

/// Read sectors from NVMe device.
/// Returns number of sectors read, or negative error.
pub fn readSectors(lba: u64, count: u32, buf: [*]u8) i32 {
    if (!enabled) return -1;
    // count==0 would compute NLB as (count - 1) = 0xFFFF (u16 underflow)
    if (count == 0) return -1;
    const q = selectQueue();

    // Channel ownership serializes submit+wait+PRP-list rebuild on this
    // queue (one command in flight; the PRP page stays stable during DMA).
    // Parks instead of spinning when another submitter owns the channel.
    acquireChannel(q);
    defer releaseChannel(q);

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
        const flags = io_locks[q].acquire();
        const prp_list: [*]u64 = @ptrFromInt(hhdm.physToVirt(prp_list_phys[q]));
        @memset(@as([*]u8, @ptrCast(prp_list))[0..4096], 0);
        var prp_count: u32 = 0;
        var cur_phys = (buf_phys + 4096) & ~@as(u64, 0xFFF);
        while (cur_phys < buf_phys + bytes and prp_count < 512) : (prp_count += 1) {
            prp_list[prp_count] = cur_phys;
            cur_phys += 4096;
        }
        cmd.prp2 = prp_list_phys[q];
        io_locks[q].release(flags);
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
    // count==0 would compute NLB as (count - 1) = 0xFFFF (u16 underflow)
    if (count == 0) return -1;
    const q = selectQueue();

    // Channel ownership serializes submit+wait+PRP-list rebuild on this
    // queue (one command in flight; the PRP page stays stable during DMA).
    acquireChannel(q);
    defer releaseChannel(q);

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
        const flags = io_locks[q].acquire();
        const prp_list: [*]u64 = @ptrFromInt(hhdm.physToVirt(prp_list_phys[q]));
        @memset(@as([*]u8, @ptrCast(prp_list))[0..4096], 0);
        var prp_count: u32 = 0;
        var cur_phys = (buf_phys + 4096) & ~@as(u64, 0xFFF);
        while (cur_phys < buf_phys + bytes and prp_count < 512) : (prp_count += 1) {
            prp_list[prp_count] = cur_phys;
            cur_phys += 4096;
        }
        cmd.prp2 = prp_list_phys[q];
        io_locks[q].release(flags);
    }

    const cpl = submitIoCmd(q, &cmd) orelse return -1;
    const status = (cpl.status >> 1) & 0x7FF;
    if (status != 0) {
        return -1;
    }
    return @intCast(count);
}

// ─── TRIM (Dataset Management, G5) ───────────────────────────────────────

pub fn isTrimSupported() bool {
    return trim_supported;
}

/// Deallocate (TRIM) `count` LBAs starting at `lba` via a Dataset Management
/// command (opcode 0x09) on a regular I/O queue — same channel-ownership path
/// as read/write (one command in flight per queue keeps the range-list page
/// stable while the controller DMAs it). Returns 0 on success, -1 on error
/// or when the controller lacks DSM support.
pub fn trimSectors(lba: u64, count: u32) i32 {
    if (!enabled or !trim_supported) return -1;
    if (count == 0) return 0;
    const q = selectQueue();

    acquireChannel(q);
    defer releaseChannel(q);

    // One DSM range (16 bytes) in a PMM page (DMA-safe, physically contiguous).
    const page_phys = pmm.allocPage() orelse return -1;
    defer pmm.freePage(page_phys);
    const page: [*]u8 = @ptrFromInt(hhdm.physToVirt(page_phys));
    @memset(page[0..4096], 0);
    const ranges: *volatile DsmRange = @ptrCast(@alignCast(page));
    ranges.cattr = 0;
    ranges.len = count;
    ranges.slba = lba;

    var cmd = zeroCommand();
    cmd.opcode = NVME_CMD_DSM;
    cmd.nsid = nsid;
    cmd.prp1 = page_phys;
    cmd.cdw10 = 0; // NR — number of ranges, 0-based (1 range)
    cmd.cdw11 = DSM_ATTR_DEALLOCATE; // AD — deallocate

    const cpl = submitIoCmd(q, &cmd) orelse return -1;
    const status = (cpl.status >> 1) & 0x7FF;
    if (status != 0) {
        serial.writeString("[NVMe] TRIM error: status=0x");
        fmt.writeHex32(status);
        serial.writeString("\n");
        return -1;
    }
    return 0;
}
