// kernel/arch/x86_64/clone.zig — Clone (fork/thread) subsystem
//
// Implements clone() syscall and COW page table duplication.

const std = @import("std");
const serial = @import("serial.zig");
const idt = @import("idt.zig");
const sched = @import("../../proc/sched.zig");
const task_mod = @import("../../proc/task.zig");
const vfs_mod = @import("../../fs/vfs.zig");
const pmm_mod = @import("../../mm/pmm.zig");
const hhdm_mod = @import("../../mm/hhdm.zig");
const paging_mod = @import("paging.zig");
const getPerCpu = @import("syscall_entry.zig").getPerCpu;
const fmt = @import("../../lib/fmt.zig");
const cow_pte_mod = @import("../../mm/cow_pte.zig");
const lifecycle_policy = @import("../../mm/lifecycle_policy.zig");
const shared_mapping_policy = @import("../../mm/shared_mapping_policy.zig");
const clone_flags_policy = @import("../../mm/clone_flags_policy.zig");
const copy_user = @import("../../mm/copy_from_user.zig");

// ── CLONE flags ──────────────────────────────────────────────────────
const CLONE_VM: u64 = 0x100;
const CLONE_FS: u64 = 0x200;
const CLONE_FILES: u64 = 0x400;
const CLONE_SIGHAND: u64 = 0x800;
const CLONE_THREAD: u64 = 0x10000;
const CLONE_SETTLS: u64 = 0x80000;
const CLONE_PARENT_SETTID: u64 = 0x100000;
const CLONE_CHILD_CLEARTID: u64 = 0x200000;

/// CLONE_THREAD tasks share the group's leader TID as their parent_tid.
/// Preserve that identity when a thread creates another thread.
fn threadGroupParentTid(parent: *const task_mod.Task, flags: u64) u32 {
    if (flags & CLONE_THREAD != 0 and parent.is_thread and parent.parent_tid != 0) {
        return parent.parent_tid;
    }
    return parent.tid;
}

/// Parent register state to replicate into child.
pub const ParentRegs = struct {
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

// ── COW page-table duplication ───────────────────────────────────────

/// Check if a 4096-byte page is entirely zero.
fn isZeroPage(page: [*]const u8) bool {
    const words: [*]const u64 = @ptrCast(@alignCast(page));
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        if (words[i] != 0) return false;
    }
    return true;
}

fn isSharedMapping(regions: []const task_mod.MmapRegion, virt: u64) bool {
    for (regions) |*region| {
        if (!region.active or !region.shared) continue;
        if (shared_mapping_policy.contains(region.base, region.num_pages, virt, 4096)) return true;
    }
    return false;
}

/// Clone the user-space page tables with Copy-on-Write semantics.
/// Returns the physical address of the new PML4, or null on OOM.
///
/// Transactional three-phase structure (same as proc/fork.zig's
/// cloneUserPagesCow): phase 0 demotes parent huge PDEs (neutral) and counts
/// table pages; phase 1 preallocates them into a pool (failure frees only
/// fresh, unlinked pages — parent untouched); phase 2 downgrades and fills
/// with zero allocations, so OOM can neither abandon a half-built child tree
/// nor leave the parent COW-marked for a child that does not exist.
pub fn cloneUserPages(parent_pml4_phys: u64, shared_regions: []const task_mod.MmapRegion) ?u64 {
    const ADDR_MASK: u64 = 0xFFFFFFFFF000;

    const parent_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pml4_phys));

    // ── Phase 0: demote + count ──────────────────────────────────────
    var needed: u32 = 1; // the child PML4 itself
    for (0..256) |pml4_idx| {
        const pml4e = parent_pml4[pml4_idx];
        if (pml4e == 0 or pml4e & 1 == 0) continue;
        needed += 1;

        const count_pdpt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(pml4e & ADDR_MASK));
        for (0..512) |pdpt_idx| {
            const pdpte = count_pdpt[pdpt_idx];
            if (pdpte == 0 or pdpte & 1 == 0) continue;
            needed += 1;

            const count_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(pdpte & ADDR_MASK));
            for (0..512) |pd_idx| {
                // I1: a 2MiB user huge PDE is a data frame, not a PT —
                // demote it in the parent before the 4K COW walk below.
                const huge_virt = (@as(u64, pml4_idx) << 39) |
                    (@as(u64, pdpt_idx) << 30) | (@as(u64, pd_idx) << 21);
                paging_mod.demoteHugePage(parent_pml4_phys, huge_virt) catch return null;
                const pde = count_pd[pd_idx];
                if (pde == 0 or pde & 1 == 0) continue;
                needed += 1;
            }
        }
    }
    // 512 pool entries cover 1 GiB of 4K PTEs — more than the machine's RAM.
    if (needed > 512) return null;

    // ── Phase 1: preallocate pool + tables ───────────────────────────
    const pool_phys = pmm_mod.allocPage() orelse return null;
    const pool: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(pool_phys));
    var got: u32 = 0;
    while (got < needed) : (got += 1) {
        pool[got] = pmm_mod.allocPage() orelse {
            for (0..got) |j| pmm_mod.freePage(pool[j]);
            pmm_mod.freePage(pool_phys);
            return null;
        };
        const t: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(pool[got]));
        @memset(t[0..4096], 0);
    }
    defer pmm_mod.freePage(pool_phys);

    // ── Phase 2: build + downgrade (allocation-free, cannot fail) ────
    var next: u32 = 1;
    const child_pml4_phys = pool[0];
    const child_pml4: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pml4_phys));

    const kernel_pml4_phys = paging_mod.getKernelPml4();
    const kernel_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(kernel_pml4_phys));
    for (256..512) |i| {
        child_pml4[i] = kernel_pml4[i];
    }

    for (0..256) |pml4_idx| {
        const pml4e = parent_pml4[pml4_idx];
        if (pml4e == 0) continue;
        if (pml4e & 1 == 0) continue;

        const parent_pdpt_phys = pml4e & ADDR_MASK;
        // A table that appeared after phase 0 would overflow the pool —
        // abort rather than index past it (concurrent CLONE_VM mutation).
        if (next >= needed) return abortClone(child_pml4_phys);
        const child_pdpt_phys = pool[next];
        next += 1;
        const child_pdpt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pdpt_phys));
        child_pml4[pml4_idx] = child_pdpt_phys | 0x07;

        const parent_pdpt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pdpt_phys));

        for (0..512) |pdpt_idx| {
            const pdpte = parent_pdpt[pdpt_idx];
            if (pdpte == 0) continue;
            if (pdpte & 1 == 0) continue;

            const parent_pd_phys = pdpte & ADDR_MASK;
            if (next >= needed) return abortClone(child_pml4_phys);
            const child_pd_phys = pool[next];
            next += 1;
            const child_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pd_phys));
            child_pdpt[pdpt_idx] = child_pd_phys | 0x07;

            const parent_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pd_phys));

            for (0..512) |pd_idx| {
                // Phase 0 already demoted every huge PDE; this is a no-op
                // safeguard against one appearing between the phases.
                const huge_virt = (@as(u64, pml4_idx) << 39) |
                    (@as(u64, pdpt_idx) << 30) | (@as(u64, pd_idx) << 21);
                paging_mod.demoteHugePage(parent_pml4_phys, huge_virt) catch return abortClone(child_pml4_phys);
                const pde = parent_pd[pd_idx];
                if (pde == 0) continue;
                if (pde & 1 == 0) continue;

                const parent_pt_phys = pde & ADDR_MASK;
                if (next >= needed) return abortClone(child_pml4_phys);
                const child_pt_phys = pool[next];
                next += 1;
                const child_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pt_phys));
                child_pd[pd_idx] = child_pt_phys | 0x07;

                const parent_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pt_phys));

                for (0..512) |pt_idx| {
                    const pte = parent_pt[pt_idx];
                    if (pte == 0) continue;
                    if (pte & 1 == 0) continue;

                    const src_phys = pte & ADDR_MASK;

                    const src: [*]const u8 = @ptrFromInt(hhdm_mod.physToVirt(src_phys));
                    const virt = (@as(u64, pml4_idx) << 39) |
                        (@as(u64, pdpt_idx) << 30) |
                        (@as(u64, pd_idx) << 21) |
                        (@as(u64, pt_idx) << 12);
                    const shared_mapping = isSharedMapping(shared_regions, virt);
                    if (isZeroPage(src) and !shared_mapping) continue;

                    pmm_mod.addRef(src_phys);
                    if (shared_mapping) {
                        // MAP_SHARED keeps writable access and the same frame
                        // in both address spaces; only the reference count is
                        // duplicated here.
                        child_pt[pt_idx] = pte;
                    } else {
                        // Private mappings use COW. Rebuilding from the frame
                        // address would drop NX at bit 63, so preserve flags.
                        const cow = cow_pte_mod.sharedPte(pte);
                        parent_pt[pt_idx] = cow;
                        child_pt[pt_idx] = cow;
                    }
                }
            }
        }
    }

    // K4: reloadCR3 only flushes THIS CPU; CPUs sharing the parent's address
    // space (CLONE_VM) or the parent's previous CPU under PCID no-flush would
    // keep stale writable entries for the just-downgraded pages. A ranged
    // shootdown over the user space flushes local + all matching remote CPUs.
    const tlb = @import("tlb.zig");
    tlb.shootdownRange(0, 1 << 31, parent_pml4_phys);
    return child_pml4_phys;
}

/// Roll back a half-built child tree (destroyUserSpace tolerates a partial
/// tree and its batched frees undo the addRef increments on shared pages).
fn abortClone(child_pml4_phys: u64) ?u64 {
    @import("../../mm/user_space.zig").destroyUserSpace(child_pml4_phys);
    return null;
}

// ── clone() syscall ──────────────────────────────────────────────────

/// Core clone implementation. Returns child TID to parent, or -errno.
pub fn clone(
    flags: u64,
    new_stack: u64,
    parent_tid_ptr: u64,
    child_tid_ptr: u64,
    tls: u64,
    regs: ParentRegs,
) i64 {
    if (!clone_flags_policy.valid(flags, blk: {
        const idx = sched.currentTaskIndex() orelse break :blk false;
        break :blk (task_mod.getTask(idx) orelse break :blk false).mm != null;
    })) return -22; // EINVAL: unsupported or incoherent flags
    const parent_idx = sched.currentTaskIndex() orelse return -1;
    const parent = task_mod.getTask(parent_idx) orelse return -1;
    if (flags & clone_flags_policy.TID_FLAGS != 0) {
        if (parent_tid_ptr != 0 and !copy_user.validateUserBufferWritable(parent_tid_ptr, 4)) return -14;
        if (child_tid_ptr != 0 and !copy_user.validateUserBufferWritable(child_tid_ptr, 4)) return -14;
        if (flags & clone_flags_policy.CLONE_PARENT_SETTID != 0 and parent_tid_ptr == 0) return -22;
        if (flags & clone_flags_policy.CLONE_CHILD_CLEARTID != 0 and child_tid_ptr == 0) return -22;
    }

    // See fork(): until SHM attachment ownership is shared/address-space
    // based, reject both process and CLONE_VM cloning while attached.
    if (@import("../../ipc/sysv_shm.zig").hasAttachments(parent.tid)) return -11; // EAGAIN

    // RLIMIT_NPROC preflight: a thread or process created via clone counts
    // against the parent's real UID (Linux counts every task). Gate before
    // COW cloning or address-space retention so a denied clone leaks
    // nothing. EAGAIN matches Linux.
    if (!task_mod.nprocPreflight(parent.uid, parent.nproc_cur)) return -11;

    // CLONE_VM: share address space (thread) vs COW copy (process)
    const shares_vm = flags & CLONE_VM != 0;
    const vm_policy = lifecycle_policy.cloneVmResult(flags, parent.mm != null);
    if (vm_policy != 0) return vm_policy;
    const child_pml4 = if (shares_vm)
        parent.page_table_phys
    else
        // Guard the COW page-table clone with the parent's vm_lock: it
        // rewrites parent PTEs and must not race concurrent VM mutations or
        // fault-side PTE writes. Scope is deliberately limited to the clone
        // call — createUserProcess takes task_lock (ordering violation under
        // vm_lock); region-metadata inheritance stays a follow-up.
        clone: {
            var vm_guard = @import("../../mm/mm.zig").Mm.beginVmMutation(parent.mm, @ptrCast(parent)) catch return -12; // ENOMEM
            defer vm_guard.release();
            break :clone cloneUserPages(parent.page_table_phys, &parent.mmap_regions) orelse return -12; // ENOMEM
        };

    if (shares_vm) {
        if (parent.mm) |parent_mm| {
            if (!parent_mm.retain()) return -12;
        }
    } else {
        // I1: the COW clone demoted every huge block in the parent (the
        // walk is 4K-only) — no huge pages remain, clear the counts.
        for (&parent.mmap_regions) |*r| r.huge_pages = 0;
    }

    // parent_mm.retain() above supplies the one retained reference transferred
    // to createUserProcess for CLONE_VM. That function releases it on failure
    // or installs it as the child owner on success, so clone must not release
    // the reference after this call (including when the call returns null).
    const child_idx = task_mod.createUserProcess(
        parent.user_entry,
        if (new_stack != 0) new_stack else parent.user_stack_top,
        child_pml4,
        if (shares_vm) parent.mm else null,
        threadGroupParentTid(parent, flags),
        false, // inherit general affinity
        @import("../../proc/capability_profile.zig").default_user_profile,
        parent.fSize_cur,
        parent.fSize_max,
    ) orelse return -12;
    const child = task_mod.getTask(child_idx).?;
    child.clear_tid_ptr = if (flags & clone_flags_policy.CLONE_CHILD_CLEARTID != 0) child_tid_ptr else 0;
    child.nofile_cur = parent.nofile_cur;
    child.nofile_max = parent.nofile_max;
    child.stack_cur = parent.stack_cur;
    child.stack_max = parent.stack_max;
    child.as_cur = parent.as_cur;
    child.as_max = parent.as_max;
    child.data_cur = parent.data_cur;
    child.data_max = parent.data_max;
    child.nproc_cur = parent.nproc_cur;
    child.nproc_max = parent.nproc_max;
    child.fSize_cur = parent.fSize_cur;
    child.fSize_max = parent.fSize_max;
    // The clone's address space mirrors (or with CLONE_VM shares) the
    // parent's, so it starts with the same charged usage.
    child.as_used = parent.as_used;
    child.data_used = parent.data_used;
    child.mmap_regions = parent.mmap_regions;
    child.mmap_count = parent.mmap_count;
    child.mmap_active_bm = parent.mmap_active_bm;

    child.brk_current = parent.brk_current;
    child.stack_limit = parent.stack_limit;

    if (flags & CLONE_FILES != 0) {
        // Share the fd table with the parent (pthread v2): one atomic
        // reference added, NO descriptor copy and NO retainSharedResources —
        // the table holds exactly one reference per underlying resource for
        // the whole thread group, and exitTask only closes it when the last
        // reference drops. The fresh table createUserProcess allocated goes
        // straight back to the pool (it only wires stdin/stdout/stderr, whose
        // close is a no-op). alloc_limit is inherited with the shared table —
        // the thread group shares NOFILE, matching Linux.
        vfs_mod.retainFdTable(parent.fd_table);
        const fresh = child.fd_table;
        child.fd_table = parent.fd_table;
        if (vfs_mod.releaseFdTable(fresh)) vfs_mod.freeFdTable(fresh);
    } else {
        child.fd_table.alloc_limit = child.nofile_cur;

        // v53.50: Copy free_bm bitmap — child inherits parent's fd occupancy state.
        parent.fd_table.inheritFdTable(child.fd_table);
    }
    // POSIX MQ descriptors live outside FdTable; mirror their per-task
    // references for both fork-like clones and CLONE_FILES threads.
    @import("../../ipc/posix_mq.zig").inheritRefs(
        sched.currentTaskIndex() orelse return -1,
        child_idx,
    );

    // Signal handlers, mask, environment, cwd, pgid, sid
    for (0..31) |i| {
        child.signal_handlers[i] = parent.signal_handlers[i];
    }
    child.signal_mask = parent.signal_mask;
    child.env_count = parent.env_count;
    for (0..parent.env_count) |i| {
        child.env_vars[i] = parent.env_vars[i];
    }
    @memcpy(child.cwd[0..256], parent.cwd[0..256]);
    child.cwd_len = parent.cwd_len;
    child.pgid = parent.pgid;
    child.sid = parent.sid;
    // CLONE_THREAD: 标记为线程——getpid 汇报 tgid，waitpid 不 reap。
    child.is_thread = (flags & CLONE_THREAD) != 0;
    // Inherit credentials
    child.uid = parent.uid;
    child.gid = parent.gid;
    child.euid = parent.euid;
    child.egid = parent.egid;
    child.suid = parent.suid;
    child.sgid = parent.sgid;
    child.umask_val = @import("../../proc/creation_metadata.zig").inheritedTaskUmask(parent.umask_val);
    child.effective_caps = parent.effective_caps;
    child.permitted_caps = parent.permitted_caps;
    child.inheritable_caps = parent.inheritable_caps;
    child.initial_init = false;

    // Set up child's execution context
    const child_stack_top = child.kernel_stack_top;
    const child_frame_addr = child_stack_top - @sizeOf(idt.InterruptFrame);
    const child_frame: *idt.InterruptFrame = @ptrFromInt(child_frame_addr);
    const frame_bytes: [*]u8 = @ptrCast(child_frame);
    @memset(frame_bytes[0..@sizeOf(idt.InterruptFrame)], 0);

    child_frame.rax = 0;
    child_frame.rbx = regs.rbx;
    child_frame.rcx = regs.rcx;
    child_frame.rdx = regs.rdx;
    child_frame.rsi = regs.rsi;
    child_frame.rdi = regs.rdi;
    child_frame.rbp = regs.rbp;
    child_frame.r8 = regs.r8;
    child_frame.r9 = regs.r9;
    child_frame.r10 = regs.r10;
    child_frame.r11 = regs.r11;
    child_frame.r12 = regs.r12;
    child_frame.r13 = regs.r13;
    child_frame.r14 = regs.r14;
    child_frame.r15 = regs.r15;

    child_frame.rip = regs.rcx; // sysret return address
    child_frame.cs = 0x1B;
    child_frame.rflags = regs.r11;
    if (new_stack != 0) {
        child_frame.rsp = new_stack;
        child.user_stack_top = new_stack;
    } else {
        child_frame.rsp = getPerCpu().saved_user_rsp;
    }
    child_frame.ss = 0x23;
    child_frame.vector = 0;
    child_frame.error_code = 0;

    child.saved_rsp = child_frame_addr;
    child.started = true;

    // CLONE_SETTLS names the *child's* TLS. Writing FS_BASE here would program
    // the CPU currently running the parent: the parent would start reading the
    // child's TLS block, the child would get whatever base happened to be
    // loaded, and since nothing saved FS_BASE per task the stray value stayed on
    // that CPU for every task scheduled after it. Record it on the child and let
    // the scheduler install it.
    child.tls_base = if (flags & CLONE_SETTLS != 0) tls else parent.tls_base;

    // A thread's creator keeps running by definition, so unlike fork this path
    // cannot rely on the run queue draining to get the child noticed.
    if (flags & clone_flags_policy.CLONE_PARENT_SETTID != 0) {
        var tid_buf: [4]u8 = undefined;
        const child_tid = child.tid;
        tid_buf[0] = @truncate(child_tid);
        tid_buf[1] = @truncate(child_tid >> 8);
        tid_buf[2] = @truncate(child_tid >> 16);
        tid_buf[3] = @truncate(child_tid >> 24);
        if (copy_user.copyToUser(@ptrFromInt(parent_tid_ptr), &tid_buf, 4) != 4) {
            return -14;
        }
    }
    child.saved_user_rsp = child_frame.rsp;
    task_mod.publishRunnable(child_idx);

    serial.writeString("[clone] parent=");
    fmt.writeDecimal(parent.tid);
    serial.writeString(" child=");
    fmt.writeDecimal(child.tid);
    if (flags & CLONE_VM != 0) serial.writeString(" VM");
    if (flags & CLONE_THREAD != 0) serial.writeString(" THREAD");
    serial.writeString("\n");
    return @intCast(child.tid);
}

test "nested CLONE_THREAD preserves the thread group's leader TID" {
    var parent: task_mod.Task = undefined;
    parent.tid = 43;
    parent.is_thread = true;
    parent.parent_tid = 42;
    try std.testing.expectEqual(@as(u32, 42), threadGroupParentTid(&parent, CLONE_THREAD));
    try std.testing.expectEqual(@as(u32, 43), threadGroupParentTid(&parent, 0));
}
