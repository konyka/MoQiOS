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
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

const MAP_SHARED: u64 = 0x1;

// ── fb0 mapping registry (fbcon mirror restore) ──────────────────────
// Every successful mmapFb registers its [base, pages) range here. munmap
// (noteUnmap, wired into mmap.zig) clips ranges, task exit/exec
// (cleanupTask, wired next to devfs_proxy.cleanupTask) drops them; when
// the last mapping goes away the text console mirror is re-enabled.
const MAX_FB_MAPS: usize = 8;

const FbMap = struct {
    active: bool = false,
    owner: ?*task_mod.Task = null,
    base: u64 = 0,
    pages: u64 = 0,
};

var fb_maps: [MAX_FB_MAPS]FbMap = @splat(.{});
var fb_maps_lock: IrqSpinlock = .{};
var fb_map_count: u32 = 0;

/// Re-enable the mirror once no userspace fb mapping remains. Caller holds
/// fb_maps_lock.
fn maybeRestoreMirrorLocked() void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    if (fb_map_count != 0) return;
    const fbcon = @import("fbcon.zig");
    if (fbcon.fbcon_enable or !fbcon.isActive()) return;
    fbcon.fbcon_enable = true;
    const serial = @import("../arch/arch.zig").serial;
    serial.writeString("[fbcon] mirror restored (no fb0 mappings left)\n");
}

/// Register a fresh fb mapping and silence the mirror. Caller holds no
/// locks; a full registry degrades to the old one-way behavior (mirror
/// stays off) without failing the mapping.
fn registerMapping(task: *task_mod.Task, base: u64, pages: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const flags = fb_maps_lock.acquire();
    defer fb_maps_lock.release(flags);
    for (&fb_maps) |*m| {
        if (m.active) continue;
        m.* = .{ .active = true, .owner = task, .base = base, .pages = pages };
        fb_map_count += 1;
        break;
    }
    // Userspace now owns the screen: stop the text console mirror or its
    // periodic present() would clobber the mapping owner's pixels.
    const fbcon = @import("fbcon.zig");
    if (fbcon.fbcon_enable) {
        const serial = @import("../arch/arch.zig").serial;
        serial.writeString("[fbcon] mirror disabled (fb0 mapped by userspace)\n");
        fbcon.fbcon_enable = false;
    }
}

/// munmap/mremap-shrink hook: clip every registered range of `task` that
/// overlaps [base, base + num_pages*4096). A middle cut splits the entry
/// into a second slot when one is free, otherwise keeps the larger half.
pub fn noteUnmap(task: *task_mod.Task, base: u64, num_pages: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const PAGE: u64 = 4096;
    const u_end = base + num_pages * PAGE;
    const flags = fb_maps_lock.acquire();
    defer fb_maps_lock.release(flags);
    for (&fb_maps) |*m| {
        if (!m.active or m.owner != task) continue;
        const m_end = m.base + m.pages * PAGE;
        if (m.base >= u_end or m_end <= base) continue;

        const left_pages = if (base > m.base) (base - m.base) / PAGE else 0;
        const right_base = @min(u_end, m_end);
        const right_pages = (m_end - right_base) / PAGE;

        if (left_pages > 0 and right_pages > 0) {
            // Middle cut: try to represent both halves.
            var slot: ?*FbMap = null;
            for (&fb_maps) |*s| {
                if (!s.active) {
                    slot = s;
                    break;
                }
            }
            if (slot) |s| {
                s.* = .{ .active = true, .owner = task, .base = right_base, .pages = right_pages };
                fb_map_count += 1;
                m.pages = left_pages;
            } else if (left_pages >= right_pages) {
                m.pages = left_pages; // degraded: right half untracked
            } else {
                m.base = right_base;
                m.pages = right_pages;
            }
        } else if (left_pages > 0) {
            m.pages = left_pages;
        } else if (right_pages > 0) {
            m.base = right_base;
            m.pages = right_pages;
        } else {
            m.active = false;
            m.owner = null;
            fb_map_count -= 1;
        }
    }
    maybeRestoreMirrorLocked();
}

/// exit/exec hook: drop all fb mappings owned by `task`.
pub fn cleanupTask(task: *task_mod.Task) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const flags = fb_maps_lock.acquire();
    defer fb_maps_lock.release(flags);
    for (&fb_maps) |*m| {
        if (m.active and m.owner == task) {
            m.active = false;
            m.owner = null;
            fb_map_count -= 1;
        }
    }
    maybeRestoreMirrorLocked();
}

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
    // Only now that the mapping is fully established: register it and silence
    // the console mirror. Registering on success (not on entry) keeps the
    // mirror running when the mmap itself fails.
    registerMapping(task, base, pages);
    return @bitCast(base);
}

/// Unmap without decRef/free: the frames belong to the device.
fn unmapPinned(pml4: u64, base: u64, pages: u64) void {
    for (0..pages) |i| {
        _ = paging.unmapPage(pml4, base + i * 4096);
    }
}
