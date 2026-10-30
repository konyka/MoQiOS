const serial = @import("../arch/arch.zig").serial;
const syscall_entry = @import("../arch/arch.zig").syscall;
const getPerCpu = syscall_entry.getPerCpu;
const idt = @import("../arch/arch.zig").interrupts;
const lifecycle_policy = @import("../mm/lifecycle_policy.zig");

/// Stage 1 rejects exec from a CLONE_THREAD task because siblings still use
/// the current address space. Also rejects exec on any shared (CLONE_VM,
/// refs > 1) Mm: teardown would race siblings still running in it.
/// The syscall wrapper reports this as EPERM.
pub fn threadedExecDenied() bool {
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const cur_idx = sched.currentTaskIndex() orelse return false;
    const cur = task_mod.getTask(cur_idx) orelse return false;
    const mm_shared = if (cur.mm) |m| m.isShared() else false;
    return lifecycle_policy.execResult(cur.is_thread, mm_shared) != 0;
}

pub const Prepared = union(enum) {
    /// Interrupt-frame address for the iretq tail into the new image.
    frame: u64,
    /// Negative errno; the old image is untouched.
    err: i64,
};

/// execve(name_ptr, argv, envp): copy the path and resolve it against the
/// working directory, then exec it (see prepareExecName).
pub fn prepareExec(name_ptr: u64, argv_ptr: u64, envp_ptr: u64) Prepared {
    return prepareExecAt(-100, name_ptr, argv_ptr, envp_ptr, 0);
}

/// execve/execveat. `dirfd` and the relative name resolve through at_path
/// like every other *at() call; AT_EMPTY_PATH with an empty name is ENOENT
/// (no program is ever opened as a descriptor: they live on the ramdisk).
pub fn prepareExecAt(dirfd: i64, name_ptr: u64, argv_ptr: u64, envp_ptr: u64, flags: u32) Prepared {
    const policy = @import("exec_policy.zig");
    const fl = policy.checkAtFlags(flags);
    if (fl != 0) return .{ .err = fl };
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return .{ .err = policy.errno(.fault) };
    const copy = @import("../mm/copy_from_user.zig");
    var raw: [256]u8 = undefined;
    const n = copy.copyPathFromUser(raw[0..], name_ptr, 255);
    const len = switch (@import("../fs/namespace_policy.zig").pathFromCopy(raw[0..], n, 255)) {
        .ok => |p| p.len,
        .err => |e| return .{ .err = e },
    };
    var joined: [256]u8 = undefined;
    const resolved = switch (@import("../fs/dirfd_name.zig").resolve(dirfd, raw[0..len], &joined)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    const name = switch (policy.programName(resolved)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    return prepareExecName(name, argv_ptr, envp_ptr);
}

/// Load ramdisk program `name` and switch the current task to it. Failures
/// before the commit point leave the old image intact and report an errno.
pub fn prepareExecName(name: []const u8, argv_ptr: u64, envp_ptr: u64) Prepared {
    const policy = @import("exec_policy.zig");
    if (threadedExecDenied()) return .{ .err = policy.errno(.denied) };

    // The old image cannot be destroyed while SHM attachment records still
    // point at it. Reject exec before loading the replacement image; the
    // old image stays intact.
    if (hasShmAttachments()) return .{ .err = policy.errno(.denied) };

    const ramdisk = @import("../fs/ramdisk.zig");
    const file = ramdisk.findFile(name) orelse return .{ .err = policy.errno(.not_found) };
    if (@import("elf.zig").parseHeader(file.data, file.size) == null) return .{ .err = policy.errno(.bad_format) };
    const copy = @import("../mm/copy_from_user.zig");

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
            const al = copy.copyStringFromUser(argv_buffers[i][0..127], arg_ptr) orelse break;
            argv_buffers[i][al] = 0;
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
            const el = copy.copyStringFromUser(envp_buffers[i][0..127], env_ptr) orelse break;
            envp_buffers[i][el] = 0;
            envp_slices[i] = envp_buffers[i][0..el];
            envc = i + 1;
        }
    }

    // Load the new program — if this fails, old address space is intact, caller can return error
    const loader = @import("loader.zig");
    const result = loader.loadProgramForExec(name, argv_slices[0..argc], envp_slices[0..envc]) orelse {
        serial.writeString("[execve] failed\n");
        return .{ .err = policy.errno(.no_memory) };
    };

    // From here on, we're committed — destroy old address space and switch
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const user_space = @import("../mm/user_space.zig");
    const cur_idx = sched.currentTaskIndex() orelse {
        user_space.destroyUserSpace(result.pml4);
        return .{ .err = policy.errno(.denied) };
    };
    const cur = task_mod.getTask(cur_idx) orelse {
        user_space.destroyUserSpace(result.pml4);
        return .{ .err = policy.errno(.denied) };
    };
    const new_mm = user_space.createMmForRoot(result.pml4) orelse {
        user_space.destroyUserSpace(result.pml4);
        return .{ .err = policy.errno(.no_memory) };
    };

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
    const old_mm = cur.mm;
    cur.page_table_phys = result.pml4;
    cur.mm = new_mm;
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
    commitSignalStateForExec(cur, result.pml4);
    @import("credentials.zig").applyExec(cur);

    // Switch to new address space
    if (sched.currentTaskIndex()) |task_idx| {
        @import("../ipc/posix_mq.zig").closeCloexecForTask(task_idx);
    }
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
    if (old_mm) |mm| mm.release() else if (old_pml4 != 0) user_space.destroyUserSpace(old_pml4);
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

    return .{ .frame = frame_addr };
}


/// Signal and thread state that belongs to the replaced image. Runs only
/// after the new address space is committed to `cur`, so a failed exec
/// leaves the old image's state untouched.
fn commitSignalStateForExec(cur: *@import("task.zig").Task, new_pml4: u64) void {
    const exec_policy = @import("signal_exec_policy.zig");
    // Caught signals revert to SIG_DFL (the handler addresses pointed into
    // the old image); SIG_IGN survives exec. Mask and pending set are kept.
    for (&cur.signal_handlers) |*h| h.* = exec_policy.execHandlerAfter(h.*);
    // sa_mask/sa_flags describe handlers of the old image; none survive.
    cur.signal_sa_masks = @splat(0);
    cur.signal_sa_flags = @splat(0);
    cur.sigaltstack_base = 0;
    cur.sigaltstack_size = 0;
    // CLONE_CHILD_CLEARTID address is meaningless in the new image (Linux
    // mm_release clears it on exec).
    cur.clear_tid_ptr = 0;
    // Handlers installed by the new image return through the trampoline.
    @import("signal.zig").setupSigreturnTrampoline(new_pml4);
}

fn hasShmAttachments() bool {
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");
    const shm = @import("../ipc/sysv_shm.zig");
    const idx = sched.currentTaskIndex() orelse return false;
    const cur = task_mod.getTask(idx) orelse return false;
    return shm.hasAttachments(cur.page_table_phys);
}
