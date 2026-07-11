const serial = @import("../arch/arch.zig").serial;
const syscall_entry = @import("../arch/x86_64/syscall_entry.zig");
const getPerCpu = syscall_entry.getPerCpu;
const idt = @import("../arch/x86_64/idt.zig");

/// Prepare execve: load program, destroy old address space, set up new context.
/// Returns the frame address for iretq tail, or null if loading fails (before destroying old AS).
pub fn prepareExec(name_ptr: u64, argv_ptr: u64) ?u64 {
    if (name_ptr == 0 or name_ptr >= 0x0000_8000_0000_0000) return null;

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

    // Build argv array from user-space argv pointer
    var argv_buffers: [16][128]u8 = undefined;
    var argv_slices: [16][]const u8 = undefined;
    var argc: usize = 1;
    argv_slices[0] = name;

    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        for (1..16) |i| {
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

    // Load the new program — if this fails, old address space is intact, caller can return error
    const loader = @import("loader.zig");
    const result = loader.loadProgramForExec(name, argv_slices[0..argc]) orelse {
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

    if (cur.page_table_phys != 0) {
        user_space.destroyUserSpace(cur.page_table_phys);
    }

    cur.page_table_phys = result.pml4;
    cur.user_entry = result.entry;
    cur.user_stack_top = result.stack_top;
    cur.brk_current = result.brk;

    // Switch to new address space
    asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
        :
        : [cr3] "r" (result.pml4),
        : .{ .rax = true, .memory = true });
    @import("../arch/x86_64/gdt.zig").setRsp0(getPerCpu().cpu_id, cur.kernel_stack_top);
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
pub fn prepareExecWithKernelPath(name: []const u8, argv_ptr: u64) ?u64 {
    const copy = @import("../mm/copy_from_user.zig");

    serial.writeString("[execveat] loading '");
    serial.writeString(name);
    serial.writeString("'\n");

    // Build argv array from user-space argv pointer
    var argv_buffers: [16][128]u8 = undefined;
    var argv_slices: [16][]const u8 = undefined;
    var argc: usize = 1;
    argv_slices[0] = name;

    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        for (1..16) |i| {
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

    const loader = @import("loader.zig");
    const result = loader.loadProgramForExec(name, argv_slices[0..argc]) orelse {
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

    if (cur.page_table_phys != 0) {
        user_space.destroyUserSpace(cur.page_table_phys);
    }

    cur.page_table_phys = result.pml4;
    cur.user_entry = result.entry;
    cur.user_stack_top = result.stack_top;
    cur.brk_current = result.brk;

    asm volatile ("movq %[cr3], %%rax\n\tmovq %%rax, %%cr3"
        :
        : [cr3] "r" (result.pml4),
        : .{ .rax = true, .memory = true });
    @import("../arch/x86_64/gdt.zig").setRsp0(getPerCpu().cpu_id, cur.kernel_stack_top);
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
