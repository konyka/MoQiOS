const syscall_entry = @import("../arch/x86_64/syscall_entry.zig");
const SyscallFrame = syscall_entry.SyscallFrame;
const getPerCpu = syscall_entry.getPerCpu;
const serial = @import("../arch/x86_64/serial.zig");
const idt = @import("../arch/x86_64/idt.zig");
const fmt = @import("../lib/fmt.zig");

/// Syscall #57: fork() — clone the current process.
/// Returns child TID to parent, -1 on error.
pub fn fork(frame: *SyscallFrame) i64 {
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const vfs_mod = @import("../fs/vfs.zig");

    const parent_idx = sched.currentTaskIndex() orelse return -1;
    const parent = task_mod.getTask(parent_idx) orelse return -1;

    const child_pml4 = cloneUserPages(parent.page_table_phys) orelse return -1;

    const child_idx = task_mod.createUserProcess(
        parent.user_entry,
        parent.user_stack_top,
        child_pml4,
        parent.tid,
        true,
    ) orelse return -1;
    const child = task_mod.getTask(child_idx).?;

    // Inherit parent's CPU pin — fork must not migrate (M8-5b-2).
    child.cpu_affinity = parent.cpu_affinity;

    child.brk_current = parent.brk_current;

    for (0..vfs_mod.MAX_FDS) |i| {
        child.fd_table.fds[i] = parent.fd_table.fds[i];
        if (child.fd_table.fds[i].fd_type == .pipe_read or child.fd_table.fds[i].fd_type == .pipe_write) {
            const pidx = child.fd_table.fds[i].pipe_idx;
            if (pidx < 16) {
                vfs_mod.pipes[pidx].ref_count += 1;
            }
        }
    }

    for (0..31) |i| {
        child.signal_handlers[i] = parent.signal_handlers[i];
    }
    child.signal_mask = parent.signal_mask;
    child.env_count = parent.env_count;
    for (0..parent.env_count) |i| {
        @memcpy(child.env_vars[i][0..128], parent.env_vars[i][0..128]);
    }
    @memcpy(child.cwd[0..256], parent.cwd[0..256]);
    child.cwd_len = parent.cwd_len;

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
    const paging_mod = @import("../arch/x86_64/paging.zig");

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
        const child_pdpt_phys = pmm_mod.allocPage() orelse return null;
        const child_pdpt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pdpt_phys));
        @memset(child_pdpt[0..512], 0);
        child_pml4[pml4_idx] = child_pdpt_phys | 0x07;

        const parent_pdpt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pdpt_phys));

        for (0..512) |pdpt_idx| {
            const pdpte = parent_pdpt[pdpt_idx];
            if (pdpte == 0) continue;
            if (pdpte & 1 == 0) continue;

            const parent_pd_phys = pdpte & ADDR_MASK;
            const child_pd_phys = pmm_mod.allocPage() orelse return null;
            const child_pd: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pd_phys));
            @memset(child_pd[0..512], 0);
            child_pdpt[pdpt_idx] = child_pd_phys | 0x07;

            const parent_pd: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pd_phys));

            for (0..512) |pd_idx| {
                const pde = parent_pd[pd_idx];
                if (pde == 0) continue;
                if (pde & 1 == 0) continue;

                const parent_pt_phys = pde & ADDR_MASK;
                const child_pt_phys = pmm_mod.allocPage() orelse return null;
                const child_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pt_phys));
                @memset(child_pt[0..512], 0);
                child_pd[pd_idx] = child_pt_phys | 0x07;

                const parent_pt: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pt_phys));

                for (0..512) |pt_idx| {
                    const pte = parent_pt[pt_idx];
                    if (pte == 0) continue;
                    if (pte & 1 == 0) continue;

                    const src_phys = pte & ADDR_MASK;
                    const dst_phys = pmm_mod.allocPage() orelse return null;

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
