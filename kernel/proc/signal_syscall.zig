// kernel/proc/signal_syscall.zig — Signal-related syscall implementations
//
// Extracted from syscall_entry.zig: sigaction, sigprocmask, sigreturn,
// sigaltstack, rt_sigpending, rt_sigsuspend, rt_sigtimedwait,
// rt_sigqueueinfo, pidfd_send_signal, signalfd4, signalfd, rt_tgsigqueueinfo.

const sched = @import("sched.zig");
const task_mod = @import("task.zig");
const sig_mod = @import("signal.zig");
const copy = @import("../mm/copy_from_user.zig");
const vfs_mod = @import("../fs/vfs.zig");
const bo = @import("../lib/byte_order.zig");

// Access syscall_entry globals for sigreturn
const syscall_entry = @import("../arch/arch.zig").syscall;

/// sigaction(signum, act_ptr, oldact_ptr) → 0 or -errno
pub fn sigaction(signum: u32, act_ptr: u64, oldact_ptr: u64) i64 {
    if (signum == 0 or signum > 31) return -22;

    const current = sched.currentTask() orelse return -1;
    const old_handler = current.signal_handlers[signum - 1];

    // Validate the optional output before changing the installed action.
    if (oldact_ptr != 0 and !copy.validateUserBufferWritable(oldact_ptr, 28)) return -14;
    if (act_ptr != 0 and !copy.validateUserBuffer(act_ptr, 28)) return -14;

    // Return old action if requested
    if (oldact_ptr != 0) {
        var old_buf: [28]u8 = undefined;
        @memset(&old_buf, 0);
        const handler_bytes: [*]const u8 = @ptrCast(&old_handler);
        @memcpy(old_buf[0..8], handler_bytes[0..8]);
        if (copy.copyToUser(@ptrFromInt(oldact_ptr), &old_buf, 28) != 28) return -14;
    }

    // Set new action if provided
    if (act_ptr != 0) {
        var act_buf: [28]u8 = undefined;
        const copied = copy.copyFromUser(&act_buf, @ptrFromInt(act_ptr), 28);
        if (copied != 28) return -14;
        const new_handler: u64 = @bitCast(act_buf[0..8].*);
        current.signal_handlers[signum - 1] = new_handler;
    }

    return 0;
}

/// sigprocmask(how, set_ptr, oldset_ptr) → 0 or -errno
pub fn sigprocmask(how: u32, set_ptr: u64, oldset_ptr: u64) i64 {
    const current = sched.currentTask() orelse return -1;
    const old_mask = current.signal_mask;

    if (oldset_ptr != 0 and !copy.validateUserBufferWritable(oldset_ptr, 4)) return -14;
    if (set_ptr != 0 and !copy.validateUserBuffer(set_ptr, 4)) return -14;
    if (oldset_ptr != 0 and copy.copyToUser(@ptrFromInt(oldset_ptr), @as([*]const u8, @ptrCast(&old_mask))[0..4], 4) != 4) return -14;

    if (set_ptr != 0) {
        var new_set: u32 = 0;
        const new_set_bytes: [*]u8 = @ptrCast(&new_set);
        if (copy.copyFromUser(new_set_bytes[0..4], @ptrFromInt(set_ptr), 4) != 4) return -14;

        const sigkill_mask = @as(u32, 1) << 8;
        const sigstop_mask = @as(u32, 1) << 18;
        const unblockable = sigkill_mask | sigstop_mask;

        switch (how) {
            0 => {
                current.signal_mask |= new_set;
                current.signal_mask &= ~unblockable;
            },
            1 => {
                current.signal_mask &= ~new_set;
            },
            2 => {
                current.signal_mask = new_set & ~unblockable;
            },
            else => return -22,
        }
    }

    return 0;
}

/// Sigreturn context — stores register restore info for syscall entry path.
pub const SigreturnResult = struct {
    rip: u64,
    rsp: u64,
    rflags: u64,
    rax: u64,
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

/// sigreturn() → SigreturnResult (register restore values)
/// This is special: it reads the signal frame and returns all register values
/// that need to be restored. The caller (syscall_entry) applies them.
pub fn sigreturn() ?SigreturnResult {
    const user_rsp = syscall_entry.getPerCpu().saved_user_rsp;
    // A process can reach sigreturn with an arbitrary RSP, so the frame address
    // is untrusted input. Reading it directly would fault inside the kernel on an
    // unmapped stack (fatal — there is no per-syscall recovery) and would feed
    // kernel memory straight back into user registers when RSP points high.
    const sig_frame = readSignalFrame(user_rsp) orelse return null;

    // M8-5b-1: per-CPU exec redirect for the syscall return path
    const pc = syscall_entry.getPerCpu();
    pc.exec_pending = 2;
    pc.exec_new_entry = sig_frame.rip;
    pc.exec_new_stack = sig_frame.rsp;

    return .{
        .rip = sig_frame.rip,
        .rsp = sig_frame.rsp,
        .rflags = sig_frame.rflags,
        .rax = sig_frame.rax,
        .rbx = sig_frame.rbx,
        .rcx = sig_frame.rcx,
        .rdx = sig_frame.rdx,
        .rsi = sig_frame.rsi,
        .rdi = sig_frame.rdi,
        .rbp = sig_frame.rbp,
        .r8 = sig_frame.r8,
        .r9 = sig_frame.r9,
        .r10 = sig_frame.r10,
        .r11 = sig_frame.rflags, // r11 gets rflags for sysretq
        .r12 = sig_frame.r12,
        .r13 = sig_frame.r13,
        .r14 = sig_frame.r14,
        .r15 = sig_frame.r15,
    };
}

/// Copy a signal frame out of user memory. Returns null when `addr` is not a
/// fully mapped user range.
fn readSignalFrame(addr: u64) ?sig_mod.SignalFrame {
    const size = @sizeOf(sig_mod.SignalFrame);
    if (addr == 0 or addr >= 0x0000_8000_0000_0000) return null;
    var frame: sig_mod.SignalFrame = undefined;
    const dst: [*]u8 = @ptrCast(&frame);
    const copy_mod = @import("../mm/copy_from_user.zig");
    if (copy_mod.copyFromUser(dst[0..size], @ptrFromInt(addr), size) != size) return null;
    return frame;
}

/// sigaltstack(ss_ptr, old_ss_ptr) → 0 or -errno
pub fn sigaltstack(ss_ptr: u64, old_ss_ptr: u64) i64 {
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (old_ss_ptr != 0 and !copy.validateUserBufferWritable(old_ss_ptr, 24)) return -14;
    if (ss_ptr != 0 and !copy.validateUserBuffer(ss_ptr, 24)) return -14;
    // Return old sigaltstack if requested
    if (old_ss_ptr != 0) {
        var old_ss: [24]u8 = undefined;
        @memset(&old_ss, 0);
        const sp: u64 = cur.sigaltstack_base;
        const sz: u64 = cur.sigaltstack_size;
        const flags: u32 = if (sp != 0) 0 else 2; // SS_DISABLE
        bo.writeU64Le(old_ss[0..8], sp);
        bo.writeU32Le(old_ss[8..12], flags);
        bo.writeU64Le(old_ss[16..24], sz);
        if (copy.copyToUser(@ptrFromInt(old_ss_ptr), &old_ss, 24) != 24) return -14;
    }
    // Set new sigaltstack if requested
    if (ss_ptr != 0) {
        var ss_buf: [24]u8 = undefined;
        if (copy.copyFromUser(ss_buf[0..], @ptrFromInt(ss_ptr), 24) != 24) return -14;
        const sp: u64 = bo.readU64Le(ss_buf[0..8]);
        const sz: u64 = bo.readU64Le(ss_buf[16..24]);
        cur.sigaltstack_base = sp;
        cur.sigaltstack_size = sz;
    }
    return 0;
}

/// rt_sigpending(set_ptr, sigsetsize) → 0 or -errno
pub fn rtSigpending(set_ptr: u64, sigsetsize: u64) i64 {
    _ = sigsetsize;
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (set_ptr != 0) {
        const pending: u64 = @intCast(cur.pending_signals);
        const bytes: [*]const u8 = @ptrCast(&pending);
        if (copy.copyToUser(@ptrFromInt(set_ptr), bytes[0..8], 8) != 8) return -14;
    } else {
        return -14;
    }
    return 0;
}

/// rt_sigsuspend(mask_ptr, sigsetsize) → -errno (always EINTR in simplified impl)
pub fn rtSigsuspend(mask_ptr: u64, sigsetsize: u64) i64 {
    _ = sigsetsize;
    const cur_idx = sched.currentTaskIndex() orelse return -1;
    const cur = task_mod.getTask(cur_idx) orelse return -1;

    if (mask_ptr == 0 or mask_ptr >= 0x0000_8000_0000_0000) return -14;

    var new_mask: u32 = 0;
    const mask_bytes: [*]u8 = @ptrCast(&new_mask);
    if (copy.copyFromUser(mask_bytes[0..4], @ptrFromInt(mask_ptr), 4) != 4) return -14;
    cur.signal_mask = new_mask;
    return -4; // EINTR
}

/// rt_sigtimedwait(sigset_ptr, info_ptr, timeout_ptr, sigset_size) → signal number or -errno
pub fn rtSigtimedwait(sigset_ptr: u64, info_ptr: u64, timeout_ptr: u64, sigset_size: u64) i64 {
    _ = info_ptr;
    _ = timeout_ptr;

    if (sigset_size == 0 or sigset_ptr == 0 or sigset_ptr >= 0x0000_8000_0000_0000) return -22;

    var mask_buf: [8]u8 = undefined;
    const copied = copy.copyFromUser(mask_buf[0..], @ptrFromInt(sigset_ptr), @min(sigset_size, @as(u64, 4)));
    if (copied == 0) return -14;
    const mask: u32 = @as(u32, @bitCast(mask_buf[0..4].*));

    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = task_mod.getTask(cur_idx) orelse return -3;

    const pending = cur.pending_signals & mask;
    if (pending != 0) {
        const sig = @ctz(pending) + 1;
        cur.pending_signals &= ~(@as(u32, 1) << @intCast(sig - 1));
        return @intCast(sig);
    }
    return -11; // EAGAIN
}

/// rt_sigqueueinfo(tgid, sig, uinfo_ptr) → 0 or -errno
pub fn rtSigqueueinfo(tgid: u32, sig: u32, uinfo_ptr: u64) i64 {
    _ = uinfo_ptr;
    if (sig == 0 or sig > 64) return -22;
    if (sig_mod.sendSignal(tgid, sig)) return 0;
    return -3; // ESRCH
}

/// tkill(tid, sig) → 0 or -errno
pub fn tkill(tid: u32, sig: u32) i64 {
    if (sig == 0 or sig > 64) return -22;
    if (sig_mod.sendSignal(tid, sig)) return 0;
    return -3; // ESRCH
}

/// pidfd_send_signal(pidfd, sig, info_ptr, flags) → 0 or -errno
pub fn pidfdSendSignal(pidfd: u32, sig: u32, info_ptr: u64, flags: u32) i64 {
    _ = info_ptr;
    _ = flags;

    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = task_mod.getTask(cur_idx) orelse return -3;

    if (pidfd >= vfs_mod.MAX_FDS) return -9;
    const desc = cur.fd_table.fds[pidfd];
    if (desc.fd_type != .proc_file) return -9;

    const target_pid: u32 = @intCast(desc.proc_pid);
    if (sig_mod.sendSignal(target_pid, sig)) return 0;
    return -3;
}

/// signalfd4(old_fd, mask, sizemask, flags) → fd or -errno
pub fn signalfd4(old_fd: u64, mask: u64, sizemask: u64, flags: u64) i64 {
    _ = mask;
    _ = sizemask;
    _ = flags;

    // If old_fd is valid, just return it
    if (old_fd != @as(u64, @bitCast(@as(i64, -1))) and old_fd < 0x0000_8000_0000_0000) {
        const cur_idx = sched.currentTaskIndex() orelse return -3;
        const cur = task_mod.getTask(cur_idx) orelse return -3;
        const fd: u32 = @intCast(old_fd);
        if (fd < vfs_mod.MAX_FDS and cur.fd_table.fds[fd].fd_type == .eventfd) {
            return @bitCast(old_fd);
        }
    }

    // Create a new eventfd-backed signalfd
    const eventfd_mod = @import("../fs/eventfd.zig");
    const efd_idx = eventfd_mod.eventfdCreate(0);
    if (efd_idx < 0) return @as(i64, efd_idx);

    const cur_idx = sched.currentTaskIndex() orelse return -3;
    const cur = task_mod.getTask(cur_idx) orelse return -3;

    const slot = cur.fd_table.allocFd() orelse return -24;
    cur.fd_table.fds[slot] = .{ .fd_type = .eventfd, .eventfd_idx = @intCast(efd_idx) };
    return @bitCast(@as(u64, slot));
}

/// rt_tgsigqueueinfo(tgid, tid, sig, uinfo) → 0 or -errno
pub fn rtTgsigqueueinfo(tgid: u32, tid: u32, sig: u32, uinfo: u64) i64 {
    _ = tid;
    return rtSigqueueinfo(tgid, sig, uinfo);
}
