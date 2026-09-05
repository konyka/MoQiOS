const serial = @import("../arch/arch.zig").serial;
const syscall_entry = @import("../arch/arch.zig").syscall;
const getPerCpu = syscall_entry.getPerCpu;
const idt = @import("../arch/arch.zig").interrupts;

/// Prepare execve: load program, destroy old address space, set up new context.
/// Returns the frame address for iretq tail, or null if loading fails (before destroying old AS).
pub fn prepareExec(name_ptr: u64, argv_ptr: u64, envp_ptr: u64) ?u64 {
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return null;

    // The old image cannot be destroyed while SHM attachment records still
    // point at it. Reject exec before loading the replacement image; the
    // syscall wrapper reports this as EPERM and leaves the old image intact.
    if (hasShmAttachments()) return null;

    var name_buf: [64]u8 = undefined;
    const copy = @import("../mm/copy_from_user.zig");
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(name_ptr), 63);
    if (copied == 0) return null;
    name_buf[if (copied < 63) copied else 63] = 0;
    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    serial.writeString("[execve] loading '");
    serial.writeString(name);
    serial.writeString("'\n");

    // Build argv array from user-space argv pointer.
    // Linux semantics: the caller's argv is authoritative — their argv[0] is
    // the program's argv[0]. Only fall back to the resolved path when the
    // caller supplied an empty/absent argv.
    var argv_buffers: [16][128]u8 = undefined;
    var argv_slices: [16][]const u8 = undefined;
    var argc: usize = 0;

    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        for (0..16) |i| {
            var ptr_bytes: [8]u8 = undefined;
            const pc = copy.copyFromUser(ptr_bytes[0..], @ptrFromInt(argv_ptr + i * 8), 8);
            if (pc < 8) break;
            const arg_ptr: u64 = @bitCast(ptr_bytes);
            if (arg_ptr == 0 or arg_ptr >= 0x0000_8000_0000_0000) break;
            const ac = copy.copyFromUser(argv_buffers[i][0..], @ptrFromInt(arg_ptr), 127);
            if (ac == 0) break;
            argv_buffers[i][if (ac < 127) ac else 127] = 0;
            var al: usize = 0;
            while (al < ac and argv_buffers[i][al] != 0) : (al += 1) {}
            argv_slices[i] = argv_buffers[i][0..al];
            argc = i + 1;
        }
    }
    if (argc == 0) {
        argv_slices[0] = name;
        argc = 1;
    }

    // Build envp array from user-space envp pointer (same rules as argv:
    // caller's envp is authoritative; absent envp means an empty environment).
    var envp_buffers: [16][128]u8 = undefined;
    var envp_slices: [16][]const u8 = undefined;
    var envc: usize = 0;

    if (envp_ptr != 0 and envp_ptr < 0x0000_8000_0000_0000) {
        for (0..16) |i| {
            var ptr_bytes: [8]u8 = undefined;
            const pc = copy.copyFromUser(ptr_bytes[0..], @ptrFromInt(envp_ptr + i * 8), 8);
            if (pc < 8) break;
            const env_ptr: u64 = @bitCast(ptr_bytes);
            if (env_ptr == 0 or env_ptr >= 0x0000_8000_0000_0000) break;
            const ec = copy.copyFromUser(envp_buffers[i][0..], @ptrFromInt(env_ptr), 127);
            if (ec == 0) break;
            envp_buffers[i][if (ec < 127) ec else 127] = 0;
            var el: usize = 0;
            while (el < ec and envp_buffers[i][el] != 0) : (el += 1) {}
            envp_slices[i] = envp_buffers[i][0..el];
            envc = i + 1;
        }
    }

    // Load the new program — if this fails, old address space is intact, caller can return error
    const loader = @import("loader.zig");
    const result = loader.loadProgramForExec(name, argv_slices[0..argc], envp_slices[0..envc]) orelse {
        serial.writeString("[execve] failed\n");
        return null;
    };

    // From here on, we're committed — destroy old address space and switch
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const user_space = @import("../mm/user_space.zig");
    const cur_idx = sched.currentTaskIndex() orelse return null;
    const cur = task_mod.getTask(cur_idx) orelse return null;

    // v53.44: Close FD_CLOEXEC file descriptors before destroying old address space.
    // POSIX requires exec to auto-close FDs with O_CLOEXEC/FD_CLOEXEC flag.
    {
        const vfs_mod = @import("../fs/vfs.zig");
        const fcntl_mod = @import("../fs/fcntl.zig");
        for (0..vfs_mod.MAX_FDS) |i| {
            if (cur.fd_table.fds[i].fd_type != .none and
                (cur.fd_table.fds[i].fd_flags & fcntl_mod.FD_CLOEXEC) != 0)
            {
                _ = cur.fd_table.close(@intCast(i));
            }
        }
    }

    const lock_flags = task_mod.lockTask();
    const old_pml4 = cur.page_table_phys;
    cur.page_table_phys = result.pml4;
    task_mod.unlockTask(lock_flags);
    cur.user_entry = result.entry;
    cur.user_stack_top = result.stack_top;
    // RLIMIT_STACK is preserved across exec (like NOFILE), but the growth
    // watermark belongs to the old image — reset it so a deep inherited
    // watermark cannot bypass the limit's floor in the fresh image.
    cur.stack_limit = @import("rlimit.zig").Policy.initialStackLimit(
        result.stack_top,
        @import("../mm/user_space.zig").USER_STACK_BOTTOM,
        cur.stack_cur,
    );
    // RLIMIT_AS limits are preserved, but every charged byte belonged to the
    // replaced image — the fresh image starts uncharged (see docs/rlimit.md).
    cur.as_used = 0;
    cur.data_used = 0;
    cur.brk_current = result.brk;
    cur.brk_start = result.brk;
    // The old TLS block belonged to the replaced image. Program the CPU too:
    // execve returns straight to user space without passing through the
    // scheduler, so the stale base would otherwise survive into the new image.
    cur.tls_base = 0;
    syscall_entry.setUserTlsBase(0);

    // Switch to new address space
    @import("../arch/arch.zig").pcid.switchCr3(result.pml4);
    // L1: the old image's user-driver resources (IRQ registrations, DMA
    // buffers, MMIO mappings) die with it, before the address-space walk.
    // cur.page_table_phys already points at the NEW space — pass the old one.
    @import("../drivers/userdrv.zig").cleanupTask(cur, old_pml4);
    // fb0: the old image's framebuffer mappings die with it — drop their
    // registry entries (restores the console mirror when none remain).
    @import("../drivers/fbdev.zig").cleanupTask(cur);
    // G2: the old image's file mappings die with it — release their backing
    // refs (ext2 open slots) and clear the stale region table before the old
    // address space is destroyed.
    @import("../mm/mmap.zig").releaseFileRefs(cur);
    if (old_pml4 != 0) user_space.destroyUserSpace(old_pml4);
    @import("../arch/arch.zig").gdt.setRsp0(getPerCpu().cpu_id, cur.kernel_stack_top);
    // ioperm: pair every per-switch RSP0 update with the IOPB load.
    @import("ioperm.zig").loadForTask(getPerCpu().cpu_id, cur);
    getPerCpu().kernel_rsp = cur.kernel_stack_top;

    // Build interrupt frame for new program
    const stack_top = cur.kernel_stack_top;
    const frame_addr = stack_top - @sizeOf(idt.InterruptFrame);
    const new_frame: *idt.InterruptFrame = @ptrFromInt(frame_addr);
    const bytes: [*]u8 = @ptrCast(new_frame);
    @memset(bytes[0..@sizeOf(idt.InterruptFrame)], 0);

    new_frame.rip = result.entry;
    new_frame.cs = 0x1B;
    new_frame.rflags = 0x202;
    new_frame.rsp = result.stack_top;
    new_frame.ss = 0x23;
    new_frame.vector = 0;
    new_frame.error_code = 0;

    cur.saved_rsp = frame_addr;
    cur.started = true;
    cur.saved_user_rsp = result.stack_top;

    getPerCpu().saved_user_rsp = result.stack_top;
    sched.setAnchor(frame_addr);

    return frame_addr;
}

/// v52.0: Variant of prepareExec that takes a kernel-space path directly.
/// Used by execveat with non-AT_FDCWD dirfd where the combined path is
/// already resolved in kernel memory.
pub fn prepareExecWithKernelPath(name: []const u8, argv_ptr: u64, envp_ptr: u64) ?u64 {
    const copy = @import("../mm/copy_from_user.zig");

    // Keep execveat consistent with execve: attachment cleanup must happen
    // before an address-space replacement, or the SHM records become stale.
    if (hasShmAttachments()) return null;

    serial.writeString("[execveat] loading '");
    serial.writeString(name);
    serial.writeString("'\n");

    // Build argv array from user-space argv pointer.
    // Linux semantics: the caller's argv is authoritative — their argv[0] is
    // the program's argv[0]. Only fall back to the resolved path when the
    // caller supplied an empty/absent argv.
    var argv_buffers: [16][128]u8 = undefined;
    var argv_slices: [16][]const u8 = undefined;
    var argc: usize = 0;

    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        for (0..16) |i| {
            var ptr_bytes: [8]u8 = undefined;
            const pc = copy.copyFromUser(ptr_bytes[0..], @ptrFromInt(argv_ptr + i * 8), 8);
            if (pc < 8) break;
            const arg_ptr: u64 = @bitCast(ptr_bytes);
            if (arg_ptr == 0 or arg_ptr >= 0x0000_8000_0000_0000) break;
            const ac = copy.copyFromUser(argv_buffers[i][0..], @ptrFromInt(arg_ptr), 127);
            if (ac == 0) break;
            argv_buffers[i][if (ac < 127) ac else 127] = 0;
            var al: usize = 0;
            while (al < ac and argv_buffers[i][al] != 0) : (al += 1) {}
            argv_slices[i] = argv_buffers[i][0..al];
            argc = i + 1;
        }
    }
    if (argc == 0) {
        argv_slices[0] = name;
        argc = 1;
    }

    // Build envp array from user-space envp pointer (same rules as argv:
    // caller's envp is authoritative; absent envp means an empty environment).
    var envp_buffers: [16][128]u8 = undefined;
    var envp_slices: [16][]const u8 = undefined;
    var envc: usize = 0;

    if (envp_ptr != 0 and envp_ptr < 0x0000_8000_0000_0000) {
        for (0..16) |i| {
            var ptr_bytes: [8]u8 = undefined;
            const pc = copy.copyFromUser(ptr_bytes[0..], @ptrFromInt(envp_ptr + i * 8), 8);
            if (pc < 8) break;
            const env_ptr: u64 = @bitCast(ptr_bytes);
            if (env_ptr == 0 or env_ptr >= 0x0000_8000_0000_0000) break;
            const ec = copy.copyFromUser(envp_buffers[i][0..], @ptrFromInt(env_ptr), 127);
            if (ec == 0) break;
            envp_buffers[i][if (ec < 127) ec else 127] = 0;
            var el: usize = 0;
            while (el < ec and envp_buffers[i][el] != 0) : (el += 1) {}
            envp_slices[i] = envp_buffers[i][0..el];
            envc = i + 1;
        }
    }

    const loader = @import("loader.zig");
    const result = loader.loadProgramForExec(name, argv_slices[0..argc], envp_slices[0..envc]) orelse {
        serial.writeString("[execveat] failed\n");
        return null;
    };

    // Committed — destroy old address space and switch
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const user_space = @import("../mm/user_space.zig");
    const cur_idx = sched.currentTaskIndex() orelse return null;
    const cur = task_mod.getTask(cur_idx) orelse return null;

    // v53.44: Close FD_CLOEXEC file descriptors before destroying old address space.
    {
        const vfs_mod = @import("../fs/vfs.zig");
        const fcntl_mod = @import("../fs/fcntl.zig");
        for (0..vfs_mod.MAX_FDS) |i| {
            if (cur.fd_table.fds[i].fd_type != .none and
                (cur.fd_table.fds[i].fd_flags & fcntl_mod.FD_CLOEXEC) != 0)
            {
                _ = cur.fd_table.close(@intCast(i));
            }
        }
    }

    const lock_flags = task_mod.lockTask();
    const old_pml4 = cur.page_table_phys;
    cur.page_table_phys = result.pml4;
    task_mod.unlockTask(lock_flags);
    cur.user_entry = result.entry;
    cur.user_stack_top = result.stack_top;
    // RLIMIT_STACK preserved across exec; watermark resets for the new image.
    cur.stack_limit = @import("rlimit.zig").Policy.initialStackLimit(
        result.stack_top,
        @import("../mm/user_space.zig").USER_STACK_BOTTOM,
        cur.stack_cur,
    );
    // RLIMIT_AS limits are preserved, but every charged byte belonged to the
    // replaced image — the fresh image starts uncharged (see docs/rlimit.md).
    cur.as_used = 0;
    cur.data_used = 0;
    cur.brk_current = result.brk;
    cur.brk_start = result.brk;
    // The old TLS block belonged to the replaced image. Program the CPU too:
    // execve returns straight to user space without passing through the
    // scheduler, so the stale base would otherwise survive into the new image.
    cur.tls_base = 0;
    syscall_entry.setUserTlsBase(0);

    @import("../arch/arch.zig").pcid.switchCr3(result.pml4);
    // L1: the old image's user-driver resources (IRQ registrations, DMA
    // buffers, MMIO mappings) die with it — cur.page_table_phys already
    // points at the NEW space, so pass the old one explicitly.
    @import("../drivers/userdrv.zig").cleanupTask(cur, old_pml4);
    // fb0: the old image's framebuffer mappings die with it — drop their
    // registry entries (restores the console mirror when none remain).
    @import("../drivers/fbdev.zig").cleanupTask(cur);
    // G2: the old image's file mappings die with it — release their backing
    // refs (ext2 open slots) and clear the stale region table before the old
    // address space is destroyed.
    @import("../mm/mmap.zig").releaseFileRefs(cur);
    if (old_pml4 != 0) user_space.destroyUserSpace(old_pml4);
    @import("../arch/arch.zig").gdt.setRsp0(getPerCpu().cpu_id, cur.kernel_stack_top);
    // ioperm: pair every per-switch RSP0 update with the IOPB load.
    @import("ioperm.zig").loadForTask(getPerCpu().cpu_id, cur);
    getPerCpu().kernel_rsp = cur.kernel_stack_top;

    const stack_top = cur.kernel_stack_top;
    const frame_addr = stack_top - @sizeOf(idt.InterruptFrame);
    const new_frame: *idt.InterruptFrame = @ptrFromInt(frame_addr);
    const bytes: [*]u8 = @ptrCast(new_frame);
    @memset(bytes[0..@sizeOf(idt.InterruptFrame)], 0);

    new_frame.rip = result.entry;
    new_frame.cs = 0x1B;
    new_frame.rflags = 0x202;
    new_frame.rsp = result.stack_top;
    new_frame.ss = 0x23;
    new_frame.vector = 0;
    new_frame.error_code = 0;

    cur.saved_rsp = frame_addr;
    cur.started = true;
    cur.saved_user_rsp = result.stack_top;

    getPerCpu().saved_user_rsp = result.stack_top;
    sched.setAnchor(frame_addr);

    return frame_addr;
}

fn hasShmAttachments() bool {
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const shm = @import("../ipc/sysv_shm.zig");
    const idx = sched.currentTaskIndex() orelse return false;
    const cur = task_mod.getTask(idx) orelse return false;
    return shm.hasAttachments(cur.tid);
}
