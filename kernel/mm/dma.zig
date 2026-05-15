/// DMA buffer management — stubs for Phase 2 (PCI/driver infrastructure).
/// Full implementation requires PCI enumeration + IOMMU support.

const pmm = @import("pmm.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog.zig");

pub const DmaBuffer = struct {
    virt_addr: u64,
    phys_addr: u64,
    size: usize,
};

/// Allocate a DMA-coherent buffer (physically contiguous).
pub fn allocCoherent(size: usize) ?DmaBuffer {
    const pages = (size + 4095) / 4096;
    if (pages > 1) {
        serial.writeString("[dma] allocCoherent: multi-page not supported yet\n");
        return null;
    }
    const phys = pmm.allocPage() orelse return null;
    const virt = hhdm.physToVirt(phys);
    return .{
        .virt_addr = virt,
        .phys_addr = phys,
        .size = pages * 4096,
    };
}

/// Free a DMA-coherent buffer.
pub fn freeCoherent(buf: DmaBuffer) void {
    pmm.freePage(buf.phys_addr);
}

/// Map a single physical page for DMA access (stub).
pub fn mapSingle(phys: u64) ?u64 {
    _ = phys;
    serial.writeString("[dma] mapSingle: not yet implemented\n");
    return null;
}

pub fn init() void {
    klog.log(.info, "DMA manager initialized (stubs)");
}
