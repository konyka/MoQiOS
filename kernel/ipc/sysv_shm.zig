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
const sched = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const shm_policy = @import("shm_policy.zig");
const sysv_policy = @import("sysv_policy.zig");
const tlb = @import("../arch/arch.zig").tlb;

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

const USER_ADDR_MAX: u64 = 0x0000_8000_0000_0000;

/// Attached-segment bookkeeping, keyed by TID, so process exit can detach
/// segments whose owner never called shmdt (attach_count would otherwise
/// leak and IPC_RMID segments would never be freed).
const MAX_ATTACH_RECS: u32 = 128;
const AttachRec = struct {
    active: bool = false,
    tid: u32 = 0,
    shmid: u32 = 0,
    base: u64 = 0,
};
var attach_recs: [MAX_ATTACH_RECS]AttachRec = @splat(.{});

/// True if an attach-record slot is free. Caller holds shm_lock.
fn hasFreeAttachRec() bool {
    for (&attach_recs) |*rec| {
        if (!rec.active) return true;
    }
    return false;
}

/// Record an attachment. Caller holds shm_lock and checked hasFreeAttachRec.
fn addAttachRec(tid: u32, shmid: u32, base: u64) void {
    for (&attach_recs) |*rec| {
        if (!rec.active) {
            rec.* = .{ .active = true, .tid = tid, .shmid = shmid, .base = base };
            return;
        }
    }
}

/// Drop the record for (tid, base), if any. Caller holds shm_lock.
fn removeAttachRec(tid: u32, base: u64) void {
    for (&attach_recs) |*rec| {
        if (rec.active and rec.tid == tid and rec.base == base) {
            rec.active = false;
            return;
        }
    }
}

fn existingLookup(seg: *const ShmSegment, shmflg: i32, credentials: sysv_policy.Credentials) i64 {
    const segment_owner: sysv_policy.Owner = .{
        .uid = seg.perm.uid,
        .gid = seg.perm.gid,
        .cuid = seg.perm.cuid,
        .cgid = seg.perm.cgid,
    };
    return switch (shm_policy.existingLookup(
        shmflg & IPC_CREAT != 0 and shmflg & IPC_EXCL != 0,
        @intCast(shmflg & 0o777),
        seg.perm.mode,
        segment_owner,
        credentials,
    )) {
        .allow => @intCast(seg.shmid),
        .exists => -17, // -EEXIST
        .access_denied => -13, // -EACCES
    };
}

/// IPC flags
const IPC_CREAT: i32 = 0o1000;
const IPC_EXCL: i32 = 0o2000;
const IPC_RMID: i32 = 0;
const IPC_STAT: i32 = 2;
const IPC_SET: i32 = 1;
const IPC_PRIVATE: i32 = 0;

/// shmget(key, size, shmflg) -> shmid or -errno
pub fn shmget(key: i32, size: u64, shmflg: i32) i64 {
    const owner = if (sched.currentTaskIndex()) |idx| task_mod.getTask(idx) else null;
    const owner_uid: u32 = if (owner) |task| task.euid else 0;
    const owner_gid: u32 = if (owner) |task| task.egid else 0;
    const credentials: sysv_policy.Credentials = if (owner) |task|
        .{ .euid = task.euid, .egid = task.egid, .cap_sys_admin = task.effective_caps.cap_sys_admin }
    else
        .{ .euid = 0, .egid = 0, .cap_sys_admin = true };
    // Phase 1 (locked): lookup existing segment and validate the request.
    {
        const flags = shm_lock.acquire();
        defer shm_lock.release(flags);

        // Search for existing segment with this key
        if (key != IPC_PRIVATE) {
            for (&segments) |*seg| {
                if (seg.active and seg.perm.key == key) {
                    return existingLookup(seg, shmflg, credentials);
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
    }

    const num_pages: u32 = @intCast((size + PAGE_SIZE - 1) / PAGE_SIZE);

    // Allocate and zero physical pages WITHOUT shm_lock: zeroing up to 1 MiB
    // with IRQs off stalls interrupt handling for milliseconds.
    var phys_pages: [MAX_PAGES_PER_SEG]u64 = @splat(0);
    var allocated: u32 = 0;
    for (0..num_pages) |p| {
        const phys = pmm.allocPage() orelse {
            freePages(&phys_pages, allocated);
            return -12; // -ENOMEM
        };
        phys_pages[p] = phys;
        allocated += 1;
        // Zero the page
        const virt_addr = hhdm.physToVirt(phys);
        const ptr: [*]u8 = @ptrFromInt(virt_addr);
        @memset(ptr[0..PAGE_SIZE], 0);
    }

    // Phase 2 (locked): re-validate (another CPU may have created the segment
    // or taken the last slot while we allocated without the lock), then publish.
    var result: i64 = -1;
    var published = false;
    {
        const flags = shm_lock.acquire();
        defer shm_lock.release(flags);

        if (key != IPC_PRIVATE) {
            for (&segments) |*seg| {
                if (seg.active and seg.perm.key == key) {
                    // Lost the race — drop our pages and report the winner.
                    result = existingLookup(seg, shmflg, credentials);
                    break;
                }
            }
        }

        if (result == -1) {
            // Find a free slot
            var slot: ?u32 = null;
            for (0..MAX_SEGMENTS) |i| {
                if (!segments[i].active) {
                    slot = @intCast(i);
                    break;
                }
            }
            if (slot == null) {
                result = -28; // -ENOSPC
            } else {
                const idx = slot.?;
                const shmid = next_shmid;
                next_shmid += 1;

                const seg = &segments[idx];
                seg.* = .{
                    .active = true,
                    .perm = .{
                        .key = key,
                        .uid = owner_uid,
                        .gid = owner_gid,
                        .cuid = owner_uid,
                        .cgid = owner_gid,
                        .mode = @intCast(shmflg & 0o777),
                    },
                    .shmid = shmid,
                    .size = size,
                    .num_pages = num_pages,
                    .phys_pages = phys_pages,
                    .attach_count = 0,
                    .owner_tid = 0,
                };
                published = true;
                result = @intCast(shmid);

                serial.writeString("[sysv_shm] created shmid=");
                fmt.writeDecimal(seg.shmid);
                serial.writeString(" key=");
                fmt.writeDecimal64(@intCast(seg.perm.key));
                serial.writeString(" pages=");
                fmt.writeDecimal(seg.num_pages);
                serial.writeString("\n");
            }
        }
    }

    if (!published) freePages(&phys_pages, allocated);
    return result;
}

/// shmat(shmid, shmaddr, shmflg) -> virtual address or -errno
/// Maps shared memory into the current process's address space.
pub fn shmat(shmid: u32, shmaddr: u64, shmflg: u64) i64 {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    // Find segment
    const seg = findSegment(shmid) orelse return -22; // -EINVAL

    if (seg.marked_removed) return -22; // -EINVAL
    if (!shm_policy.flagsValid(shmflg)) return -22; // -EINVAL
    // Replacing arbitrary VMAs safely requires their backing metadata and
    // ownership to be released first. Reject SHM_REMAP until that operation
    // can be made transactional; silently overwriting PTEs would corrupt the
    // replaced mapping and can free unrelated frames.
    if (shmflg & shm_policy.SHM_REMAP != 0) return -22; // -EINVAL

    // Get current process page table
    const cur_idx = sched.currentTaskIndex() orelse return -1; // -EPERM
    const task = task_mod.getTask(cur_idx) orelse return -1;
    const pml4 = task.page_table_phys;
    if (pml4 == 0) return -1; // kernel thread can't attach

    var requested_access: u5 = if (shmflg & shm_policy.SHM_RDONLY != 0) 0o4 else 0o6;
    if (shmflg & shm_policy.SHM_EXEC != 0) requested_access |= 0o1;
    if (task.euid != 0) {
        const class_bits: u5 = if (task.euid == seg.perm.uid)
            6
        else if (task.egid == seg.perm.gid)
            3
        else
            0;
        if (!shm_policy.modeAllows(seg.perm.mode, class_bits, requested_access)) return -13; // -EACCES
    }

    // Need an attach-record slot so process exit can undo this attachment.
    if (!hasFreeAttachRec()) return -28; // -ENOSPC

    // Determine mapping address
    const map_addr: u64 = if (shmaddr != 0) blk: {
        if (shmflg & shm_policy.SHM_RND != 0) break :blk shmaddr / PAGE_SIZE * PAGE_SIZE;
        break :blk shmaddr;
    } else findFreeRegion(task, seg.num_pages);
    if (map_addr == 0) return -12; // -ENOMEM
    if (map_addr & (PAGE_SIZE - 1) != 0) return -22; // -EINVAL (not aligned)
    const map_size = @as(u64, seg.num_pages) * PAGE_SIZE;
    _ = shm_policy.rangeEnd(map_addr, map_size, USER_ADDR_MAX) orelse return -22;

    // SHM_REMAP is intentionally rejected above; a nonzero address must be a
    // wholly free mapping, not merely a valid address at its first page.

    // Preflight the complete range before installing any PTE. mapPage replaces
    // an existing PTE, so checking only the first page leaves partial overlap
    // able to destroy unrelated mappings.
    for (0..seg.num_pages) |p| {
        const virt = map_addr + @as(u64, @intCast(p)) * PAGE_SIZE;
        if (paging.isPageMapped(pml4, virt)) return -22; // -EINVAL
    }

    // Map flags
    var map_flags: paging.MapFlags = .{ .writable = true, .user = true };
    if (shmflg & shm_policy.SHM_RDONLY != 0) {
        // SHM_RDONLY
        map_flags.writable = false;
    }
    if (shmflg & shm_policy.SHM_EXEC != 0) map_flags.no_execute = false;

    // Track each successful install so rollback never infers ownership from
    // the current loop index or unmaps a page outside this call.
    var installed: [MAX_PAGES_PER_SEG]u32 = undefined;
    var installed_count: u32 = 0;

    // Map each page
    for (0..seg.num_pages) |p| {
        const virt = map_addr + @as(u64, @intCast(p)) * PAGE_SIZE;
        paging.mapPage(pml4, virt, seg.phys_pages[p], map_flags) catch {
            // Roll back only pages installed by this call. Verify the PTE
            // still owns the expected SHM frame before removing it; this
            // avoids destroying a mapping that changed after installation.
            var q = installed_count;
            while (q > 0) {
                q -= 1;
                const page_index = installed[q];
                const rv = map_addr + @as(u64, page_index) * PAGE_SIZE;
                if (isMappedAt(pml4, rv, seg.phys_pages[page_index])) {
                    _ = paging.unmapPage(pml4, rv);
                }
            }
            if (installed_count > 0) tlb.shootdownRange(map_addr, installed_count, pml4);
            return -12; // -ENOMEM
        };
        installed[installed_count] = @intCast(p);
        installed_count += 1;
    }

    // mapPage already flushes locally; also invalidate CPUs that may retain
    // this address space, matching the generic VM unmap lifecycle.
    tlb.shootdownRange(map_addr, @intCast(seg.num_pages), pml4);

    seg.attach_count += 1;
    addAttachRec(task.tid, shmid, map_addr);

    serial.writeString("[sysv_shm] shmat shmid=");
    fmt.writeDecimal(shmid);
    serial.writeString(" addr=0x");
    fmt.writeHex(map_addr);
    serial.writeString("\n");

    return @intCast(map_addr);
}

/// True if [base, base + num_pages) intersects an attachment owned by `tid`.
/// The generic munmap path uses this guard so only shmdt can release SHM pages.
pub fn overlapsAttachment(tid: u32, base: u64, num_pages: u64) bool {
    const size_result = @mulWithOverflow(num_pages, PAGE_SIZE);
    if (size_result[1] != 0) return true;
    const range_end = shm_policy.rangeEnd(base, size_result[0], USER_ADDR_MAX) orelse return true;
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);
    for (attach_recs) |rec| {
        if (!rec.active or rec.tid != tid) continue;
        const seg = findSegment(rec.shmid) orelse continue;
        const attached_end = rec.base + @as(u64, seg.num_pages) * PAGE_SIZE;
        if (base < attached_end and rec.base < range_end) return true;
    }
    return false;
}

/// Fork/clone cannot safely duplicate SHM attachment ownership yet: a COW
/// child would turn shared pages private, while CLONE_VM exit would unmap the
/// sibling's attachment. Callers must reject the operation while attached.
pub fn hasAttachments(tid: u32) bool {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);
    for (attach_recs) |rec| {
        if (rec.active and rec.tid == tid) return true;
    }
    return false;
}

/// shmdt(shmaddr) -> 0 or -errno
/// Detaches shared memory from the current process.
pub fn shmdt(shmaddr: u64) i64 {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    if (shmaddr == 0 or shmaddr & (PAGE_SIZE - 1) != 0) return -22; // -EINVAL

    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const task = task_mod.getTask(cur_idx) orelse return -1;
    const pml4 = task.page_table_phys;
    if (pml4 == 0) return -1;

    // Resolve the caller's own attachment record first. Matching only the
    // physical frame at an address could detach another mapping that happens
    // to use the same segment, and would corrupt attach_count.
    for (&attach_recs) |*rec| {
        if (!rec.active or rec.tid != task.tid or rec.base != shmaddr) continue;
        const seg = findSegment(rec.shmid) orelse return -22;
        if (!isMappedRange(pml4, shmaddr, seg)) return -22;
        // Unmap all pages
        for (0..seg.num_pages) |p| {
            const virt = shmaddr + @as(u64, @intCast(p)) * PAGE_SIZE;
            _ = paging.unmapPage(pml4, virt);
        }
        // Invalidate every CPU that may still run this address space before
        // the attachment is considered gone.
        tlb.shootdownRange(shmaddr, @intCast(seg.num_pages), pml4);
        rec.active = false;
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

    return -22; // -EINVAL (not attached)
}

/// Detach every segment still attached by `tid`. Called from task.exitTask
/// so a process that exits without shmdt doesn't leak attachments (and
/// IPC_RMID segments waiting on attach_count get freed).
pub fn detachAllForTask(tid: u32, pml4: u64) void {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    for (&attach_recs) |*rec| {
        if (!rec.active or rec.tid != tid) continue;
        rec.active = false;
        const seg = findSegment(rec.shmid) orelse continue;

        // Unmap all pages
        for (0..seg.num_pages) |p| {
            _ = paging.unmapPage(pml4, rec.base + @as(u64, @intCast(p)) * PAGE_SIZE);
        }
        tlb.shootdownRange(rec.base, @intCast(seg.num_pages), pml4);
        if (seg.attach_count > 0) seg.attach_count -= 1;

        serial.writeString("[sysv_shm] exit-detach shmid=");
        fmt.writeDecimal(seg.shmid);
        serial.writeString(" addr=0x");
        fmt.writeHex(rec.base);
        serial.writeString("\n");

        // If marked for removal and no more attachments, free it
        if (seg.marked_removed and seg.attach_count == 0) {
            freeSegment(seg);
        }
    }
}

/// shmctl(shmid, cmd, buf) -> 0 or -errno
pub fn shmctl(shmid: u32, cmd: i32, buf: u64) i64 {
    const flags = shm_lock.acquire();
    defer shm_lock.release(flags);

    const seg = findSegment(shmid) orelse return -22; // -EINVAL
    const cur = if (sched.currentTaskIndex()) |idx| task_mod.getTask(idx) else null;
    const can_manage = if (cur) |task|
        task.euid == 0 or task.euid == seg.perm.uid or task.euid == seg.perm.cuid
    else
        false;

    switch (cmd) {
        IPC_STAT => {
            if (!can_manage and cur != null) {
                const task = cur.?;
                const class_bits: u5 = if (task.egid == seg.perm.gid) 3 else 0;
                if (!shm_policy.modeAllows(seg.perm.mode, class_bits, 0o4)) return -13; // -EACCES
            }
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
            if (!can_manage) return -1; // -EPERM
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
            if (!can_manage) return -1; // -EPERM
            // Update permission mode bits from buf (simplified: accept mode as u64)
            if (buf == 0 or buf >= 0x0000_8000_0000_0000) return -14; // -EFAULT
            const copy = @import("../mm/copy_from_user.zig");
            var mode_buf: [1]u64 = .{0};
            if (copy.copyFromUser(@ptrCast(&mode_buf), @as([*]const u8, @ptrFromInt(buf)), @sizeOf(u64)) != @sizeOf(u64)) return -14; // -EFAULT
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

/// Free `count` pages from a freshly allocated (not yet published) page list.
fn freePages(phys_pages: *[MAX_PAGES_PER_SEG]u64, count: u32) void {
    for (0..count) |p| {
        if (phys_pages[p] != 0) {
            pmm.freePage(phys_pages[p]);
            phys_pages[p] = 0;
        }
    }
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

fn isMappedRange(pml4: u64, base: u64, seg: *const ShmSegment) bool {
    for (0..seg.num_pages) |p| {
        const virt = base + @as(u64, @intCast(p)) * PAGE_SIZE;
        if (!isMappedAt(pml4, virt, seg.phys_pages[p])) return false;
    }
    return true;
}

/// Find a free virtual region in user space for mapping.
/// Uses next_free_hint to avoid rescanning previously allocated regions.
/// Conflicts are checked against the process's tracked mmap/vma list (cheap
/// memory compares) instead of probing the page tables for every candidate
/// page — the old O(region × pages) walk held shm_lock (IRQs off) for
/// milliseconds. Page-table probing only happens for pages the region list
/// does not know about (loaded image, earlier shmat after a hint wrap).
fn findFreeRegion(task: *task_mod.Task, num_pages: u32) u64 {
    const SHM_BASE: u64 = 0x7000_0000;
    const SHM_END: u64 = 0x7800_0000; // 128MB region
    const region_size: u64 = @as(u64, num_pages) * PAGE_SIZE;

    var addr: u64 = next_free_hint;
    while (addr + region_size <= SHM_END) {
        // Skip past any tracked region overlapping this candidate.
        var conflict_end: u64 = 0;
        for (task.mmap_regions) |r| {
            if (!r.active) continue;
            const r_end = r.base + r.num_pages * PAGE_SIZE;
            if (addr < r_end and r.base < addr + region_size) {
                conflict_end = @max(conflict_end, r_end);
            }
        }
        if (conflict_end != 0) {
            addr = conflict_end;
            continue;
        }
        // Probe untracked pages once; skip straight past the first one in the
        // way instead of rescanning page by page.
        var p: u32 = 0;
        while (p < num_pages) : (p += 1) {
            if (isPageMapped(task.page_table_phys, addr + @as(u64, @intCast(p)) * PAGE_SIZE)) break;
        }
        if (p == num_pages) {
            next_free_hint = addr + region_size; // advance hint past this region
            return addr;
        }
        addr += @as(u64, p + 1) * PAGE_SIZE;
    }
    // Wrap around: retry from SHM_BASE if we started past it
    if (next_free_hint > SHM_BASE) {
        next_free_hint = SHM_BASE;
        return findFreeRegion(task, num_pages);
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
