const syscall_entry = @import("../arch/arch.zig").syscall;
const SyscallFrame = syscall_entry.SyscallFrame;
const getPerCpu = syscall_entry.getPerCpu;
const serial = @import("../arch/arch.zig").serial;
const idt = @import("../arch/arch.zig").interrupts;
const fmt = @import("../lib/fmt.zig");

/// Syscall #57: fork() — clone the current process.
/// Returns child TID to parent, -1 on error.
pub fn fork(frame: *SyscallFrame) i64 {
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const vfs_mod = @import("../fs/vfs.zig");

    const parent_idx = sched.currentTaskIndex() orelse return -1;
    const parent = task_mod.getTask(parent_idx) orelse return -1;

    const child_pml4 = cloneUserPagesCow(parent.page_table_phys) orelse return -1;

    const child_idx = task_mod.createUserProcess(
        parent.user_entry,
        parent.user_stack_top,
        child_pml4,
        parent.tid,
        true,
    ) orelse {
        @import("../mm/user_space.zig").destroyUserSpace(child_pml4);
        return -1;
    };
    const child = task_mod.getTask(child_idx).?;

    // Inherit parent's CPU pin — fork must not migrate (M8-5b-2).
    // Task #2: also inherit last_cpu so the child first runs on the same
    // CPU as the parent (warm cache), then participates in work-stealing.
    child.cpu_affinity = parent.cpu_affinity;
    child.last_cpu = parent.last_cpu;

    child.brk_current = parent.brk_current;
    child.brk_start = parent.brk_start;
    // The child is a copy of the address space, so its TLS block sits at the
    // same address.
    child.tls_base = parent.tls_base;

    // v53.50: Copy free_bm bitmap — child inherits parent's fd occupancy state.
    // Without this, child's free_bm stays at default (only bits 0-2 occupied),
    // causing allocFd() to return already-occupied slots and corrupt fds.
    child.fd_table.free_bm = parent.fd_table.free_bm;

    for (0..vfs_mod.MAX_FDS) |i| {
        child.fd_table.fds[i] = parent.fd_table.fds[i];
        switch (child.fd_table.fds[i].fd_type) {
            .pipe_read, .pipe_write => {
                const pidx = child.fd_table.fds[i].pipe_idx;
                if (pidx < 16) {
                    _ = vfs_mod.pipeRetain(pidx, child.fd_table.fds[i].fd_type == .pipe_write);
                }
            },
            // The shallow copy duplicates readahead page pointers that stay
            // owned by the parent — drop the child's copy (UAF/double-free).
            .fat32_file => {
                const readahead = @import("../fs/readahead.zig");
                readahead.resetStateForFork(&child.fd_table.fds[i].readahead_state);
            },
            else => {},
        }
    }
    // v53.44 fix: ext2/tcp/epoll/unix/timerfd resources are now refcounted —
    // one reference per process per distinct index (see vfs.retainSharedResources).
    vfs_mod.retainSharedResources(&child.fd_table);

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

    // v53.2: inherit mmap regions so munmap/madvise/mlock work in child
    child.mmap_regions = parent.mmap_regions;
    child.mmap_count = parent.mmap_count;

    // G2: the child inherits file-backed regions. Each ext2 region piece
    // holds an open-slot reference (taken at mmap time); the child needs its
    // own so the fault path survives the parent's close/exit. tmpfs/fat32/
    // ramdisk need no retain (see mmap.zig's RegionFileMeta comments).
    for (&child.mmap_regions) |*r| {
        if (r.active and r.file_kind == @intFromEnum(@import("../mm/filemap.zig").FsKind.ext2)) {
            @import("../fs/ext2.zig").retainFile(r.file_idx);
        }
    }

    // v53.6: inherit POSIX-required process attributes (credentials, umask, process group)
    child.uid = parent.uid;
    child.gid = parent.gid;
    child.euid = parent.euid;
    child.egid = parent.egid;
    child.suid = parent.suid;
    child.sgid = parent.sgid;
    child.umask_val = parent.umask_val;
    child.pgid = parent.pgid;
    child.sid = parent.sid;
    child.personality = parent.personality;
    child.stack_limit = parent.stack_limit;
    @memcpy(child.comm[0..16], parent.comm[0..16]);
    child.sched_policy = parent.sched_policy;
    child.pdeathsig = parent.pdeathsig;

    // Task #8: inherit POSIX capability sets verbatim.
    child.effective_caps = parent.effective_caps;
    child.permitted_caps = parent.permitted_caps;
    child.inheritable_caps = parent.inheritable_caps;

    const child_stack_top = child.kernel_stack_top;
    const child_frame_addr = child_stack_top - @sizeOf(idt.InterruptFrame);
    const child_frame: *idt.InterruptFrame = @ptrFromInt(child_frame_addr);
    const frame_bytes: [*]u8 = @ptrCast(child_frame);
    @memset(frame_bytes[0..@sizeOf(idt.InterruptFrame)], 0);

    child_frame.rax = 0;
    child_frame.rbx = frame.rbx;
    child_frame.rcx = frame.rcx;
    child_frame.rdx = frame.rdx;
    child_frame.rsi = frame.rsi;
    child_frame.rdi = frame.rdi;
    child_frame.rbp = frame.rbp;
    child_frame.r8 = frame.r8;
    child_frame.r9 = frame.r9;
    child_frame.r10 = frame.r10;
    child_frame.r11 = frame.r11;
    child_frame.r12 = frame.r12;
    child_frame.r13 = frame.r13;
    child_frame.r14 = frame.r14;
    child_frame.r15 = frame.r15;

    child_frame.rip = frame.rcx;
    child_frame.cs = 0x1B;
    child_frame.rflags = frame.r11;
    child_frame.rsp = parent.saved_user_rsp;
    child_frame.ss = 0x23;
    child_frame.vector = 0;
    child_frame.error_code = 0;

    child.saved_user_rsp = parent.saved_user_rsp;

    child.saved_rsp = child_frame_addr;
    child.started = true;
    task_mod.publishRunnable(child_idx);

    serial.writeString("[fork] parent=");
    fmt.writeDecimal64(parent.tid);
    serial.writeString(" child=");
    fmt.writeDecimal64(child.tid);
    serial.writeString("\n");

    return @intCast(child.tid);
}

/// Clone all user-space pages from parent PML4 (deep copy).
pub fn cloneUserPages(parent_pml4_phys: u64) ?u64 {
    const pmm_mod = @import("../mm/pmm.zig");
    const hhdm_mod = @import("../mm/hhdm.zig");
    const paging_mod = @import("../arch/arch.zig").paging;

    const ADDR_MASK: u64 = 0xFFFFFFFFF000;

    const child_pml4_phys = pmm_mod.allocPage() orelse return null;
    const child_pml4: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pml4_phys));
    @memset(child_pml4[0..512], 0);

    const kernel_pml4_phys = paging_mod.getKernelPml4();
    const kernel_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(kernel_pml4_phys));
    for (256..512) |i| {
        child_pml4[i] = kernel_pml4[i];
    }

    const parent_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pml4_phys));

    for (0..256) |pml4_idx| {
        const pml4e = parent_pml4[pml4_idx];
        if (pml4e == 0) continue;
        if (pml4e & 1 == 0) continue;

        const parent_pdpt_phys = pml4e & ADDR_MASK;
        const child_pdpt_phys = pmm_mod.allocPage() orelse return abortCloneRoot(child_pml4_phys);
        const child_pdpt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pdpt_phys));
        @memset(child_pdpt[0..512], 0);
        child_pml4[pml4_idx] = child_pdpt_phys | 0x07;

        const parent_pdpt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pdpt_phys));

        for (0..512) |pdpt_idx| {
            const pdpte = parent_pdpt[pdpt_idx];
            if (pdpte == 0) continue;
            if (pdpte & 1 == 0) continue;

            const parent_pd_phys = pdpte & ADDR_MASK;
            const child_pd_phys = pmm_mod.allocPage() orelse return abortCloneRoot(child_pml4_phys);
            const child_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pd_phys));
            @memset(child_pd[0..512], 0);
            child_pdpt[pdpt_idx] = child_pd_phys | 0x07;

            const parent_pd: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pd_phys));

            for (0..512) |pd_idx| {
                const pde = parent_pd[pd_idx];
                if (pde == 0) continue;
                if (pde & 1 == 0) continue;

                const parent_pt_phys = pde & ADDR_MASK;
                const child_pt_phys = pmm_mod.allocPage() orelse return abortCloneRoot(child_pml4_phys);
                const child_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pt_phys));
                @memset(child_pt[0..512], 0);
                child_pd[pd_idx] = child_pt_phys | 0x07;

                const parent_pt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pt_phys));

                for (0..512) |pt_idx| {
                    const pte = parent_pt[pt_idx];
                    if (pte == 0) continue;
                    if (pte & 1 == 0) continue;

                    const src_phys = pte & ADDR_MASK;
                    const dst_phys = pmm_mod.allocPage() orelse return abortCloneRoot(child_pml4_phys);

                    const src: [*]const u8 = @ptrFromInt(hhdm_mod.physToVirt(src_phys));
                    const dst: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(dst_phys));
                    @memcpy(dst[0..4096], src[0..4096]);

                    const flags = pte & 0xFFF;
                    child_pt[pt_idx] = dst_phys | flags;
                }
            }
        }
    }

    return child_pml4_phys;
}

/// Release a half-built child address space and report the clone as failed.
///
/// Running out of memory partway through the walk used to abandon every table
/// and leaf page allocated so far. `destroyUserSpace` walks from the root and
/// skips zero entries, so it handles a partial tree, and its batched page frees
/// also undo the COW `addRefBatch` increments on shared pages.
fn abortCloneRoot(child_pml4_phys: u64) ?u64 {
    @import("../mm/user_space.zig").destroyUserSpace(child_pml4_phys);
    return null;
}

/// COW (Copy-on-Write) fork: share physical pages between parent and child.
/// Instead of allocating + copying 4KB per page, both processes share the same
/// physical page marked read-only with COW bit. The #PF handler (handleCowFault
/// in idt.zig) allocates a private copy on first write.
/// This makes fork() O(page-table-entries) instead of O(total-pages * 4KB).
pub fn cloneUserPagesCow(parent_pml4_phys: u64) ?u64 {
    const pmm_mod = @import("../mm/pmm.zig");
    const hhdm_mod = @import("../mm/hhdm.zig");
    const paging_mod = @import("../arch/arch.zig").paging;

    const ADDR_MASK: u64 = 0xFFFFFFFFF000;
    const cow_pte_mod = @import("../mm/cow_pte.zig");

    const child_pml4_phys = pmm_mod.allocPage() orelse return null;
    const child_pml4: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pml4_phys));
    @memset(child_pml4[0..512], 0);

    // Copy kernel page table entries (upper half, entries 256..511)
    const kernel_pml4_phys = paging_mod.getKernelPml4();
    const kernel_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(kernel_pml4_phys));
    for (256..512) |i| {
        child_pml4[i] = kernel_pml4[i];
    }

    const parent_pml4: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pml4_phys));

    for (0..256) |pml4_idx| {
        const pml4e = parent_pml4[pml4_idx];
        if (pml4e == 0 or pml4e & 1 == 0) continue;

        const parent_pdpt_phys = pml4e & ADDR_MASK;
        const child_pdpt_phys = pmm_mod.allocPage() orelse return abortCloneRoot(child_pml4_phys);
        const child_pdpt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pdpt_phys));
        @memset(child_pdpt[0..512], 0);
        child_pml4[pml4_idx] = child_pdpt_phys | 0x07; // present+writable+user

        const parent_pdpt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pdpt_phys));

        for (0..512) |pdpt_idx| {
            const pdpte = parent_pdpt[pdpt_idx];
            if (pdpte == 0 or pdpte & 1 == 0) continue;

            const parent_pd_phys = pdpte & ADDR_MASK;
            const child_pd_phys = pmm_mod.allocPage() orelse return abortCloneRoot(child_pml4_phys);
            const child_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pd_phys));
            @memset(child_pd[0..512], 0);
            child_pdpt[pdpt_idx] = child_pd_phys | 0x07;

            const parent_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pd_phys));

            for (0..512) |pd_idx| {
                const pde = parent_pd[pd_idx];
                if (pde == 0 or pde & 1 == 0) continue;

                const parent_pt_phys = pde & ADDR_MASK;
                const child_pt_phys = pmm_mod.allocPage() orelse return abortCloneRoot(child_pml4_phys);
                const child_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pt_phys));
                @memset(child_pt[0..512], 0);
                child_pd[pd_idx] = child_pt_phys | 0x07;

                const parent_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pt_phys));

                // v53.47: Two-pass COW — batch addRef to reduce pmm.lock acquisitions
                // from O(N) to O(N/128). For a 4MB process (~1024 pages), this
                // reduces ~1024 lock ops to ~8.
                // Pass 1: Collect physical addresses for batch ref count increment
                var cow_phys: [128]u64 = undefined;
                var cow_count: u32 = 0;
                for (0..512) |pt_idx| {
                    const pte = parent_pt[pt_idx];
                    if (pte == 0 or pte & 1 == 0) continue;
                    cow_phys[cow_count] = pte & ADDR_MASK;
                    cow_count += 1;
                    if (cow_count == 128) {
                        pmm_mod.addRefBatch(cow_phys[0..cow_count]);
                        cow_count = 0;
                    }
                }
                if (cow_count > 0) pmm_mod.addRefBatch(cow_phys[0..cow_count]);

                // Pass 2: Set PTEs (mark COW, invalidate parent TLB, copy to child)
                for (0..512) |pt_idx| {
                    const pte = parent_pt[pt_idx];
                    if (pte == 0 or pte & 1 == 0) continue;

                    // Both sides hold the same entry, so derive it once. The
                    // child's used to be rebuilt as `phys | (pte & 0xFFF)`,
                    // which dropped NX at bit 63 and handed the child an
                    // executable stack and heap.
                    const shared = cow_pte_mod.sharedPte(pte);

                    // Downgrade the parent only when the entry actually changed;
                    // an already-COW or already-read-only page keeps its entry.
                    if (shared != pte) {
                        parent_pt[pt_idx] = shared;
                        // Invalidate parent TLB for this page
                        const virt = (pml4_idx << 39) | (pdpt_idx << 30) |
                            (pd_idx << 21) | (pt_idx << 12);
                        paging_mod.invlpg(virt);
                    }

                    child_pt[pt_idx] = shared;
                }
            }
        }
    }

    return child_pml4_phys;
}
