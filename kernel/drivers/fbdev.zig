/// /dev/fb0 mmap integration.
///
/// The Limine framebuffer lives in normal RAM, so userdrv's dev_map_mmio
/// cannot map it (it rejects anything pmm.isRamPhys reports as RAM). This
/// helper is the fb's own mapping path, invoked from mm/mmap.zig when an
/// mmap() targets the /dev/fb0 devfs fd: the fb's physical frames are
/// mapped SHARED and writable into the caller's address space eagerly, each
/// frame is addRef-pinned, and the region is tracked as a no_free region
/// (mmap.zig trackNoFreeRegion) so munmap/exit unmap the pages but never
/// return the frames to the PMM. The addRef is deliberately never released:
/// it is a permanent pin on device memory, keeping PMM accounting balanced
/// (unmap neither frees nor decRefs) while guaranteeing the frames can
/// never re-enter the free pool even if another subsystem mistakes them
/// for ordinary RAM.
const builtin = @import("builtin");
const fb = @import("framebuffer.zig");
const task_mod = @import("../proc/task.zig");
const mmap_mod = @import("../mm/mmap.zig");
const pmm = @import("../mm/pmm.zig");
const paging = @import("../arch/arch.zig").paging;

const MAP_SHARED: u64 = 0x1;

/// Map the framebuffer into `task` for an mmap() on a /dev/fb0 fd.
/// Returns the mapped base address or a negative errno.
pub fn mmapFb(task: *task_mod.Task, length: u64, prot: u64, flags: u64, offset: u64) i64 {
    if (comptime builtin.cpu.arch != .x86_64) return -19; // ENODEV
    if (!fb.isInitialized()) return -19; // ENODEV — no Limine framebuffer
    // A private mapping of a framebuffer is meaningless: writes must reach
    // the screen. Require MAP_SHARED like Linux fb_mmap effectively does.
    if (flags & MAP_SHARED == 0) return -22; // EINVAL
    if (offset % 4096 != 0) return -22; // EINVAL
    const fb_size = fb.getSize();
    if (offset >= fb_size) return -22; // EINVAL
    if (length == 0 or length > fb_size - offset) return -22; // EINVAL

    const phys_base = fb.getPhysBase();
    if (phys_base % 4096 != 0) return -19; // ENODEV — unaligned fb, cannot map

    // Userspace now owns the screen: stop the text console mirror or its
    // periodic present() would clobber the mapping owner's pixels.
    if (comptime builtin.cpu.arch == .x86_64) {
        const fbcon = @import("fbcon.zig");
        if (fbcon.fbcon_enable) {
            const serial = @import("../arch/arch.zig").serial;
            serial.writeString("[fbcon] mirror disabled (fb0 mapped by userspace)\n");
            fbcon.fbcon_enable = false;
        }
    }

    const pages = (length + 4095) / 4096;
    const base = mmap_mod.findFreeRangePub(task, pages) orelse return -12; // ENOMEM
    if (!mmap_mod.canTrackRegionPub(task, base, pages)) return -12; // ENOMEM

    const map_flags = paging.MapFlags{
        .writable = (prot & 2) != 0,
        .user = true,
        .no_execute = true,
        .global = false,
        .write_through = true, // writes must reach the screen promptly
    };
    var mapped: u64 = 0;
    while (mapped < pages) : (mapped += 1) {
        const phys = phys_base + offset + mapped * 4096;
        paging.mapPage(task.page_table_phys, base + mapped * 4096, phys, map_flags) catch {
            unmapPinned(task.page_table_phys, base, mapped);
            return -12; // ENOMEM
        };
        // Pin AFTER the map succeeds; balanced by the no_free region below
        // (unmap never decRefs — a permanent device-memory pin).
        pmm.addRef(phys);
    }
    if (!mmap_mod.trackNoFreeRegion(task, base, pages)) {
        unmapPinned(task.page_table_phys, base, mapped);
        return -12; // ENOMEM
    }
    return @bitCast(base);
}

/// Unmap without decRef/free: the frames belong to the device.
fn unmapPinned(pml4: u64, base: u64, pages: u64) void {
    for (0..pages) |i| {
        _ = paging.unmapPage(pml4, base + i * 4096);
    }
}
