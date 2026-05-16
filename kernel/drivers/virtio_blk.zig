/// Virtio-block device driver for virtio-blk-pci.
///
/// Provides sector read/write operations via the virtio transport.
/// Detects virtio-blk devices via PCI vendor 0x1AF4, device 0x1001.

const serial = @import("../arch/x86_64/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const pmm = @import("../mm/pmm.zig");
const pci = @import("pci.zig");

pub const SECTOR_SIZE: u32 = 512;

// Virtio PCI configuration (via capabilities or legacy)
const VIRTIO_PCI_QUEUE_SEL: u32 = 0x0E;
const VIRTIO_PCI_QUEUE_NUM: u32 = 0x0C;
const VIRTIO_PCI_QUEUE_PFN: u32 = 0x08;
const VIRTIO_PCI_QUEUE_NOTIFY: u32 = 0x10;
const VIRTIO_PCI_STATUS: u32 = 0x12;
const VIRTIO_PCI_DEVICE_FEATURES: u32 = 0x00;
const VIRTIO_PCI_DRIVER_FEATURES: u32 = 0x04;
const VIRTIO_PCI_CONFIG_OFFSET: u32 = 0x14;

// Status bits
const VIRTIO_STATUS_ACK: u8 = 1;
const VIRTIO_STATUS_DRIVER: u8 = 2;
const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
const VIRTIO_STATUS_FEATURES_OK: u8 = 8;
const VIRTIO_STATUS_FAILED: u8 = 0x80;

// Block request types
const VIRTIO_BLK_T_IN: u32 = 0;
const VIRTIO_BLK_T_OUT: u32 = 1;

// Block request status
const VIRTIO_BLK_S_OK: u8 = 0;
const VIRTIO_BLK_S_IOERR: u8 = 1;
const VIRTIO_BLK_S_UNSUPP: u8 = 2;

const QUEUE_SIZE: u32 = 256;

/// Virtio-blk request header.
const BlkReqHeader = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};

/// Virtqueue descriptor.
const VqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VqAvailable = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]u16,
};

const VqUsedElem = extern struct {
    id: u32,
    len: u32,
};

const VqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]VqUsedElem,
};

const VQ_DESC_OFF: u32 = 0;
const VQ_AVAIL_OFF: u32 = QUEUE_SIZE * 16;
const VQ_USED_OFF: u32 = 8192;

fn getDesc(vq_virt: u64, idx: u32) *volatile VqDesc {
    return @ptrFromInt(vq_virt + VQ_DESC_OFF + idx * @sizeOf(VqDesc));
}

fn getAvail(vq_virt: u64) *volatile VqAvailable {
    return @ptrFromInt(vq_virt + VQ_AVAIL_OFF);
}

fn getUsed(vq_virt: u64) *volatile VqUsed {
    return @ptrFromInt(vq_virt + VQ_USED_OFF);
}

const VirtioBlkDevice = struct {
    io_base: u64,
    config_base: u64,
    queue_phys: u64,
    queue_virt: u64,
    queue_num: u32,
    capacity_sectors: u64,
    active: bool,
    last_used_idx: u16,
    req_header_phys: u64,
    req_header_virt: u64,
    status_phys: u64,
    status_virt: u64,
};

var device: VirtioBlkDevice = .{
    .io_base = 0,
    .config_base = 0,
    .queue_phys = 0,
    .queue_virt = 0,
    .queue_num = 0,
    .capacity_sectors = 0,
    .active = false,
    .last_used_idx = 0,
    .req_header_phys = 0,
    .req_header_virt = 0,
    .status_phys = 0,
    .status_virt = 0,
};

fn readReg8(offset: u32) u8 {
    return io.inb(@intCast(device.io_base + offset));
}

fn writeReg8(offset: u32, value: u8) void {
    io.outb(@intCast(device.io_base + offset), value);
}

fn readReg16(offset: u32) u16 {
    return io.inw(@intCast(device.io_base + offset));
}

fn writeReg16(offset: u32, value: u16) void {
    io.outw(@intCast(device.io_base + offset), value);
}

fn readReg32(offset: u32) u32 {
    return io.inl(@intCast(device.io_base + offset));
}

fn writeReg32(offset: u32, value: u32) void {
    io.outl(@intCast(device.io_base + offset), value);
}

fn readConfig32(offset: u32) u32 {
    return io.inl(@intCast(device.config_base + offset));
}

pub fn init() void {
    serial.writeString("[virtio-blk] Scanning for virtio-blk devices...\n");

    for (0..pci.device_count) |i| {
        const dev = pci.devices[i];
        // Virtio-blk: vendor 0x1AF4, device 0x1001 (transitional) or 0x1042 (non-transitional)
        if (dev.vendor_id == pci.VENDOR_QEMU_VIRTIO and (dev.device_id == 0x1001 or dev.device_id == 0x1042)) {
            serial.writeString("[virtio-blk] Found at ");
            writeHex8(dev.bus);
            serial.writeString(":");
            writeHex8(dev.device);
            serial.writeString(".");
            writeHex8(dev.function);
            serial.writeString("\n");
            initDevice(&dev) catch |err| {
                serial.writeString("[virtio-blk] Init failed: ");
                serial.writeString(@errorName(err));
                serial.writeString("\n");
            };
            return;
        }
    }
    serial.writeString("[virtio-blk] No device found\n");
}

fn initDevice(dev: *const pci.PciDevice) !void {
    // Use BAR0 (I/O ports) for legacy/transitional virtio
    const bar0 = dev.bars[0];
    if (bar0 == 0) {
        serial.writeString("[virtio-blk] BAR0 is null\n");
        return error.NoBAR;
    }
    device.io_base = bar0 & 0xFFFFFFFC;

    // BAR1 + config offset for device-specific config
    // For virtio-blk legacy, config is at io_base + 0x38
    device.config_base = device.io_base + VIRTIO_PCI_CONFIG_OFFSET;

    // Map I/O region is not needed for port I/O — we use in/out instructions

    // Reset device
    writeReg8(VIRTIO_PCI_STATUS, 0);

    // Acknowledge
    writeReg8(VIRTIO_PCI_STATUS, VIRTIO_STATUS_ACK);
    writeReg8(VIRTIO_PCI_STATUS, VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER);

    // Negotiate features — accept none for simplicity (no barriers, etc.)
    const device_features = readReg32(VIRTIO_PCI_DEVICE_FEATURES);
    _ = device_features;
    writeReg32(VIRTIO_PCI_DRIVER_FEATURES, 0);

    writeReg8(VIRTIO_PCI_STATUS, VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK);
    const status = readReg8(VIRTIO_PCI_STATUS);
    if ((status & VIRTIO_STATUS_FEATURES_OK) == 0) {
        serial.writeString("[virtio-blk] Feature negotiation failed\n");
        return error.FeatureNegotiation;
    }

    // Read capacity from config (first 8 bytes = capacity in 512-byte sectors)
    const cap_lo = readConfig32(0);
    const cap_hi = readConfig32(4);
    device.capacity_sectors = (@as(u64, cap_hi) << 32) | cap_lo;

    serial.writeString("[virtio-blk] Capacity: ");
    writeDecimal64(device.capacity_sectors);
    serial.writeString(" sectors (");
    writeDecimal64(device.capacity_sectors / 2);
    serial.writeString(" KB)\n");

    // Set up virtqueue 0 (request queue)
    writeReg16(VIRTIO_PCI_QUEUE_SEL, 0);
    const queue_size = readReg16(VIRTIO_PCI_QUEUE_NUM);
    if (queue_size == 0) {
        serial.writeString("[virtio-blk] Queue 0 has size 0\n");
        return error.BadQueue;
    }
    device.queue_num = queue_size;

    // Allocate queue memory (3 pages for desc+avail+used)
    const queue_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const queue_phys2 = pmm.allocPage() orelse {
        pmm.freePage(queue_phys);
        return error.OutOfMemory;
    };
    const queue_phys3 = pmm.allocPage() orelse {
        pmm.freePage(queue_phys2);
        pmm.freePage(queue_phys);
        return error.OutOfMemory;
    };
    const queue_virt = hhdm.physToVirt(queue_phys);
    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    paging.mapPage(pml4, queue_virt + paging.PAGE_SIZE, queue_phys2, flags) catch {};
    paging.mapPage(pml4, queue_virt + 2 * paging.PAGE_SIZE, queue_phys3, flags) catch {};

    // Zero the queue (3 pages)
    var qptr: [*]u8 = @ptrFromInt(queue_virt);
    @memset(qptr[0 .. paging.PAGE_SIZE * 3], 0);

    device.queue_phys = queue_phys;
    device.queue_virt = queue_virt;

    // Register the queue (legacy: write page frame number = phys / 4096)
    writeReg32(VIRTIO_PCI_QUEUE_PFN, @truncate(queue_phys / paging.PAGE_SIZE));

    // Allocate request header and status bytes
    const req_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const req_virt = hhdm.physToVirt(req_phys);
    var rptr: [*]u8 = @ptrFromInt(req_virt);
    @memset(rptr[0..paging.PAGE_SIZE], 0);
    device.req_header_phys = req_phys;
    device.req_header_virt = req_virt;

    const stat_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const stat_virt = hhdm.physToVirt(stat_phys);
    var sptr: [*]u8 = @ptrFromInt(stat_virt);
    @memset(sptr[0..paging.PAGE_SIZE], 0);
    device.status_phys = stat_phys;
    device.status_virt = stat_virt;

    // Driver OK
    writeReg8(VIRTIO_PCI_STATUS, VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK);

    device.active = true;
    device.last_used_idx = 0;

    serial.writeString("[virtio-blk] Initialized, queue size=");
    writeDecimal(queue_size);
    serial.writeString("\n");
}

/// Read sectors from the virtio-blk device.
/// Returns bytes read or -1 on error.
pub fn readSectors(lba: u64, count: u32, buf: [*]u8) i64 {
    if (!device.active) return -1;
    if (count == 0 or count > 128) return -1;

    const buf_phys = virtToPhys(@intFromPtr(buf));

    // Set up request header
    const req: *volatile BlkReqHeader = @ptrFromInt(device.req_header_virt);
    req.type = VIRTIO_BLK_T_IN;
    req.reserved = 0;
    req.sector = lba;

    // Set up status byte
    const status_byte: *volatile u8 = @ptrFromInt(device.status_virt);
    status_byte.* = 0xFF;

    // Set up descriptors in virtqueue
    // Desc 0: request header (device-readable)
    const d0 = getDesc(device.queue_virt, 0);
    d0.addr = device.req_header_phys;
    d0.len = @sizeOf(BlkReqHeader);
    d0.flags = 1 << 0; // VIRTQ_DESC_F_NEXT
    d0.next = 1;

    // Desc 1: data buffer (device-writable for read)
    const d1 = getDesc(device.queue_virt, 1);
    d1.addr = buf_phys;
    d1.len = count * SECTOR_SIZE;
    d1.flags = (1 << 0) | (1 << 1); // NEXT + WRITE
    d1.next = 2;

    // Desc 2: status byte (device-writable)
    const d2 = getDesc(device.queue_virt, 2);
    d2.addr = device.status_phys;
    d2.len = 1;
    d2.flags = 1 << 1; // WRITE
    d2.next = 0;

    // Add to available ring
    const avail = getAvail(device.queue_virt);
    const avail_idx = avail.idx;
    avail.ring[avail_idx % device.queue_num] = 0; // start descriptor
    asm volatile ("" ::: .{ .memory = true });
    avail.idx = avail_idx + 1;

    // Notify the device
    writeReg16(VIRTIO_PCI_QUEUE_NOTIFY, 0);

    // Wait for completion (polling)
    const used = getUsed(device.queue_virt);
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        if (used.idx != device.last_used_idx) {
            device.last_used_idx = used.idx;
            break;
        }
        asm volatile ("pause");
    }

    if (timeout == 0) {
        serial.writeString("[virtio-blk] Read timeout at LBA ");
        writeHex64(lba);
        serial.writeString("\n");
        return -1;
    }

    if (status_byte.* != VIRTIO_BLK_S_OK) {
        serial.writeString("[virtio-blk] Read error status=");
        writeHex8(status_byte.*);
        serial.writeString("\n");
        return -1;
    }

    return @intCast(count * SECTOR_SIZE);
}

/// Write sectors to the virtio-blk device.
pub fn writeSectors(lba: u64, count: u32, buf: [*]const u8) i64 {
    if (!device.active) return -1;
    if (count == 0 or count > 128) return -1;

    const buf_phys = virtToPhys(@intFromPtr(buf));

    const req: *volatile BlkReqHeader = @ptrFromInt(device.req_header_virt);
    req.type = VIRTIO_BLK_T_OUT;
    req.reserved = 0;
    req.sector = lba;

    const status_byte: *volatile u8 = @ptrFromInt(device.status_virt);
    status_byte.* = 0xFF;

    const vq_virt = device.queue_virt;

    // Desc 0: request header (device-readable)
    const d0 = getDesc(vq_virt, 0);
    d0.addr = device.req_header_phys;
    d0.len = @sizeOf(BlkReqHeader);
    d0.flags = 1 << 0; // NEXT
    d0.next = 1;

    // Desc 1: data buffer (device-readable for write)
    const d1 = getDesc(vq_virt, 1);
    d1.addr = buf_phys;
    d1.len = count * SECTOR_SIZE;
    d1.flags = 1 << 0; // NEXT (no WRITE flag = device reads)
    d1.next = 2;

    // Desc 2: status byte (device-writable)
    const d2 = getDesc(vq_virt, 2);
    d2.addr = device.status_phys;
    d2.len = 1;
    d2.flags = 1 << 1; // WRITE
    d2.next = 0;

    const avail = getAvail(vq_virt);
    const avail_idx = avail.idx;
    avail.ring[avail_idx % device.queue_num] = 0;
    asm volatile ("" ::: .{ .memory = true });
    avail.idx = avail_idx + 1;

    writeReg16(VIRTIO_PCI_QUEUE_NOTIFY, 0);

    const used = getUsed(device.queue_virt);
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        if (used.idx != device.last_used_idx) {
            device.last_used_idx = used.idx;
            break;
        }
        asm volatile ("pause");
    }

    if (timeout == 0) return -1;
    if (status_byte.* != VIRTIO_BLK_S_OK) return -1;

    return @intCast(count * SECTOR_SIZE);
}

pub fn hasActiveDisk() bool {
    return device.active;
}

pub fn getCapacity() u64 {
    return device.capacity_sectors;
}

fn virtToPhys(virt: u64) u64 {
    return hhdm.virtToPhys(virt);
}

fn writeHex8(v: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[(v >> 4) & 0xF];
    buf[1] = hex[v & 0xF];
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

fn writeDecimal64(v: u64) void {
    if (v == 0) {
        serial.writeString("0");
        return;
    }
    var buf: [20]u8 = undefined;
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
