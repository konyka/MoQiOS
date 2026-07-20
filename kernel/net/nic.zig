//! Active-NIC transmit facade.
//!
//! The protocol stack (arp/ipv4/ipv6/icmp/tcp/udp/netif) used to hardcode
//! `drivers/e1000.zig` for every transmit, so a machine with only a
//! virtio-net NIC could initialise the stack but never send a frame. This
//! facade dispatches TX / MAC / liveness to whichever NIC is active,
//! preferring e1000 when both are present. RX stays driver-specific: e1000
//! is polled via `receivePacket` (raw_net/socket_syscall) while virtio-net
//! pushes frames straight into `net.handleRxPacket` from its own path.

const builtin = @import("builtin");

/// The concrete NIC drivers only exist on x86 (they reach through
/// `drivers/pci.zig` → ACPI → port I/O, none of which is portable yet).
/// Importing them behind a comptime arch gate keeps this facade — and the
/// whole `net/*` tree that now routes through it — compilable on non-x86,
/// where every TX/RX call is a no-op until an arch-clean NIC driver lands.
const drivers = if (builtin.cpu.arch == .x86_64) struct {
    const e1000 = @import("../drivers/e1000.zig");
    const virtio_net = @import("../drivers/virtio_net.zig");
} else struct {};

/// True when any NIC can carry traffic.
pub fn isActive() bool {
    if (comptime builtin.cpu.arch == .x86_64) {
        return drivers.e1000.isActive() or drivers.virtio_net.isActive();
    }
    return false;
}

/// MAC of the active NIC (e1000 preferred). Zero when no NIC is up.
pub fn getMAC() [6]u8 {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (drivers.e1000.isActive()) return drivers.e1000.getMAC();
        if (drivers.virtio_net.isActive()) return drivers.virtio_net.getMAC();
    }
    return .{ 0, 0, 0, 0, 0, 0 };
}

/// Transmit one L2 frame on the active NIC. Returns false when no NIC
/// accepted it (none active, or the driver rejected the length).
pub fn sendPacket(data: [*]const u8, len: u32) bool {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (drivers.e1000.isActive()) return drivers.e1000.sendPacket(data, len);
        if (drivers.virtio_net.isActive()) return drivers.virtio_net.sendPacket(data, len);
    }
    return false;
}

/// Poll one frame off the active NIC's RX ring into `buf`; returns bytes
/// copied (0 = nothing ready). Only e1000 is pollable — virtio-net has no
/// poll API and pushes RX straight into `net.handleRxPacket` from its own
/// path, so a virtio-net-only machine still receives, it just returns 0
/// here and callers rely on the driver's push path instead.
pub fn receivePacket(buf: [*]u8, max_len: u32) u32 {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (drivers.e1000.isActive()) return drivers.e1000.receivePacket(buf, max_len);
    }
    return 0;
}
