/// Virtio-net device driver for virtio-net-pci.
///
/// Provides high-performance network I/O via the virtio transport.
/// Detects virtio-net devices via PCI vendor 0x1AF4, device 0x1000.
///
/// Design:
///   - Legacy virtio PCI (I/O port based)
///   - Two virtqueues: RX (queue 0) and TX (queue 1)
///   - Interrupt-driven receive
///   - Simple synchronous transmit
const serial = @import("../arch/arch.zig").serial;
const io = @import("../arch/arch.zig").io;
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/arch.zig").paging;
const pmm = @import("../mm/pmm.zig");
const pci = @import("pci.zig");
const fmt = @import("../lib/fmt.zig");

// Virtio PCI registers (legacy)
const VIRTIO_PCI_QUEUE_SEL: u32 = 0x0E;
const VIRTIO_PCI_QUEUE_NUM: u32 = 0x0C;
const VIRTIO_PCI_QUEUE_PFN: u32 = 0x08;
const VIRTIO_PCI_QUEUE_NOTIFY: u32 = 0x10;
const VIRTIO_PCI_STATUS: u32 = 0x12;
const VIRTIO_PCI_DEVICE_FEATURES: u32 = 0x00;
const VIRTIO_PCI_DRIVER_FEATURES: u32 = 0x04;
const VIRTIO_PCI_ISR: u32 = 0x13;
const VIRTIO_PCI_CONFIG_OFFSET: u32 = 0x14;

// Status bits
const VIRTIO_STATUS_ACK: u8 = 1;
const VIRTIO_STATUS_DRIVER: u8 = 2;
const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
const VIRTIO_STATUS_FEATURES_OK: u8 = 8;

// Virtio-net feature bits
const VIRTIO_NET_F_MAC: u32 = 0x20; // Device has given MAC address
const VIRTIO_NET_F_STATUS: u32 = 0x10; // Device status available

const QUEUE_SIZE: u32 = 128;

/// Virtqueue descriptor.
const VqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VQ_DESC_NEXT: u16 = 1;
const VQ_DESC_WRITE: u16 = 2; // device-writable

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

// Virtqueue layout offsets (for 128-entry queue)
const VQ_DESC_OFF: u32 = 0;
const VQ_AVAIL_OFF: u32 = QUEUE_SIZE * 16; // 2048
const VQ_USED_OFF: u32 = 8192; // after avail + padding to 4K

/// Virtio-net header (12 bytes with mergeable rx buffers disabled).
const VirtioNetHdr = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
};

const Virtqueue = struct {
    phys: u64,
    virt: u64,
    num: u32,
    free_head: u16,
    free_count: u16,
    last_used_idx: u16,
    // Buffer tracking: physical address of each descriptor's buffer
    buf_phys: [QUEUE_SIZE]u64,
};

const VirtioNetDevice = struct {
    io_base: u64,
    active: bool,
    mac: [6]u8,
    rx_queue: Virtqueue,
    tx_queue: Virtqueue,
    pci_bus: u8,
    pci_dev: u8,
    pci_func: u8,
    irq_line: u8,
};

var device: VirtioNetDevice = .{
    .io_base = 0,
    .active = false,
    .mac = .{0} ** 6,
    .rx_queue = .{
        .phys = 0,
        .virt = 0,
        .num = 0,
        .free_head = 0,
        .free_count = 0,
        .last_used_idx = 0,
        .buf_phys = .{0} ** QUEUE_SIZE,
    },
    .tx_queue = .{
        .phys = 0,
        .virt = 0,
        .num = 0,
        .free_head = 0,
        .free_count = 0,
        .last_used_idx = 0,
        .buf_phys = .{0} ** QUEUE_SIZE,
    },
    .pci_bus = 0,
    .pci_dev = 0,
    .pci_func = 0,
    .irq_line = 0,
};

pub fn isActive() bool {
    return device.active;
}

pub fn getMAC() [6]u8 {
    return device.mac;
}

pub fn getIrqLine() u8 {
    return device.irq_line;
}

// ─── Virtqueue helpers ──────────────────────────────────────────────────────

fn vqGetDesc(vq: *Virtqueue, idx: u32) *volatile VqDesc {
    return @ptrFromInt(vq.virt + VQ_DESC_OFF + idx * @sizeOf(VqDesc));
}

fn vqGetAvail(vq: *Virtqueue) *volatile VqAvailable {
    return @ptrFromInt(vq.virt + VQ_AVAIL_OFF);
}

fn vqGetUsed(vq: *Virtqueue) *volatile VqUsed {
    return @ptrFromInt(vq.virt + VQ_USED_OFF);
}

fn vqAllocDesc(vq: *Virtqueue) ?u16 {
    if (vq.free_count == 0) return null;
    const idx = vq.free_head;
    const desc = vqGetDesc(vq, idx);
    vq.free_head = desc.next;
    vq.free_count -= 1;
    return idx;
}

fn vqFreeDesc(vq: *Virtqueue, idx: u16) void {
    const desc = vqGetDesc(vq, idx);
    desc.next = vq.free_head;
    vq.free_head = idx;
    vq.free_count += 1;
}

fn initVirtqueue(vq: *Virtqueue, io_base: u64, queue_idx: u16) !void {
    const base = io_base;
    io.outw(@intCast(base + VIRTIO_PCI_QUEUE_SEL), queue_idx);
    const qsize = io.inw(@intCast(base + VIRTIO_PCI_QUEUE_NUM));
    if (qsize == 0) return error.BadQueue;
    vq.num = qsize;

    // Allocate 3 pages for desc+avail+used
    const p1 = pmm.allocPage() orelse return error.OutOfMemory;
    const p2 = pmm.allocPage() orelse {
        pmm.freePage(p1);
        return error.OutOfMemory;
    };
    const p3 = pmm.allocPage() orelse {
        pmm.freePage(p2);
        pmm.freePage(p1);
        return error.OutOfMemory;
    };
    const virt = hhdm.physToVirt(p1);
    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    paging.mapPage(pml4, virt + paging.PAGE_SIZE, p2, flags) catch {};
    paging.mapPage(pml4, virt + 2 * paging.PAGE_SIZE, p3, flags) catch {};

    // Zero 3 pages
    const ptr: [*]u8 = @ptrFromInt(virt);
    @memset(ptr[0 .. paging.PAGE_SIZE * 3], 0);

    vq.phys = p1;
    vq.virt = virt;
    vq.free_head = 0;
    vq.free_count = @intCast(qsize);
    vq.last_used_idx = 0;

    // Initialize free list
    for (0..qsize) |i| {
        const desc = vqGetDesc(vq, @intCast(i));
        desc.next = @intCast((i + 1) % qsize);
    }

    // Register queue with device
    io.outw(@intCast(base + VIRTIO_PCI_QUEUE_SEL), queue_idx);
    io.outl(@intCast(base + VIRTIO_PCI_QUEUE_PFN), @truncate(p1 / paging.PAGE_SIZE));
}

// ─── Initialization ──────────────────────────────────────────────────────────

pub fn init() void {
    serial.writeString("[virtio-net] Scanning for virtio-net devices...\n");

    for (0..pci.device_count) |i| {
        const dev = pci.devices[i];
        // virtio-net: vendor 0x1AF4, device 0x1000
        if (dev.vendor_id == pci.VENDOR_QEMU_VIRTIO and dev.device_id == 0x1000) {
            serial.writeString("[virtio-net] Found at ");
            fmt.writeHex8(dev.bus);
            serial.writeString(":");
            fmt.writeHex8(dev.device);
            serial.writeString(".");
            fmt.writeHex8(dev.function);
            serial.writeString("\n");

            initDevice(&dev) catch |err| {
                serial.writeString("[virtio-net] Init failed: ");
                serial.writeString(@errorName(err));
                serial.writeString("\n");
            };
            return; // only init first device
        }
    }
    serial.writeString("[virtio-net] No device found\n");
}

fn initDevice(dev: *const pci.PciDevice) !void {
    device.pci_bus = dev.bus;
    device.pci_dev = dev.device;
    device.pci_func = dev.function;

    // Enable bus mastering, disable INTx initially
    var cmd = pci.configRead32(dev.bus, dev.device, dev.function, 0x04);
    cmd = (cmd & ~@as(u32, 0x400)) | 0x04; // clear INTx disable, enable bus master
    pci.configWrite32(dev.bus, dev.device, dev.function, 0x04, cmd);

    // Read IRQ line
    device.irq_line = @truncate(pci.configRead32(dev.bus, dev.device, dev.function, 0x3C) & 0xFF);

    const bar0 = dev.bars[0];
    if (bar0 == 0) return error.NoBAR;
    device.io_base = bar0 & 0xFFFFFFFC;
    const base = device.io_base;

    // Reset
    io.outb(@intCast(base + VIRTIO_PCI_STATUS), 0);
    // Acknowledge
    io.outb(@intCast(base + VIRTIO_PCI_STATUS), VIRTIO_STATUS_ACK);
    io.outb(@intCast(base + VIRTIO_PCI_STATUS), VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER);

    // Feature negotiation
    const features = io.inl(@intCast(base + VIRTIO_PCI_DEVICE_FEATURES));
    // Accept MAC and STATUS features
    var driver_features: u32 = 0;
    if (features & VIRTIO_NET_F_MAC != 0) driver_features |= VIRTIO_NET_F_MAC;
    if (features & VIRTIO_NET_F_STATUS != 0) driver_features |= VIRTIO_NET_F_STATUS;
    io.outl(@intCast(base + VIRTIO_PCI_DRIVER_FEATURES), driver_features);

    io.outb(@intCast(base + VIRTIO_PCI_STATUS), VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK);
    const status = io.inb(@intCast(base + VIRTIO_PCI_STATUS));
    if ((status & VIRTIO_STATUS_FEATURES_OK) == 0) return error.FeatureNegotiation;

    // Read MAC address from config space
    if (features & VIRTIO_NET_F_MAC != 0) {
        for (0..6) |j| {
            device.mac[j] = io.inb(@intCast(base + VIRTIO_PCI_CONFIG_OFFSET + @as(u32, @intCast(j))));
        }
        serial.writeString("[virtio-net] MAC: ");
        for (0..6) |j| {
            fmt.writeHex8(device.mac[j]);
            if (j < 5) serial.writeString(":");
        }
        serial.writeString("\n");
    }

    // Initialize RX virtqueue (queue 0)
    try initVirtqueue(&device.rx_queue, base, 0);
    serial.writeString("[virtio-net] RX queue initialized\n");

    // Initialize TX virtqueue (queue 1)
    try initVirtqueue(&device.tx_queue, base, 1);
    serial.writeString("[virtio-net] TX queue initialized\n");

    // Pre-populate RX queue with buffers
    try populateRxQueue();

    // Enable interrupts
    // Clear ISR
    _ = io.inb(@intCast(base + VIRTIO_PCI_ISR));
    // Enable INTx
    cmd = pci.configRead32(dev.bus, dev.device, dev.function, 0x04);
    cmd = (cmd & ~@as(u32, 0x400)) | 0x04;
    pci.configWrite32(dev.bus, dev.device, dev.function, 0x04, cmd);

    // Set DRIVER_OK
    io.outb(@intCast(base + VIRTIO_PCI_STATUS), VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK);

    device.active = true;
    serial.writeString("[virtio-net] Device ready\n");
}

/// Pre-populate the RX queue with empty buffers.
fn populateRxQueue() !void {
    const vq = &device.rx_queue;
    const num_bufs = @min(vq.num, QUEUE_SIZE);

    for (0..num_bufs) |_| {
        // Each RX entry: header (12 bytes) + data buffer (1514 bytes) = 2 descriptors
        const hdr_idx = vqAllocDesc(vq) orelse return error.OutOfDescs;
        const data_idx = vqAllocDesc(vq) orelse {
            vqFreeDesc(vq, hdr_idx);
            return error.OutOfDescs;
        };

        // Allocate header page
        const hdr_phys = pmm.allocPage() orelse {
            vqFreeDesc(vq, data_idx);
            vqFreeDesc(vq, hdr_idx);
            return error.OutOfMemory;
        };
        const hdr_virt = hhdm.physToVirt(hdr_phys);
        @memset(@as([*]u8, @ptrFromInt(hdr_virt))[0..paging.PAGE_SIZE], 0);

        // Allocate data page
        const data_phys = pmm.allocPage() orelse {
            pmm.freePage(hdr_phys);
            vqFreeDesc(vq, data_idx);
            vqFreeDesc(vq, hdr_idx);
            return error.OutOfMemory;
        };
        const data_virt = hhdm.physToVirt(data_phys);
        @memset(@as([*]u8, @ptrFromInt(data_virt))[0..paging.PAGE_SIZE], 0);

        vq.buf_phys[hdr_idx] = hdr_phys;
        vq.buf_phys[data_idx] = data_phys;

        // Set up descriptors: header → data (chained)
        const hdr_desc = vqGetDesc(vq, hdr_idx);
        hdr_desc.addr = hdr_phys;
        hdr_desc.len = @sizeOf(VirtioNetHdr);
        hdr_desc.flags = VQ_DESC_WRITE | VQ_DESC_NEXT;
        hdr_desc.next = data_idx;

        const data_desc = vqGetDesc(vq, data_idx);
        data_desc.addr = data_phys;
        data_desc.len = 1514 + 12; // MTU + extra
        data_desc.flags = VQ_DESC_WRITE;
        data_desc.next = 0;

        // Submit to available ring
        const avail = vqGetAvail(vq);
        const avail_idx = avail.idx;
        avail.ring[avail_idx % QUEUE_SIZE] = hdr_idx;
        asm volatile ("" ::: .{ .memory = true });
        avail.idx = avail_idx + 1;
    }

    // Notify device
    io.outw(@intCast(device.io_base + VIRTIO_PCI_QUEUE_NOTIFY), 0);
}

// ─── Transmit ────────────────────────────────────────────────────────────────

/// Send a packet via virtio-net.
/// `pkt` should be a complete Ethernet frame (including ETH header).
pub fn sendPacket(pkt: [*]const u8, len: u32) bool {
    if (!device.active or len == 0 or len > 1514) return false;

    const vq = &device.tx_queue;

    // Need 2 descriptors: header + data
    const hdr_idx = vqAllocDesc(vq) orelse return false;
    const data_idx = vqAllocDesc(vq) orelse {
        vqFreeDesc(vq, hdr_idx);
        return false;
    };

    // Allocate header buffer
    const hdr_phys = pmm.allocPage() orelse {
        vqFreeDesc(vq, data_idx);
        vqFreeDesc(vq, hdr_idx);
        return false;
    };
    const hdr_virt = hhdm.physToVirt(hdr_phys);
    @memset(@as([*]u8, @ptrFromInt(hdr_virt))[0..paging.PAGE_SIZE], 0);

    // Allocate data buffer and copy packet
    const data_phys = pmm.allocPage() orelse {
        pmm.freePage(hdr_phys);
        vqFreeDesc(vq, data_idx);
        vqFreeDesc(vq, hdr_idx);
        return false;
    };
    const data_virt = hhdm.physToVirt(data_phys);
    const data_ptr: [*]u8 = @ptrFromInt(data_virt);
    @memcpy(data_ptr[0..len], pkt[0..len]);

    vq.buf_phys[hdr_idx] = hdr_phys;
    vq.buf_phys[data_idx] = data_phys;

    // Header descriptor (device-readable)
    const hdr_desc = vqGetDesc(vq, hdr_idx);
    hdr_desc.addr = hdr_phys;
    hdr_desc.len = @sizeOf(VirtioNetHdr);
    hdr_desc.flags = VQ_DESC_NEXT;
    hdr_desc.next = data_idx;

    // Data descriptor (device-readable)
    const data_desc = vqGetDesc(vq, data_idx);
    data_desc.addr = data_phys;
    data_desc.len = len;
    data_desc.flags = 0;
    data_desc.next = 0;

    // Submit
    const avail = vqGetAvail(vq);
    const avail_idx = avail.idx;
    avail.ring[avail_idx % QUEUE_SIZE] = hdr_idx;
    asm volatile ("" ::: .{ .memory = true });
    avail.idx = avail_idx + 1;

    // Notify device (queue 1 = TX)
    io.outw(@intCast(device.io_base + VIRTIO_PCI_QUEUE_NOTIFY), 1);

    // Wait for completion (synchronous TX)
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const used = vqGetUsed(vq);
        if (used.idx != vq.last_used_idx) {
            // Process completed TX
            const elem = used.ring[vq.last_used_idx % QUEUE_SIZE];
            // Free the descriptor chain
            vqFreeDesc(vq, @intCast(elem.id));
            // Free the chained data desc (it was hdr_desc.next)
            const chain_desc = vqGetDesc(vq, elem.id);
            if (chain_desc.flags & VQ_DESC_NEXT != 0) {
                vqFreeDesc(vq, chain_desc.next);
            }
            // Free physical pages
            pmm.freePage(hdr_phys);
            pmm.freePage(data_phys);
            vq.last_used_idx = used.idx;
            return true;
        }
        asm volatile ("pause");
    }

    // Timeout — leak buffers but continue
    return false;
}

// ─── Receive (interrupt-driven) ──────────────────────────────────────────────

/// Handle virtio-net interrupt. Called from IDT IRQ handler.
pub fn handleInterrupt() void {
    if (!device.active) return;

    // Read and clear ISR
    const isr = io.inb(@intCast(device.io_base + VIRTIO_PCI_ISR));
    if (isr == 0) return;

    // Process RX completions
    processRxQueue();
}

fn processRxQueue() void {
    const vq = &device.rx_queue;
    const used = vqGetUsed(vq);

    while (vq.last_used_idx != used.idx) {
        const elem = used.ring[vq.last_used_idx % QUEUE_SIZE];
        const total_len = elem.len;

        // The data starts after the virtio-net header in the second descriptor
        const hdr_desc = vqGetDesc(vq, elem.id);
        const data_desc_idx = hdr_desc.next;
        const data_virt = hhdm.physToVirt(vq.buf_phys[data_desc_idx]);

        // Packet length = total_len - header_size
        const pkt_len: u32 = if (total_len > @sizeOf(VirtioNetHdr))
            total_len - @sizeOf(VirtioNetHdr)
        else
            0;

        if (pkt_len > 0 and pkt_len <= 1514) {
            // Pass to network stack
            const net = @import("../net/mod.zig");
            const pkt_ptr: [*]const u8 = @ptrFromInt(data_virt);
            net.handleRxPacket(pkt_ptr, pkt_len);
        }

        // Recycle: re-submit the same descriptors back to the RX queue
        // (buffer pages are reused, no alloc/free needed)
        const avail = vqGetAvail(vq);
        const avail_idx = avail.idx;
        avail.ring[avail_idx % QUEUE_SIZE] = @intCast(elem.id);
        asm volatile ("" ::: .{ .memory = true });
        avail.idx = avail_idx + 1;

        vq.last_used_idx +%= 1;
    }

    // Notify device of new RX buffers
    if (used.idx != vq.last_used_idx) {
        io.outw(@intCast(device.io_base + VIRTIO_PCI_QUEUE_NOTIFY), 0);
    }
    // Always notify after recycling
    io.outw(@intCast(device.io_base + VIRTIO_PCI_QUEUE_NOTIFY), 0);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
