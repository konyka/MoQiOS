// kernel/arch/x86_64/clone.zig — Clone (fork/thread) subsystem
//
// Implements clone() syscall and COW page table duplication.

const serial = @import("serial.zig");
const idt = @import("idt.zig");
const sched = @import("../../proc/sched.zig");
const task_mod = @import("../../proc/task.zig");
const vfs_mod = @import("../../fs/vfs.zig");
const pmm_mod = @import("../../mm/pmm.zig");
const hhdm_mod = @import("../../mm/hhdm.zig");
const paging_mod = @import("paging.zig");
const getPerCpu = @import("syscall_entry.zig").getPerCpu;
const wrmsr = @import("syscall_entry.zig").wrmsr;
const fmt = @import("../../lib/fmt.zig");

// ── CLONE flags ──────────────────────────────────────────────────────
const CLONE_VM: u64 = 0x100;
const CLONE_FS: u64 = 0x200;
const CLONE_FILES: u64 = 0x400;
const CLONE_SIGHAND: u64 = 0x800;
const CLONE_THREAD: u64 = 0x10000;
const CLONE_SETTLS: u64 = 0x80000;
const CLONE_PARENT_SETTID: u64 = 0x100000;
const CLONE_CHILD_CLEARTID: u64 = 0x200000;

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

const COW_BIT: u64 = 1 << 9;

/// Check if a 4096-byte page is entirely zero.
fn isZeroPage(page: [*]const u8) bool {
    const words: [*]const u64 = @ptrCast(@alignCast(page));
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        if (words[i] != 0) return false;
    }
    return true;
}

/// Clone the user-space page tables with Copy-on-Write semantics.
/// Returns the physical address of the new PML4, or null on OOM.
pub fn cloneUserPages(parent_pml4_phys: u64) ?u64 {
    const ADDR_MASK: u64 = 0xFFFFFFFFF000;

    const child_pml4_phys = pmm_mod.allocPage() orelse return null;
    const child_pml4: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(child_pml4_phys));
    @memset(child_pml4[0..512], 0);

    const kernel_pml4_phys = paging_mod.getKernelPml4();
    const kernel_pml4: [*]const u64 = @ptrFromInt(hhdm_mod.physToVirt(kernel_pml4_phys));
    for (256..512) |i| {
        child_pml4[i] = kernel_pml4[i];
    }

    const parent_pml4: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pml4_phys));

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

                const parent_pt: [*]u64 = @ptrFromInt(hhdm_mod.physToVirt(parent_pt_phys));

                for (0..512) |pt_idx| {
                    const pte = parent_pt[pt_idx];
                    if (pte == 0) continue;
                    if (pte & 1 == 0) continue;

                    const src_phys = pte & ADDR_MASK;

                    const src: [*]const u8 = @ptrFromInt(hhdm_mod.physToVirt(src_phys));
                    if (isZeroPage(src)) continue;

                    pmm_mod.addRef(src_phys);
                    parent_pt[pt_idx] = (pte & ~@as(u64, paging_mod.WRITABLE)) | COW_BIT;

                    const flags = pte & 0xFFF;
                    child_pt[pt_idx] = src_phys | (flags & ~@as(u64, paging_mod.WRITABLE)) | COW_BIT;
                }
            }
        }
    }

    paging_mod.reloadCR3();
    return child_pml4_phys;
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
    const parent_idx = sched.currentTaskIndex() orelse return -1;
    const parent = task_mod.getTask(parent_idx) orelse return -1;

    // CLONE_VM: share address space (thread) vs COW copy (process)
    const child_pml4 = if (flags & CLONE_VM != 0)
        parent.page_table_phys
    else
        cloneUserPages(parent.page_table_phys) orelse return -12; // ENOMEM

    const child_idx = task_mod.createUserProcess(
        parent.user_entry,
        if (new_stack != 0) new_stack else parent.user_stack_top,
        child_pml4,
        parent.tid,
        false, // inherit general affinity
    ) orelse {
        if (flags & CLONE_VM == 0) {
            @import("../../mm/user_space.zig").destroyUserSpace(child_pml4);
        }
        return -12;
    };
    const child = task_mod.getTask(child_idx).?;

    child.brk_current = parent.brk_current;
    child.stack_limit = parent.stack_limit;

    // CLONE_FILES: share fd table (currently always copies)
    // v53.50: Copy free_bm bitmap — child inherits parent's fd occupancy state.
    child.fd_table.free_bm = parent.fd_table.free_bm;
    for (0..vfs_mod.MAX_FDS) |i| {
        child.fd_table.fds[i] = parent.fd_table.fds[i];
        if (child.fd_table.fds[i].fd_type == .pipe_read or child.fd_table.fds[i].fd_type == .pipe_write) {
            const pidx = child.fd_table.fds[i].pipe_idx;
            if (pidx < 16) {
                vfs_mod.pipes[pidx].ref_count += 1;
            }
        }
    }

    // Signal handlers, mask, environment, cwd, pgid, sid
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
    child.pgid = parent.pgid;
    child.sid = parent.sid;
    // Inherit credentials
    child.uid = parent.uid;
    child.gid = parent.gid;
    child.euid = parent.euid;
    child.egid = parent.egid;
    child.suid = parent.suid;
    child.sgid = parent.sgid;

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

    // CLONE_SETTLS: set FS_BASE for TLS
    if (flags & CLONE_SETTLS != 0 and tls != 0) {
        wrmsr(0xC0000100, tls);
    }

    _ = parent_tid_ptr;
    _ = child_tid_ptr;

    serial.writeString("[clone] parent=");
    fmt.writeDecimal(parent.tid);
    serial.writeString(" child=");
    fmt.writeDecimal(child.tid);
    if (flags & CLONE_VM != 0) serial.writeString(" VM");
    if (flags & CLONE_THREAD != 0) serial.writeString(" THREAD");
    serial.writeString("\n");

    return @intCast(child.tid);
}
