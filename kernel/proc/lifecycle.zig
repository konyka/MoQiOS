const serial = @import("../arch/arch.zig").serial;
const fmt = @import("../lib/fmt.zig");

/// Syscall #2: exit(status)
pub fn exit(status: u64) void {
    const t = @import("task.zig");
    serial.writeString("[exit] task exited with code ");
    fmt.writeDecimal64(status);
    serial.writeString("\n");
    t.exitTask(@intCast(status));
}

/// Syscall #5: spawn(name_ptr) — load and start a program from ramdisk.
pub fn spawn(name_ptr: u64) i64 {
    if (name_ptr >= 0x0000_8000_0000_0000) return -1;

    var name_buf: [64]u8 = undefined;
    const copy = @import("../mm/copy_from_user.zig");
    const copied = copy.copyFromUser(name_buf[0..], @ptrFromInt(name_ptr), 63);
    if (copied == 0) return -1;
    name_buf[if (copied < 63) copied else 63] = 0;

    var len: usize = 0;
    while (len < copied and name_buf[len] != 0) : (len += 1) {}
    const name = name_buf[0..len];

    serial.writeString("[spawn] loading '");
    serial.writeString(name);
    serial.writeString("'\n");

    const loader = @import("loader.zig");
    const sched = @import("sched.zig");
    const task_mod = @import("task.zig");

    var caller_tid: u32 = 0;
    var caller_fsize_cur: u64 = @import("rlimit.zig").RLIM_INFINITY;
    var caller_fsize_max: u64 = @import("rlimit.zig").RLIM_INFINITY;
    if (sched.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |cur| {
            caller_tid = cur.tid;
            caller_fsize_cur = cur.fSize_cur;
            caller_fsize_max = cur.fSize_max;
        }
    }

    var initial_init_caller = false;
    if (sched.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |cur| initial_init_caller = cur.initial_init;
    }

    // RLIMIT_NPROC preflight: the spawned program counts against the
    // caller's real UID. Gate before any loader/address-space work so a
    // denied spawn costs nothing and leaks nothing. EAGAIN matches Linux.
    if (sched.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |cur| {
            if (!task_mod.nprocPreflight(cur.uid, cur.nproc_cur)) return -11;
        }
    }

    if (loader.loadProgram(name, caller_tid, initial_init_caller, false, caller_fsize_cur, caller_fsize_max)) |task_idx| {
        const t = @import("task.zig");
        if (t.getTask(task_idx)) |new_task| {
            const se = @import("../arch/arch.zig").syscall;
            const my_cpu: u8 = @intCast(se.getPerCpu().cpu_id);
            // Task #2: prefer hard affinity, fall back to last_cpu (initial placement).
            const target_cpu: u8 = if (new_task.cpu_affinity >= 0)
                @intCast(new_task.cpu_affinity)
            else
                new_task.last_cpu;
            if (target_cpu != my_cpu) {
                asm volatile ("mfence" ::: .{ .memory = true });
                sched.kickCpu(target_cpu);
            }
            return @intCast(new_task.tid);
        }
    }

    serial.writeString("[spawn] failed\n");
    return -1;
}

/// Syscall #62: kill(pid, signum)
/// pid > 0: 单进程；pid < -1: 广播到进程组 -pid（kill(-pgid)）；pid == -1: 暂不支持。
pub fn kill(target_pid: i64, signum: u32) i64 {
    const sig_mod = @import("signal.zig");
    if (target_pid == -1) return -22; // EINVAL — kill(-1) 不在 v1 范围
    if (target_pid < -1) {
        const pgid: u16 = @intCast(-target_pid);
        return if (sig_mod.sendSignalToPgrp(pgid, signum) > 0) 0 else -1;
    }
    if (sig_mod.sendSignal(@intCast(target_pid), signum)) {
        return 0;
    }
    return -1;
}

/// Syscall #63: uname(buf)
/// RDI = pointer to user buffer (390 bytes: 6 fields × 65 bytes)
pub fn uname(buf_ptr: u64) i64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return -1;

    const copy = @import("../mm/copy_from_user.zig");

    var ubuf: [390]u8 = undefined;
    @memset(&ubuf, 0);

    const fields = [_][]const u8{
        "MoQiOS", // sysname
        "moqios", // nodename
        "0.1.0", // release
        "MoQiOS 0.1.0", // version
        "x86_64", // machine
        "", // domainname
    };

    var offset: usize = 0;
    for (fields) |f| {
        const copy_len = @min(f.len, 64);
        @memcpy(ubuf[offset .. offset + copy_len], f[0..copy_len]);
        offset += 65;
    }

    return if (copy.copyToUser(@ptrFromInt(buf_ptr), &ubuf, ubuf.len) == ubuf.len) 0 else -14;
}
