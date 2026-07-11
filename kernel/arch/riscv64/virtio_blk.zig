//! Minimal virtio-mmio block driver for QEMU virt (Milestone 7).
//!
//! Probes the 8 virtio-mmio slots (0x10001000..0x10008000), sets up one
//! virtqueue for the first virtio-blk device (DeviceID 2), and reads sector 0
//! by polling the used ring. Supports both legacy (version 1, QueuePFN) and
//! modern (version 2, QueueReady) MMIO layouts.

const pmm = @import("pmm.zig");
const uart = @import("uart.zig");

/// Queue memory in BSS: identity-mapped kernel image, so VA == PA and the
/// two queue pages are physically contiguous (legacy layout requirement).
var queue_mem: [2 * 4096]u8 align(4096) = undefined;
var req_mem: [4096]u8 align(4096) = undefined;

const MMIO_BASE: usize = 0x10001000;
const MMIO_SLOTS: usize = 8;
const MMIO_STRIDE: usize = 0x1000;

const MAGIC: u32 = 0x74726976; // "virt"
const DEVICE_BLK: u32 = 2;

// Register offsets
const REG_MAGIC: usize = 0x000;
const REG_VERSION: usize = 0x004;
const REG_DEVICE_ID: usize = 0x008;
const REG_DEV_FEATURES: usize = 0x010;
const REG_DRV_FEATURES: usize = 0x020;
const REG_GUEST_PAGE_SIZE: usize = 0x028; // legacy
const REG_QUEUE_SEL: usize = 0x030;
const REG_QUEUE_NUM_MAX: usize = 0x034;
const REG_QUEUE_NUM: usize = 0x038;
const REG_QUEUE_ALIGN: usize = 0x03c; // legacy
const REG_QUEUE_PFN: usize = 0x040; // legacy
const REG_QUEUE_READY: usize = 0x044; // modern
const REG_QUEUE_NOTIFY: usize = 0x050;
const REG_INT_STATUS: usize = 0x060;
const REG_INT_ACK: usize = 0x064;
const REG_STATUS: usize = 0x070;
const REG_QUEUE_DESC_LO: usize = 0x080; // modern
const REG_QUEUE_DESC_HI: usize = 0x084;
const REG_QUEUE_DRV_LO: usize = 0x090;
const REG_QUEUE_DRV_HI: usize = 0x094;
const REG_QUEUE_DEV_LO: usize = 0x0a0;
const REG_QUEUE_DEV_HI: usize = 0x0a4;
const REG_CONFIG: usize = 0x100;

const STATUS_ACK: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

const QUEUE_SIZE: u16 = 8;
pub const SECTOR_SIZE: usize = 512;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const DESC_F_NEXT: u16 = 1;
const DESC_F_WRITE: u16 = 2;

const BLK_T_IN: u32 = 0; // read

var base: usize = 0;
var version: u32 = 0;
var queue_page: usize = 0; // desc+avail
var used_page: usize = 0; // used ring (own page keeps legacy alignment simple)
var req_page: usize = 0; // request header + data + status
var capacity_sectors: u64 = 0;

fn reg32(offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

fn putStr(s: []const u8) void {
    uart.writeString(s);
}

fn putDec(v: u64) void {
    if (v == 0) {
        uart.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (n += 1) {
        buf[n] = @intCast('0' + (x % 10));
        x /= 10;
    }
    while (n > 0) {
        n -= 1;
        uart.writeByte(buf[n]);
    }
}

/// Find the first virtio-blk device. Returns its MMIO base or null.
pub fn probe() ?usize {
    var slot: usize = 0;
    while (slot < MMIO_SLOTS) : (slot += 1) {
        const b = MMIO_BASE + slot * MMIO_STRIDE;
        const magic: *volatile u32 = @ptrFromInt(b + REG_MAGIC);
        if (magic.* != MAGIC) continue;
        const dev: *volatile u32 = @ptrFromInt(b + REG_DEVICE_ID);
        if (dev.* == DEVICE_BLK) return b;
    }
    return null;
}

fn descTable() [*]volatile VirtqDesc {
    return @ptrFromInt(queue_page);
}

fn availRing() [*]volatile u16 {
    // avail: flags u16, idx u16, ring[n] u16 — right after 8 descriptors.
    return @ptrFromInt(queue_page + @as(usize, QUEUE_SIZE) * @sizeOf(VirtqDesc));
}

fn usedIdxPtr() *volatile u16 {
    // used: flags u16, idx u16, ring[n]{id u32, len u32}
    return @ptrFromInt(used_page + 2);
}

/// Initialise the device + one virtqueue. Returns false on failure.
pub fn init(mmio_base: usize) bool {
    base = mmio_base;
    version = reg32(REG_VERSION).*;

    reg32(REG_STATUS).* = 0; // reset
    reg32(REG_STATUS).* = STATUS_ACK;
    reg32(REG_STATUS).* = STATUS_ACK | STATUS_DRIVER;

    // Feature negotiation: accept none (polling, no fancy features).
    reg32(REG_DRV_FEATURES).* = 0;
    if (version >= 2) {
        reg32(REG_STATUS).* = STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK;
        if ((reg32(REG_STATUS).* & STATUS_FEATURES_OK) == 0) return false;
    }

    // Queue memory: two contiguous BSS pages (desc+avail | used) + request page.
    queue_page = @intFromPtr(&queue_mem);
    used_page = queue_page + pmm.PAGE_SIZE;
    req_page = @intFromPtr(&req_mem);
    @memset(queue_mem[0..], 0);
    @memset(req_mem[0..], 0);

    reg32(REG_QUEUE_SEL).* = 0;
    const num_max = reg32(REG_QUEUE_NUM_MAX).*;
    if (num_max == 0 or num_max < QUEUE_SIZE) return false;
    reg32(REG_QUEUE_NUM).* = QUEUE_SIZE;

    if (version == 1) {
        // Legacy: desc+avail in page 0, used ring page-aligned right after.
        if (used_page != queue_page + pmm.PAGE_SIZE) return false;
        reg32(REG_GUEST_PAGE_SIZE).* = @intCast(pmm.PAGE_SIZE);
        reg32(REG_QUEUE_ALIGN).* = @intCast(pmm.PAGE_SIZE);
        reg32(REG_QUEUE_PFN).* = @intCast(queue_page / pmm.PAGE_SIZE);
    } else {
        reg32(REG_QUEUE_DESC_LO).* = @truncate(queue_page);
        reg32(REG_QUEUE_DESC_HI).* = @truncate(@as(u64, queue_page) >> 32);
        const avail_addr = queue_page + @as(usize, QUEUE_SIZE) * @sizeOf(VirtqDesc);
        reg32(REG_QUEUE_DRV_LO).* = @truncate(avail_addr);
        reg32(REG_QUEUE_DRV_HI).* = @truncate(@as(u64, avail_addr) >> 32);
        reg32(REG_QUEUE_DEV_LO).* = @truncate(used_page);
        reg32(REG_QUEUE_DEV_HI).* = @truncate(@as(u64, used_page) >> 32);
        reg32(REG_QUEUE_READY).* = 1;
    }

    reg32(REG_STATUS).* = if (version >= 2)
        STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK
    else
        STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK;

    // Config space: capacity (u64 sectors) at offset 0.
    const cap_lo: *volatile u32 = @ptrFromInt(base + REG_CONFIG);
    const cap_hi: *volatile u32 = @ptrFromInt(base + REG_CONFIG + 4);
    capacity_sectors = (@as(u64, cap_hi.*) << 32) | cap_lo.*;
    return true;
}

pub fn capacity() u64 {
    return capacity_sectors;
}

/// Synchronous single-sector read into `out` (>= 512 bytes). Polls used ring.
pub fn readSector(sector: u64, out: []u8) bool {
    if (out.len < SECTOR_SIZE) return false;

    // Request layout in req_page:
    //   +0   header {type u32, reserved u32, sector u64}
    //   +16  data (512)
    //   +528 status (1)
    const hdr: *volatile extern struct { typ: u32, reserved: u32, sector: u64 } =
        @ptrFromInt(req_page);
    hdr.typ = BLK_T_IN;
    hdr.reserved = 0;
    hdr.sector = sector;
    const status: *volatile u8 = @ptrFromInt(req_page + 528);
    status.* = 0xff;

    const desc = descTable();
    desc[0] = .{ .addr = req_page, .len = 16, .flags = DESC_F_NEXT, .next = 1 };
    desc[1] = .{ .addr = req_page + 16, .len = SECTOR_SIZE, .flags = DESC_F_NEXT | DESC_F_WRITE, .next = 2 };
    desc[2] = .{ .addr = req_page + 528, .len = 1, .flags = DESC_F_WRITE, .next = 0 };

    const avail = availRing();
    const used_before = usedIdxPtr().*;
    const slot = avail[1] % QUEUE_SIZE; // avail.idx
    avail[2 + slot] = 0; // ring[slot] = head desc 0
    asm volatile ("fence w, w" ::: .{ .memory = true });
    avail[1] +%= 1;
    asm volatile ("fence w, w" ::: .{ .memory = true });

    reg32(REG_QUEUE_NOTIFY).* = 0;

    // Poll until used.idx advances (bounded spin).
    var spins: u64 = 0;
    while (usedIdxPtr().* == used_before) {
        spins += 1;
        if (spins > 100_000_000) return false;
        asm volatile ("fence r, r" ::: .{ .memory = true });
    }
    reg32(REG_INT_ACK).* = reg32(REG_INT_STATUS).*;

    if (status.* != 0) return false;
    const data: [*]const u8 = @ptrFromInt(req_page + 16);
    @memcpy(out[0..SECTOR_SIZE], data[0..SECTOR_SIZE]);
    return true;
}

/// M7 self-test: probe, init, read sector 0, verify magic prefix.
pub fn selfTest() bool {
    putStr("MoQiOS riscv64: M7 (virtio-mmio blk)\n");

    const b = probe() orelse {
        putStr("  no virtio-blk device (disk not attached?)\n");
        return false;
    };
    putStr("  virtio-blk found, version=");
    putDec(reg32Version(b));
    putStr("\n");

    if (!init(b)) {
        putStr("  M7 FAILED: init\n");
        return false;
    }
    putStr("  queue ready, capacity=");
    putDec(capacity_sectors);
    putStr(" sectors\n");

    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(0, &buf)) {
        putStr("  M7 FAILED: read sector 0\n");
        return false;
    }

    const want = "MOQI_RV64_DISK";
    if (!memEqlPrefix(&buf, want)) {
        putStr("  M7 FAILED: bad disk magic\n");
        return false;
    }
    putStr("  disk magic: OK\n");
    putStr("[riscv64] M7 complete\n");
    return true;
}

fn reg32Version(b: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(b + REG_VERSION);
    return p.*;
}

fn memEqlPrefix(buf: []const u8, prefix: []const u8) bool {
    if (buf.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (buf[i] != c) return false;
    }
    return true;
}
