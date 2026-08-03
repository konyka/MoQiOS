/// Block device unified abstraction layer.
///
/// Provides a single interface for all block devices (NVMe/AHCI/virtio-blk).
/// Drivers register themselves after init; the dispatch functions route
/// read/write/flush/discard calls to the appropriate driver based on device type.
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const klog = @import("../klog.zig");
const serial = @import("../arch/arch.zig").serial;
const virtio_blk = @import("virtio_blk.zig");
const ahci = @import("ahci.zig");
const nvme = @import("nvme.zig");

pub const BlockDevType = enum(u8) {
    nvme,
    ahci,
    virtio_blk,
};

pub const BlockDevInfo = struct {
    dev_type: BlockDevType,
    sector_size: u32, // 通常 512
    total_sectors: u64,
    name: [16]u8,
    name_len: u8,
    supports_flush: bool,
    max_transfer_sectors: u32, // 单次最大扇区数
};

pub const BlockDevice = struct {
    active: bool,
    info: BlockDevInfo,
    // 设备在各自驱动中的索引
    dev_idx: u8,
};

// IO 请求队列
pub const IoRequest = struct {
    dev_idx: u8,
    is_write: bool,
    lba: u64,
    sector_count: u32,
    buffer: [*]u8,
    completed: bool,
    result: i32, // 0=成功, 负数=错误
};

const MAX_DEVICES = 8;
const MAX_REQUESTS = 32;

var devices: [MAX_DEVICES]BlockDevice = @splat(.{
    .active = false,
    .info = .{
        .dev_type = .nvme,
        .sector_size = 0,
        .total_sectors = 0,
        .name = @splat(0),
        .name_len = 0,
        .supports_flush = false,
        .max_transfer_sectors = 0,
    },
    .dev_idx = 0,
});
var device_count: u8 = 0;
var blk_lock: IrqSpinlock = .{};

// 请求队列 (FIFO)
var request_queue: [MAX_REQUESTS]IoRequest = @splat(.{
    .dev_idx = 0,
    .is_write = false,
    .lba = 0,
    .sector_count = 0,
    .buffer = undefined,
    .completed = false,
    .result = 0,
});
var queue_head: u32 = 0;
var queue_tail: u32 = 0;

/// 注册新块设备，返回全局设备索引 (0..MAX_DEVICES-1)，满则返回 0xFF
pub fn registerDevice(info: BlockDevInfo, dev_idx: u8) u8 {
    const flags = blk_lock.acquire();
    defer blk_lock.release(flags);

    if (device_count >= MAX_DEVICES) {
        serial.writeString("[block_dev] Device table full, cannot register\n");
        return 0xFF;
    }

    const idx = device_count;
    devices[idx] = .{
        .active = true,
        .info = info,
        .dev_idx = dev_idx,
    };
    device_count += 1;

    // 打印注册信息
    serial.writeString("[block_dev] Registered device #");
    var buf: [8]u8 = undefined;
    serial.writeString(formatUint(&buf, idx));
    serial.writeString(" type=");
    serial.writeString(@tagName(info.dev_type));
    serial.writeString(" sectors=");
    serial.writeString(formatUint(&buf, info.total_sectors));
    serial.writeString("\n");

    return idx;
}

/// 通过全局设备索引读取扇区
/// 返回 0 成功, 负数错误
pub fn readSectors(dev: u8, lba: u64, count: u32, buf: [*]u8) i32 {
    if (dev >= device_count or !devices[dev].active) return -1;

    const info = devices[dev].info;
    const driver_idx = devices[dev].dev_idx;

    switch (info.dev_type) {
        .nvme => {
            const result = nvme.readSectors(lba, count, buf);
            if (result < 0) return -1;
            return 0;
        },
        .virtio_blk => {
            const result = virtio_blk.readSectorsDisk(driver_idx, lba, count, buf);
            if (result < 0) return -1;
            return 0;
        },
        .ahci => {
            // AHCI 当前只支持第一个活动端口，后续可扩展 per-port dispatch
            const result = ahci.readSectors(lba, count, buf);
            if (result < 0) return -1;
            return 0;
        },
    }
}

/// 通过全局设备索引写入扇区
/// 返回 0 成功, 负数错误
pub fn writeSectors(dev: u8, lba: u64, count: u32, buf: [*]const u8) i32 {
    if (dev >= device_count or !devices[dev].active) return -1;

    const info = devices[dev].info;

    switch (info.dev_type) {
        .nvme => {
            const result = nvme.writeSectors(lba, count, buf);
            if (result < 0) return -1;
            return 0;
        },
        .virtio_blk => {
            // virtio_blk.writeSectors 不支持 disk_id 选择，默认用 device 0
            const result = virtio_blk.writeSectors(lba, count, buf);
            if (result < 0) return -1;
            return 0;
        },
        .ahci => {
            const result = ahci.writeSectors(lba, count, buf);
            if (result < 0) return -1;
            return 0;
        },
    }
}

/// 设备是否声明了可下发的 flush 屏障。
/// 不支持屏障的设备按写透处理：回写完成即为可达的最强持久化保证。
pub fn supportsFlush(dev: u8) bool {
    if (dev >= device_count or !devices[dev].active) return false;
    return devices[dev].info.supports_flush;
}

/// 分发 flush 命令
pub fn flush(dev: u8) i32 {
    if (dev >= device_count or !devices[dev].active) return -1;
    if (!devices[dev].info.supports_flush) return -1;

    switch (devices[dev].info.dev_type) {
        .ahci => {
            return ahci.flushCache();
        },
        .nvme, .virtio_blk => return -1,
    }
}

/// 分发 TRIM 命令 (DATA SET MANAGEMENT)
/// lba_ranges: 每8字节表示一个范围，低2字节=扇区数(0=65536)，高6字节=起始LBA
/// 返回 0 成功, 负数错误
pub fn trim(dev: u8, lba_ranges: []const u64, range_count: u32) i32 {
    if (dev >= device_count or !devices[dev].active) return -1;

    switch (devices[dev].info.dev_type) {
        .ahci => {
            if (!ahci.isTrimSupported()) return -1;
            return ahci.trim(lba_ranges, range_count);
        },
        .nvme, .virtio_blk => {
            return -1;
        },
    }
}

/// Discard (deallocate) `count` sectors starting at `lba` on the active
/// device — the disk the filesystems actually sit on (virtio-blk disk 0 is
/// the only disk fat32/ext2 address directly today; when no virtio-blk
/// device is registered, falls back to the first active device so the
/// NVMe/AHCI paths stay reachable). No-op (returns 0) when the target
/// driver lacks discard/TRIM support; -1 on I/O error.
pub fn discard(lba: u64, count: u32) i32 {
    if (count == 0) return 0;

    var target: ?u8 = null;
    for (0..device_count) |i| {
        if (!devices[i].active) continue;
        if (devices[i].info.dev_type == .virtio_blk and devices[i].dev_idx == 0) {
            target = @intCast(i);
            break;
        }
        if (target == null) target = @intCast(i);
    }
    const dev = target orelse return 0;

    switch (devices[dev].info.dev_type) {
        .virtio_blk => return virtio_blk.discard(lba, count),
        .nvme => {
            if (!nvme.isTrimSupported()) return 0;
            return nvme.trimSectors(lba, count);
        },
        .ahci => {
            if (!ahci.isTrimSupported()) return 0;
            // AHCI TRIM range entry: low 2 bytes = sector count (0 = 65536),
            // high 6 bytes = starting LBA. Split counts above 65535.
            var cur = lba;
            var remaining = count;
            while (remaining > 0) {
                const chunk: u32 = @min(remaining, 65535);
                const entry: u64 = (cur << 16) | chunk;
                if (ahci.trim(&.{entry}, 1) != 0) return -1;
                cur += chunk;
                remaining -= chunk;
            }
            return 0;
        },
    }
}

pub fn getDeviceInfo(dev: u8) ?BlockDevInfo {
    if (dev >= device_count) return null;
    if (!devices[dev].active) return null;
    return devices[dev].info;
}

pub fn getDeviceCount() u8 {
    return device_count;
}

/// 提交异步 IO 请求到 FIFO 队列
/// 返回 true 成功入队, false 队列满
pub fn submitRequest(req: IoRequest) bool {
    const flags = blk_lock.acquire();
    defer blk_lock.release(flags);

    if ((queue_tail + 1) % MAX_REQUESTS == queue_head) {
        return false; // 队列满
    }

    request_queue[queue_tail] = req;
    queue_tail = (queue_tail + 1) % MAX_REQUESTS;
    return true;
}

/// 处理队列中下一个请求
pub fn processNextRequest() ?IoRequest {
    const flags = blk_lock.acquire();
    defer blk_lock.release(flags);

    if (queue_head == queue_tail) return null;

    const req = request_queue[queue_head];
    queue_head = (queue_head + 1) % MAX_REQUESTS;
    return req;
}

// ---- helpers ----

/// 格式化无符号整数为十进制字符串
fn formatUint(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0 and i < buf.len) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    // Reverse
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}
