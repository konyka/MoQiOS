//! Active-NIC transmit facade.
//!
//! The protocol stack (arp/ipv4/ipv6/icmp/tcp/udp/netif) used to hardcode
//! `drivers/e1000.zig` for every transmit, so a machine with only a
//! virtio-net NIC could initialise the stack but never send a frame. This
//! facade dispatches TX / MAC / liveness to whichever NIC is active,
//! preferring e1000 when both are present. RX stays driver-specific: e1000
//! is polled via `receivePacket` (raw_net/socket_syscall) while virtio-net
//! pushes frames straight into `net.handleRxPacket` from its own path.

const e1000 = @import("../drivers/e1000.zig");
const virtio_net = @import("../drivers/virtio_net.zig");

/// True when any NIC can carry traffic.
pub fn isActive() bool {
    return e1000.isActive() or virtio_net.isActive();
}

/// MAC of the active NIC (e1000 preferred). Zero when no NIC is up.
pub fn getMAC() [6]u8 {
    if (e1000.isActive()) return e1000.getMAC();
    if (virtio_net.isActive()) return virtio_net.getMAC();
    return .{ 0, 0, 0, 0, 0, 0 };
}

/// Transmit one L2 frame on the active NIC. Returns false when no NIC
/// accepted it (none active, or the driver rejected the length).
pub fn sendPacket(data: [*]const u8, len: u32) bool {
    if (e1000.isActive()) return e1000.sendPacket(data, len);
    if (virtio_net.isActive()) return virtio_net.sendPacket(data, len);
    return false;
}
