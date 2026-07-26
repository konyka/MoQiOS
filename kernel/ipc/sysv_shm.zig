/// SysV Shared Memory (shmget/shmat/shmdt/shmctl) implementation.
///
/// Provides POSIX-compatible shared memory segments for IPC.
/// Used by databases (PostgreSQL), X11, and other applications.
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/arch.zig").paging;
const serial = @import("../arch/arch.zig").serial;
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");

const PAGE_SIZE: u64 = 4096;
const MAX_SEGMENTS: u32 = 32;
const MAX_PAGES_PER_SEG: u32 = 256; // 1MB max per segment

/// SysV IPC permission structure
pub const IpcPerm = extern struct {
    key: i32,
    uid: u32,
    gid: u32,
    cuid: u32,
    cgid: u32,
    mode: u32,
    _pad: u32 = 0,
};

/// Shared memory segment descriptor (matches Linux shmid_ds layout)
pub const ShmSegment = struct {
    active: bool = false,
    perm: IpcPerm = .{ .key = 0, .uid = 0, .gid = 0, .cuid = 0, .cgid = 0, .mode = 0 },
    shmid: u32 = 0,
    size: u64 = 0,
    num_pages: u32 = 0,
    /// Physical page addresses (allocated from PMM)
    phys_pages: [MAX_PAGES_PER_SEG]u64 = @splat(0),
    /// Number of current attachments
    attach_count: u32 = 0,
    /// Owner task TID
    owner_tid: u32 = 0,
    /// Time of last attach/detach/change (seconds since boot, approximate)
    atime: u64 = 0,
    dtime: u64 = 0,
    ctime: u64 = 0,
    /// Marked for removal (IPC_RMID)
    marked_removed: bool = false,
};

var segments: [MAX_SEGMENTS]ShmSegment = @splat(.{});
var next_shmid: u32 = 1;
var shm_lock: IrqSpinlock = .{};
var next_free_hint: u64 = 0x7000_0000; // Track next candidate address for findFreeRegion

/// IPC flags
const IPC_CREAT: i32 = 0o1000;
const IPC_EXCL: i32 = 0o2000;
const IPC_RMID: i32 = 0;
const IPC_STAT: i32 = 2;
const IPC_SET: i32 = 1;
const IPC_PRIVATE: i32 = 0;

/// shmget(key, size, shmflg) -> shmid or -errno
pub fn shmget(key: i32, size: u64, shmflg: i32) i64 {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    // Search for existing segment with this key
    if (key != IPC_PRIVATE) {
        for (&segments) |*seg| {
            if (seg.active and seg.perm.key == key) {
                // Found existing segment
                if (shmflg & IPC_CREAT != 0 and shmflg & IPC_EXCL != 0) {
                    return -17; // -EEXIST
                }
                return @intCast(seg.shmid);
            }
        }
    }

    // Need to create a new segment
    if (shmflg & IPC_CREAT == 0 and key != IPC_PRIVATE) {
        return -2; // -ENOENT
    }

    if (size == 0 or size > MAX_PAGES_PER_SEG * PAGE_SIZE) {
        return -22; // -EINVAL
    }

    // Find a free slot
    var slot: ?u32 = null;
    for (0..MAX_SEGMENTS) |i| {
        if (!segments[i].active) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot == null) return -28; // -ENOSPC

    const idx = slot.?;
    const num_pages: u32 = @intCast((size + PAGE_SIZE - 1) / PAGE_SIZE);

    // Allocate physical pages
    var seg = &segments[idx];
    seg.num_pages = num_pages;
    for (0..num_pages) |p| {
        const phys = pmm.allocPage() orelse {
            // Rollback: free already allocated pages
            for (0..p) |q| {
                pmm.freePage(seg.phys_pages[q]);
                seg.phys_pages[q] = 0;
            }
            seg.num_pages = 0;
            return -12; // -ENOMEM
        };
        seg.phys_pages[p] = phys;
        // Zero the page
        const virt_addr = hhdm.physToVirt(phys);
        const ptr: [*]u8 = @ptrFromInt(virt_addr);
        @memset(ptr[0..PAGE_SIZE], 0);
    }

    const shmid = next_shmid;
    next_shmid += 1;

    seg.* = .{
        .active = true,
        .perm = .{
            .key = key,
            .uid = 0,
            .gid = 0,
            .cuid = 0,
            .cgid = 0,
            .mode = @intCast(shmflg & 0o777),
        },
        .shmid = shmid,
        .size = size,
        .num_pages = num_pages,
        .phys_pages = seg.phys_pages, // preserve allocated pages
        .attach_count = 0,
        .owner_tid = 0,
    };

    serial.writeString("[sysv_shm] created shmid=");
    fmt.writeDecimal(seg.shmid);
    serial.writeString(" key=");
    fmt.writeDecimal64(@intCast(seg.perm.key));
    serial.writeString(" pages=");
    fmt.writeDecimal(seg.num_pages);
    serial.writeString("\n");

    return @intCast(shmid);
}

/// shmat(shmid, shmaddr, shmflg) -> virtual address or -errno
/// Maps shared memory into the current process's address space.
pub fn shmat(shmid: u32, shmaddr: u64, shmflg: u64) i64 {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    // Find segment
    const seg = findSegment(shmid) orelse return -22; // -EINVAL

    if (seg.marked_removed) return -22; // -EINVAL

    // Get current process page table
    const sched = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1; // -EPERM
    const task = task_mod.getTask(cur_idx) orelse return -1;
    const pml4 = task.page_table_phys;
    if (pml4 == 0) return -1; // kernel thread can't attach

    // Determine mapping address
    const map_addr: u64 = if (shmaddr != 0) shmaddr else findFreeRegion(seg.num_pages, pml4);
    if (map_addr == 0) return -12; // -ENOMEM
    if (map_addr & (PAGE_SIZE - 1) != 0) return -22; // -EINVAL (not aligned)
    if (map_addr >= 0x0000_8000_0000_0000) return -22; // user space only

    // Map flags
    var map_flags: paging.MapFlags = .{ .writable = true, .user = true };
    if (shmflg & 0o10000 != 0) {
        // SHM_RDONLY
        map_flags.writable = false;
    }

    // Map each page
    for (0..seg.num_pages) |p| {
        const virt = map_addr + @as(u64, @intCast(p)) * PAGE_SIZE;
        paging.mapPage(pml4, virt, seg.phys_pages[p], map_flags) catch {
            // Rollback: unmap already mapped pages
            for (0..p) |q| {
                const rv = map_addr + @as(u64, @intCast(q)) * PAGE_SIZE;
                _ = paging.unmapPage(pml4, rv);
            }
            return -12; // -ENOMEM
        };
    }

    // Flush TLB for the mapped region
    for (0..seg.num_pages) |p| {
        const virt = map_addr + @as(u64, @intCast(p)) * PAGE_SIZE;
        paging.invlpg(virt);
    }

    seg.attach_count += 1;

    serial.writeString("[sysv_shm] shmat shmid=");
    fmt.writeDecimal(shmid);
    serial.writeString(" addr=0x");
    fmt.writeHex(map_addr);
    serial.writeString("\n");

    return @intCast(map_addr);
}

/// shmdt(shmaddr) -> 0 or -errno
/// Detaches shared memory from the current process.
pub fn shmdt(shmaddr: u64) i64 {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    if (shmaddr == 0 or shmaddr & (PAGE_SIZE - 1) != 0) return -22; // -EINVAL

    const sched = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const task = task_mod.getTask(cur_idx) orelse return -1;
    const pml4 = task.page_table_phys;
    if (pml4 == 0) return -1;

    // Find which segment is mapped at this address
    for (&segments) |*seg| {
        if (!seg.active) continue;
        if (isMappedAt(pml4, shmaddr, seg.phys_pages[0])) {
            // Unmap all pages
            for (0..seg.num_pages) |p| {
                const virt = shmaddr + @as(u64, @intCast(p)) * PAGE_SIZE;
                _ = paging.unmapPage(pml4, virt);
            }
            // Flush TLB
            for (0..seg.num_pages) |p| {
                const virt = shmaddr + @as(u64, @intCast(p)) * PAGE_SIZE;
                paging.invlpg(virt);
            }
            if (seg.attach_count > 0) seg.attach_count -= 1;

            serial.writeString("[sysv_shm] shmdt addr=0x");
            fmt.writeHex(shmaddr);
            serial.writeString(" shmid=");
            fmt.writeDecimal(seg.shmid);
            serial.writeString("\n");

            // If marked for removal and no more attachments, free it
            if (seg.marked_removed and seg.attach_count == 0) {
                freeSegment(seg);
            }
            return 0;
        }
    }

    return -22; // -EINVAL (not attached)
}

/// shmctl(shmid, cmd, buf) -> 0 or -errno
pub fn shmctl(shmid: u32, cmd: i32, buf: u64) i64 {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    const seg = findSegment(shmid) orelse return -22; // -EINVAL

    switch (cmd) {
        IPC_STAT => {
            // Copy segment info to user buffer
            if (buf == 0 or buf >= 0x0000_8000_0000_0000) return -14; // -EFAULT
            const copy = @import("../mm/copy_from_user.zig");
            // Write key, size, num_pages, attach_count as a simple struct
            var info: [6]u64 = .{
                @intCast(seg.perm.key),
                seg.size,
                @intCast(seg.num_pages),
                @intCast(seg.attach_count),
                @intCast(seg.shmid),
                if (seg.marked_removed) @as(u64, 1) else 0,
            };
            if (copy.copyToUser(@ptrFromInt(buf), @as([*]const u8, @ptrCast(&info))[0..@sizeOf([6]u64)], @sizeOf([6]u64)) != @sizeOf([6]u64)) return -14;
            return 0;
        },
        IPC_RMID => {
            seg.marked_removed = true;
            serial.writeString("[sysv_shm] marked shmid=");
            fmt.writeDecimal(shmid);
            serial.writeString(" for removal\n");
            // If no attachments, free immediately
            if (seg.attach_count == 0) {
                freeSegment(seg);
            }
            return 0;
        },
        IPC_SET => {
            // Update permission mode bits from buf (simplified: accept mode as u64)
            if (buf == 0 or buf >= 0x0000_8000_0000_0000) return -14; // -EFAULT
            const copy = @import("../mm/copy_from_user.zig");
            var mode_buf: [1]u64 = .{0};
            _ = copy.copyFromUser(@ptrCast(&mode_buf), @as([*]const u8, @ptrFromInt(buf)), @sizeOf(u64));
            seg.perm.mode = @intCast(mode_buf[0] & 0o777);
            return 0;
        },
        else => return -22, // -EINVAL
    }
}

// ── Internal helpers ──

fn findSegment(shmid: u32) ?*ShmSegment {
    for (&segments) |*seg| {
        if (seg.active and seg.shmid == shmid) return seg;
    }
    return null;
}

fn freeSegment(seg: *ShmSegment) void {
    for (0..seg.num_pages) |p| {
        if (seg.phys_pages[p] != 0) {
            pmm.freePage(seg.phys_pages[p]);
            seg.phys_pages[p] = 0;
        }
    }
    serial.writeString("[sysv_shm] freed shmid=");
    fmt.writeDecimal(seg.shmid);
    serial.writeString("\n");
    seg.* = .{};
    // Reset hint so future shmget can reuse lower addresses
    next_free_hint = 0x7000_0000;
}

fn isMappedAt(pml4: u64, virt: u64, first_phys: u64) bool {
    // Walk 4-level page table and verify that `virt` maps to `first_phys`
    const pml4_virt = hhdm.physToVirt(pml4);
    const pml4e: [*]u64 = @ptrFromInt(pml4_virt);
    const idx3 = (virt >> 39) & 0x1FF;
    if (pml4e[idx3] & 1 == 0) return false;

    const pdpt_phys = pml4e[idx3] & 0x000F_FFFF_FFFF_F000;
    const pdpt_virt = hhdm.physToVirt(pdpt_phys);
    const pdpte: [*]u64 = @ptrFromInt(pdpt_virt);
    const idx2 = (virt >> 30) & 0x1FF;
    if (pdpte[idx2] & 1 == 0) return false;
    if (pdpte[idx2] & 0x80 != 0) return false; // 1GB page — not a shm mapping

    const pd_phys = pdpte[idx2] & 0x000F_FFFF_FFFF_F000;
    const pd_virt = hhdm.physToVirt(pd_phys);
    const pde: [*]u64 = @ptrFromInt(pd_virt);
    const idx1 = (virt >> 21) & 0x1FF;
    if (pde[idx1] & 1 == 0) return false;
    if (pde[idx1] & 0x80 != 0) return false; // 2MB page — not a shm mapping

    const pt_phys = pde[idx1] & 0x000F_FFFF_FFFF_F000;
    const pt_virt = hhdm.physToVirt(pt_phys);
    const pte: [*]u64 = @ptrFromInt(pt_virt);
    const idx0 = (virt >> 12) & 0x1FF;
    if (pte[idx0] & 1 == 0) return false;
    const mapped_phys = pte[idx0] & 0x000F_FFFF_FFFF_F000;
    return mapped_phys == first_phys;
}

/// Find a free virtual region in user space for mapping.
/// Uses next_free_hint to avoid rescanning previously allocated regions (O(n) vs O(n²)).
fn findFreeRegion(num_pages: u32, pml4: u64) u64 {
    const SHM_END: u64 = 0x7800_0000; // 128MB region
    const region_size: u64 = @as(u64, num_pages) * PAGE_SIZE;

    var addr: u64 = next_free_hint;
    while (addr + region_size <= SHM_END) : (addr += PAGE_SIZE) {
        var all_free = true;
        for (0..num_pages) |p| {
            const test_addr = addr + @as(u64, @intCast(p)) * PAGE_SIZE;
            if (isPageMapped(pml4, test_addr)) {
                all_free = false;
                break;
            }
        }
        if (all_free) {
            next_free_hint = addr + region_size; // advance hint past this region
            return addr;
        }
    }
    // Wrap around: retry from SHM_BASE if we started past it
    if (next_free_hint > 0x7000_0000) {
        next_free_hint = 0x7000_0000;
        return findFreeRegion(num_pages, pml4);
    }
    return 0; // no free region
}

fn isPageMapped(pml4: u64, virt: u64) bool {
    // Walk 4-level page table to check if a virtual address is mapped
    const pml4_virt = hhdm.physToVirt(pml4);
    const pml4e: [*]u64 = @ptrFromInt(pml4_virt);
    const idx3 = (virt >> 39) & 0x1FF;
    if (pml4e[idx3] & 1 == 0) return false;

    const pdpt_phys = pml4e[idx3] & 0x000F_FFFF_FFFF_F000;
    const pdpt_virt = hhdm.physToVirt(pdpt_phys);
    const pdpte: [*]u64 = @ptrFromInt(pdpt_virt);
    const idx2 = (virt >> 30) & 0x1FF;
    if (pdpte[idx2] & 1 == 0) return false;
    if (pdpte[idx2] & 0x80 != 0) return true; // 1GB page

    const pd_phys = pdpte[idx2] & 0x000F_FFFF_FFFF_F000;
    const pd_virt = hhdm.physToVirt(pd_phys);
    const pde: [*]u64 = @ptrFromInt(pd_virt);
    const idx1 = (virt >> 21) & 0x1FF;
    if (pde[idx1] & 1 == 0) return false;
    if (pde[idx1] & 0x80 != 0) return true; // 2MB page

    const pt_phys = pde[idx1] & 0x000F_FFFF_FFFF_F000;
    const pt_virt = hhdm.physToVirt(pt_phys);
    const pte: [*]u64 = @ptrFromInt(pt_virt);
    const idx0 = (virt >> 12) & 0x1FF;
    return pte[idx0] & 1 != 0;
}
