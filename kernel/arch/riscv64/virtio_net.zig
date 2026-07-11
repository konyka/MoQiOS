//! Minimal virtio-mmio net probe for QEMU virt (M7 extension).
//!
//! Finds the first virtio-net device (DeviceID 1), negotiates VIRTIO_NET_F_MAC,
//! and prints the MAC from config space. No TX/RX queues yet — that waits on
//! shared-kernel net stack reuse.

const uart = @import("uart.zig");

const MMIO_BASE: usize = 0x10001000;
const MMIO_SLOTS: usize = 8;
const MMIO_STRIDE: usize = 0x1000;

const MAGIC: u32 = 0x74726976;
const DEVICE_NET: u32 = 1;

const REG_MAGIC: usize = 0x000;
const REG_VERSION: usize = 0x004;
const REG_DEVICE_ID: usize = 0x008;
const REG_DEV_FEATURES: usize = 0x010;
const REG_DRV_FEATURES: usize = 0x020;
const REG_STATUS: usize = 0x070;
const REG_CONFIG: usize = 0x100;

const STATUS_ACK: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

const VIRTIO_NET_F_MAC: u32 = 1 << 5;

fn putStr(s: []const u8) void {
    uart.writeString(s);
}

fn putHexByte(b: u8) void {
    const hex = "0123456789abcdef";
    uart.writeByte(hex[b >> 4]);
    uart.writeByte(hex[b & 0xf]);
}

fn reg32(base: usize, offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

fn reg8(base: usize, offset: usize) *volatile u8 {
    return @ptrFromInt(base + offset);
}

fn probe() ?usize {
    var slot: usize = 0;
    while (slot < MMIO_SLOTS) : (slot += 1) {
        const b = MMIO_BASE + slot * MMIO_STRIDE;
        if (reg32(b, REG_MAGIC).* != MAGIC) continue;
        if (reg32(b, REG_DEVICE_ID).* == DEVICE_NET) return b;
    }
    return null;
}

/// Negotiate features and read MAC. Returns false if no device / no MAC.
pub fn selfTest() bool {
    putStr("MoQiOS riscv64: M7-net (virtio-mmio net)\n");

    const b = probe() orelse {
        putStr("  no virtio-net device (nic not attached?)\n");
        return false;
    };
    const version = reg32(b, REG_VERSION).*;
    putStr("  virtio-net found, version=");
    uart.writeByte('0' + @as(u8, @truncate(version)));
    putStr("\n");

    reg32(b, REG_STATUS).* = 0;
    reg32(b, REG_STATUS).* = STATUS_ACK;
    reg32(b, REG_STATUS).* = STATUS_ACK | STATUS_DRIVER;

    const dev_feat = reg32(b, REG_DEV_FEATURES).*;
    if ((dev_feat & VIRTIO_NET_F_MAC) == 0) {
        putStr("  M7-net FAILED: no MAC feature\n");
        return false;
    }
    reg32(b, REG_DRV_FEATURES).* = VIRTIO_NET_F_MAC;
    if (version >= 2) {
        reg32(b, REG_STATUS).* = STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK;
        if ((reg32(b, REG_STATUS).* & STATUS_FEATURES_OK) == 0) {
            putStr("  M7-net FAILED: FEATURES_OK\n");
            return false;
        }
        reg32(b, REG_STATUS).* = STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK;
    } else {
        reg32(b, REG_STATUS).* = STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK;
    }

    putStr("  mac=");
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        if (i != 0) uart.writeByte(':');
        putHexByte(reg8(b, REG_CONFIG + i).*);
    }
    putStr("\n");
    putStr("  virtio-net MAC: OK\n");
    putStr("[riscv64] M7-net complete\n");
    return true;
}
