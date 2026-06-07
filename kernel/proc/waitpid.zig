/// waitpid — wait for child process state changes.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");

/// waitpid(pid, status_ptr) -> child tid or -errno.
/// pid: -1 (any child) or >0 (specific child).
pub fn waitpid(pid_raw: u64, status_ptr: u64) i64 {
    const pid: i32 = if (pid_raw == @as(u64, @bitCast(@as(i64, -1))))
        @as(i32, -1)
    else if (pid_raw > 0x7FFFFFFF)
        @as(i32, -1)
    else
        @intCast(pid_raw);

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;

    if (!task_mod.hasChildren(cur_idx)) return -10; // -ECHILD

    var exit_code: i32 = 0;
    if (task_mod.waitpid(cur_idx, pid, &exit_code)) |child_tid| {
        if (status_ptr != 0 and status_ptr < 0x0000_8000_0000_0000) {
            _ = copy.copyToUser(@ptrFromInt(status_ptr), @as([*]const u8, @ptrCast(&exit_code))[0..4], 4);
        }
        return child_tid;
    }

    // No zombie child yet — block this task until a child exits.
    asm volatile ("cli");
    const parent = task_mod.getTask(cur_idx) orelse {
        asm volatile ("sti");
        return -1;
    };
    parent.waiting_for_child = true;
    parent.state = .blocked;
    asm volatile ("" ::: .{ .memory = true });
    asm volatile ("sti");

    while (true) {
        // SMP: child may exit on another CPU — must reload from memory each lap.
        if (!@as(*volatile bool, @ptrCast(&parent.waiting_for_child)).*) break;
        asm volatile ("pause" ::: .{ .memory = true });
        asm volatile ("hlt" ::: .{ .memory = true });
    }

    // Woken up — a child has exited. Now reap it.
    if (task_mod.waitpid(cur_idx, pid, &exit_code)) |child_tid| {
        if (status_ptr != 0 and status_ptr < 0x0000_8000_0000_0000) {
            _ = copy.copyToUser(@ptrFromInt(status_ptr), @as([*]const u8, @ptrCast(&exit_code))[0..4], 4);
        }
        return child_tid;
    } else {
        return 0; // Spurious wakeup
    }
}
