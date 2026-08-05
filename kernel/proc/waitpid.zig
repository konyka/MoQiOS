/// waitpid — wait for child process state changes.
///
/// Extracted from syscall_entry.zig (v18.9).
const copy = @import("../mm/copy_from_user.zig");
const sched_mod = @import("../proc/sched.zig");
const task_mod = @import("../proc/task.zig");
const se = @import("../arch/arch.zig").syscall;

/// waitpid(pid, status_ptr) -> child tid or -errno.
/// pid: -1 (any child) or >0 (specific child).
pub fn waitpid(pid_raw: u64, status_ptr: u64) i64 {
    return waitpidWithOptions(pid_raw, status_ptr, 0);
}

/// waitpidWithOptions — core implementation with WNOHANG support.
/// options: bit 0 = WNOHANG (return 0 immediately if no zombie child)
pub fn waitpidWithOptions(pid_raw: u64, status_ptr: u64, options: u32) i64 {
    const pid: i32 = if (pid_raw == @as(u64, @bitCast(@as(i64, -1))))
        @as(i32, -1)
    else if (pid_raw > 0x7FFFFFFF)
        @as(i32, -1)
    else
        @intCast(pid_raw);

    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;
    if (status_ptr != 0 and !copy.validateUserBufferWritable(status_ptr, 4)) return -14;

    if (!task_mod.hasChildren(cur_idx)) return -10; // -ECHILD

    var exit_code: i32 = 0;
    if (task_mod.waitpid(cur_idx, pid, &exit_code)) |child_tid| {
        if (!writeStatus(status_ptr, exit_code)) return -14;
        return child_tid;
    }

    // WNOHANG: return 0 immediately if no zombie child
    if (options & 1 != 0) return 0;

    // No zombie child yet — block on each matching child's exit queue. The
    // previous waitpid path hlt-spun in the syscall until a child exited, which
    // deadlocked on a single CPU because the newly spawned child never ran.
    const parent = task_mod.getTask(cur_idx) orelse return -1;
    const sig_mod = @import("signal.zig");

    // Retry loop: any child's exit clears `waiting_for_child` (exitTask does
    // not filter by target pid), so a non-target child's exit must NOT end the
    // wait — reap our target if available, otherwise re-block. Returning 0
    // here made waitpid(specific_pid) spuriously succeed (hello44 RR test).
    while (true) {
        // Atomic block protocol: the flag store, the zombie scan and the
        // .blocked store all happen under task_lock — the same lock exitTask
        // holds across its zombie store + wake check. Either exitTask's
        // section runs first (our scan sees the zombie) or ours runs first
        // (exitTask sees flag=true && state==.blocked and performs the full
        // wake: flag clear + .ready + enqueue + kick). The previous split
        // protocol (flag store outside the lock) let the wake slip between
        // the flag store and the scan, stranding the waiter off-CPU.
        const tflags = task_mod.lockTask();
        parent.waiting_for_child = true;
        parent.wait_cpu = @intCast(se.getPerCpu().cpu_id);

        switch (task_mod.waitpidScanLocked(cur_idx, pid, &exit_code)) {
            .reaped => |child_tid| {
                parent.waiting_for_child = false;
                task_mod.unlockTask(tflags);
                if (!writeStatus(status_ptr, exit_code)) return -14;
                return child_tid;
            },
            .busy => {
                // Gated zombie — nobody will re-wake us for it (its exitTask
                // ran already), so never block: spin-reap outside the lock.
                parent.waiting_for_child = false;
                task_mod.unlockTask(tflags);
                if (task_mod.waitpid(cur_idx, pid, &exit_code)) |child_tid| {
                    if (!writeStatus(status_ptr, exit_code)) return -14;
                    return child_tid;
                }
                continue;
            },
            .none => {
                if (!task_mod.hasChildrenLocked(cur_idx)) {
                    parent.waiting_for_child = false;
                    task_mod.unlockTask(tflags);
                    return -10; // -ECHILD
                }
                se.syncUserRspToTask(parent);
                // Blocked under the lock — see the protocol comment above.
                @import("sched_claim.zig").store(&parent.state, .blocked);
                task_mod.unlockTask(tflags);
                task_mod.kickChildCpus(parent.tid, parent.wait_cpu);
                sched_mod.requestReschedule();
            },
        }

        while (@as(*volatile bool, @ptrCast(&parent.waiting_for_child)).* and !sig_mod.pendingActionable(parent)) {
            asm volatile ("sti");
            asm volatile ("hlt" ::: .{ .memory = true });
        }
        parent.waiting_for_child = false;
        // State repair: the wait loop runs with state == .blocked while this
        // task is still current and executing on this CPU. If the wake landed
        // while we were still .running, exitTask deliberately skipped the
        // .ready store — so nothing transitions us back, and the next
        // switch-out would drop a .blocked current task from the runnable set
        // for good (observed as a post-waitpid stall, [wp] woke ... state=2).
        // Being here proves we are this CPU's current task, so restore
        // .running unless a switch/re-claim already did.
        if (parent.state != .running) {
            @import("sched_claim.zig").store(&parent.state, .running);
        }
        se.syncUserRspFromTask(parent);
        se.getPerCpu().kernel_rsp = parent.kernel_stack_top;
        @import("../arch/arch.zig").gdt.setRsp0(se.getPerCpu().cpu_id, parent.kernel_stack_top);
        // ioperm: pair every per-switch RSP0 update with the IOPB load.
        @import("ioperm.zig").loadForTask(se.getPerCpu().cpu_id, parent);

        // Woken up — a child may have exited. Reap first: a pending signal
        // only aborts the wait when no child status is available, so an
        // EINTR'd (or killed) waitpid never consumes the child's exit status.
        if (task_mod.waitpid(cur_idx, pid, &exit_code)) |child_tid| {
            if (!writeStatus(status_ptr, exit_code)) return -14;
            return child_tid;
        }
        // Signal kick (sendSignal unblocks without a child exit): die on a
        // fatal signal via the same exit-by-signal path the timer tick uses,
        // or report EINTR so the handler can run on return.
        if (sig_mod.pendingFatal(parent)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(parent)) return -4; // -EINTR
        // Non-target child exit (or spurious wake): loop and re-block.
    }
}

fn writeStatus(status_ptr: u64, exit_code: i32) bool {
    if (status_ptr == 0) return true;
    if (status_ptr >= 0x0000_8000_0000_0000) return false;
    const src: [*]const u8 = @ptrCast(&exit_code);
    return copy.copyToUser(@ptrFromInt(status_ptr), src[0..4], 4) == 4;
}
