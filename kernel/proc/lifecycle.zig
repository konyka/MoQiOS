const serial = @import("../arch/x86_64/serial.zig");
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
    if (sched.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |cur| {
            caller_tid = cur.tid;
        }
    }

    if (loader.loadProgram(name, caller_tid)) |task_idx| {
        const t = @import("task.zig");
        if (t.getTask(task_idx)) |new_task| {
            return @intCast(new_task.tid);
        }
    }

    serial.writeString("[spawn] failed\n");
    return -1;
}

/// Syscall #62: kill(pid, signum)
pub fn kill(target_tid: u32, signum: u32) i64 {
    const sig_mod = @import("signal.zig");
    if (sig_mod.sendSignal(target_tid, signum)) {
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

    _ = copy.copyToUser(@ptrFromInt(buf_ptr), &ubuf, 390);
    return 0;
}
