/// procfs — virtual filesystem providing process and system information.
///
/// Dynamically generates content for /proc files on each read.
pub const ProcFile = enum(u8) {
    meminfo,
    cpuinfo,
    uptime,
    pid_status,
    pid_maps,
    pid_stat,
    pid_cmdline,
    version,
    loadavg,
    filesystems,
    stat,
    sched_stats,
};

/// Generate proc file content into the provided buffer.
/// Returns the number of bytes written (may exceed max_len, caller must handle offset).
/// For integration with VFS, the caller should generate into a scratch buffer
/// and copy from the current offset.
pub fn procRead(file: ProcFile, pid: u16, buf: [*]u8, max_len: u32) u32 {
    return switch (file) {
        .meminfo => generateMeminfo(buf, max_len),
        .cpuinfo => generateCpuinfo(buf, max_len),
        .uptime => generateUptime(buf, max_len),
        .pid_status => generatePidStatus(pid, buf, max_len),
        .pid_maps => generatePidMaps(pid, buf, max_len),
        .pid_stat => generatePidStat(pid, buf, max_len),
        .pid_cmdline => generatePidCmdline(pid, buf, max_len),
        .version => generateVersion(buf, max_len),
        .loadavg => generateLoadavg(buf, max_len),
        .filesystems => generateFilesystems(buf, max_len),
        .stat => generateStat(buf, max_len),
        .sched_stats => generateSchedStats(buf, max_len),
    };
}

// ---------- content generators ----------

fn generateMeminfo(buf: [*]u8, max_len: u32) u32 {
    const pmm = @import("../mm/pmm.zig");
    const total_kb = pmm.getTotalPages() * 4; // 4KB per page
    const free_kb = pmm.getFreePages() * 4;
    const avail_kb = free_kb; // simplified

    var pos: u32 = 0;
    pos = appendStr(buf, pos, max_len, "MemTotal:       ");
    pos = appendDec(buf, pos, max_len, total_kb);
    pos = appendStr(buf, pos, max_len, " kB\nMemFree:        ");
    pos = appendDec(buf, pos, max_len, free_kb);
    pos = appendStr(buf, pos, max_len, " kB\nMemAvailable:   ");
    pos = appendDec(buf, pos, max_len, avail_kb);
    pos = appendStr(buf, pos, max_len, " kB\n");
    return pos;
}

fn generateCpuinfo(buf: [*]u8, max_len: u32) u32 {
    const smp = @import("../smp.zig");
    const cpu_count = smp.cpu_count;

    var pos: u32 = 0;
    var i: u32 = 0;
    while (i < cpu_count) : (i += 1) {
        pos = appendStr(buf, pos, max_len, "processor\t: ");
        pos = appendDec(buf, pos, max_len, i);
        pos = appendStr(buf, pos, max_len, "\nmodel name\t: x86_64\n");
        pos = appendStr(buf, pos, max_len, "cpu cores\t: ");
        pos = appendDec(buf, pos, max_len, cpu_count);
        pos = appendStr(buf, pos, max_len, "\n\n");
    }
    return pos;
}

fn generateUptime(buf: [*]u8, max_len: u32) u32 {
    const idt = @import("../arch/x86_64/idt.zig");
    const ticks = idt.getTickCount();
    const secs = ticks / 100;
    const hundredths = ticks % 100;

    var pos: u32 = 0;
    pos = appendDec(buf, pos, max_len, secs);
    pos = appendChar(buf, pos, max_len, '.');
    if (hundredths < 10) {
        pos = appendChar(buf, pos, max_len, '0');
    }
    pos = appendDec(buf, pos, max_len, hundredths);
    pos = appendStr(buf, pos, max_len, " ");
    // idle time simplified to 0.00
    pos = appendDec(buf, pos, max_len, 0);
    pos = appendStr(buf, pos, max_len, ".00\n");
    return pos;
}

fn generatePidStatus(pid: u16, buf: [*]u8, max_len: u32) u32 {
    const t = findTaskByPid(pid) orelse {
        return appendStr(buf, 0, max_len, "Pid: 0\nState: X (dead)\n");
    };

    var pos: u32 = 0;
    pos = appendStr(buf, pos, max_len, "Name:\t\tprocess\n");
    pos = appendStr(buf, pos, max_len, "State:\t\t");
    pos = appendStr(buf, pos, max_len, stateStr(t.state));
    pos = appendStr(buf, pos, max_len, "\nPid:\t\t");
    pos = appendDec(buf, pos, max_len, t.tid);
    pos = appendStr(buf, pos, max_len, "\nPPid:\t\t");
    pos = appendDec(buf, pos, max_len, t.parent_tid);
    pos = appendStr(buf, pos, max_len, "\n");
    return pos;
}

fn generatePidMaps(pid: u16, buf: [*]u8, max_len: u32) u32 {
    _ = @import("../proc/task.zig"); // referenced by findTaskByPid
    const paging_mod = @import("../arch/arch.zig").paging;
    const t = findTaskByPid(pid) orelse {
        return appendStr(buf, 0, max_len, "# no such process\n");
    };
    if (t.page_table_phys == 0) {
        return appendStr(buf, 0, max_len, "# kernel thread\n");
    }
    var vmas: [32]paging_mod.VMAEntry = undefined;
    const count = paging_mod.enumerateVMAs(t.page_table_phys, &vmas);
    var pos: u32 = 0;
    for (0..count) |i| {
        const vma = vmas[i];
        // Format: "start-end perms offset dev inode pathname\n"
        pos = appendHex(buf, pos, max_len, vma.start);
        pos = appendStr(buf, pos, max_len, "-");
        pos = appendHex(buf, pos, max_len, vma.end);
        pos = appendStr(buf, pos, max_len, " ");
        pos = appendStr(buf, pos, max_len, if (vma.flags & 1 != 0) "r" else "-");
        pos = appendStr(buf, pos, max_len, if (vma.flags & 2 != 0) "w" else "-");
        pos = appendStr(buf, pos, max_len, if (vma.flags & 4 != 0) "x" else "-");
        pos = appendStr(buf, pos, max_len, "p 00000000 00:00 0\n");
    }
    return pos;
}

fn appendHex(buf: [*]u8, pos: u32, max_len: u32, val: u64) u32 {
    const hex = "0123456789abcdef";
    var p = pos;
    var v = val;
    var i: u32 = 16;
    var hbuf: [16]u8 = undefined;
    while (i > 0) {
        i -= 1;
        hbuf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    for (0..16) |j| {
        if (p < max_len) {
            buf[p] = hbuf[j];
            p += 1;
        }
    }
    return p;
}

/// Generate /proc/PID/stat — Linux-compatible single-line format.
fn generatePidStat(pid: u16, buf: [*]u8, max_len: u32) u32 {
    const t = findTaskByPid(pid) orelse {
        return appendStr(buf, 0, max_len, "0 (none) Z 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n");
    };
    var pos: u32 = 0;
    pos = appendDec(buf, pos, max_len, @intCast(pid));
    pos = appendStr(buf, pos, max_len, " (process) ");
    // State character
    pos = appendChar(buf, pos, max_len, stateChar(t.state));
    pos = appendStr(buf, pos, max_len, " ");
    pos = appendDec(buf, pos, max_len, @intCast(t.parent_tid));
    pos = appendStr(buf, pos, max_len, " 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n");
    return pos;
}

fn stateChar(state: @import("../proc/task.zig").TaskState) u8 {
    return switch (state) {
        .running => 'R',
        .ready => 'S',
        .blocked => 'D',
        .zombie => 'Z',
    };
}

/// Generate /proc/PID/cmdline
fn generatePidCmdline(pid: u16, buf: [*]u8, max_len: u32) u32 {
    _ = pid;
    // Simplified: return "process\0" (null-terminated)
    if (max_len >= 8) {
        const name = "process\x00";
        @memcpy(buf[0..8], name);
        return 8;
    }
    return 0;
}

/// Generate /proc/version
fn generateVersion(buf: [*]u8, max_len: u32) u32 {
    var pos: u32 = 0;
    pos = appendStr(buf, pos, max_len, "MoQiOS version 9.0 (zig 0.16.0) #1 SMP ");
    pos = appendStr(buf, pos, max_len, "x86_64 GNU/Linux\n");
    return pos;
}

/// Generate /proc/loadavg
fn generateLoadavg(buf: [*]u8, max_len: u32) u32 {
    const task_mod = @import("../proc/task.zig");
    // Count running/ready tasks
    var running: u32 = 0;
    var total: u32 = 0;
    for (0..task_mod.MAX_TASKS) |idx| {
        const i: u32 = @intCast(idx);
        if (task_mod.getTask(i)) |t| {
            total += 1;
            if (t.state == .running or t.state == .ready) running += 1;
        }
    }
    var pos: u32 = 0;
    // 1min/5min/15min load averages (simplified: 0.0x)
    pos = appendStr(buf, pos, max_len, "0.01 0.01 0.00 ");
    pos = appendDec(buf, pos, max_len, @intCast(running));
    pos = appendChar(buf, pos, max_len, '/');
    pos = appendDec(buf, pos, max_len, @intCast(total));
    pos = appendStr(buf, pos, max_len, " 0\n");
    return pos;
}

/// Generate /proc/filesystems
fn generateFilesystems(buf: [*]u8, max_len: u32) u32 {
    var pos: u32 = 0;
    pos = appendStr(buf, pos, max_len, "nodev\tproc\n");
    pos = appendStr(buf, pos, max_len, "nodev\tdevtmpfs\n");
    pos = appendStr(buf, pos, max_len, "\text2\n");
    pos = appendStr(buf, pos, max_len, "\tfat\n");
    pos = appendStr(buf, pos, max_len, "\ttmpfs\n");
    pos = appendStr(buf, pos, max_len, "\tiso9660\n");
    return pos;
}

/// Generate /proc/stat — basic system statistics
fn generateStat(buf: [*]u8, max_len: u32) u32 {
    const smp = @import("../smp.zig");
    const idt = @import("../arch/x86_64/idt.zig");
    const ticks = idt.getTickCount();
    var pos: u32 = 0;
    // Aggregate CPU line (user/nice/system/idle in jiffies)
    pos = appendStr(buf, pos, max_len, "cpu  ");
    pos = appendDec(buf, pos, max_len, ticks); // user
    pos = appendStr(buf, pos, max_len, " 0 ");
    pos = appendDec(buf, pos, max_len, ticks / 10); // system
    pos = appendStr(buf, pos, max_len, " ");
    pos = appendDec(buf, pos, max_len, ticks * 9); // idle
    pos = appendStr(buf, pos, max_len, " 0 0 0 0 0\n");
    // Per-CPU lines
    const cpu_count: u32 = @intCast(smp.cpu_count);
    for (0..cpu_count) |cidx| {
        const c: u32 = @intCast(cidx);
        pos = appendStr(buf, pos, max_len, "cpu");
        pos = appendDec(buf, pos, max_len, c);
        pos = appendStr(buf, pos, max_len, " ");
        pos = appendDec(buf, pos, max_len, ticks / @max(cpu_count, 1));
        pos = appendStr(buf, pos, max_len, " 0 ");
        pos = appendDec(buf, pos, max_len, ticks / 10 / @max(cpu_count, 1));
        pos = appendStr(buf, pos, max_len, " ");
        pos = appendDec(buf, pos, max_len, ticks * 9 / @max(cpu_count, 1));
        pos = appendStr(buf, pos, max_len, " 0 0 0 0 0\n");
    }
    pos = appendStr(buf, pos, max_len, "intr 0\nprocesses 0\nprocs_running ");
    pos = appendDec(buf, pos, max_len, 1);
    pos = appendStr(buf, pos, max_len, "\nprocs_blocked 0\n");
    return pos;
}

/// Generate /proc/sched_stats — Task #6 per-CPU scheduler profiling dump.
///
/// One line per online CPU:
///   cpuN: enq=.. deq=.. steal_try=.. steal_ok=.. stolen=.. idle=.. sched=.. avg_depth=..
fn generateSchedStats(buf: [*]u8, max_len: u32) u32 {
    const per_cpu = @import("../proc/per_cpu.zig");
    const smp = @import("../smp.zig");
    var ncpus: u32 = smp.cpu_count;
    if (ncpus == 0) ncpus = 1;
    if (ncpus > per_cpu.MAX_CPUS) ncpus = per_cpu.MAX_CPUS;

    var pos: u32 = 0;
    var c: u32 = 0;
    while (c < ncpus) : (c += 1) {
        const stats = per_cpu.getStats(@intCast(c)) orelse continue;
        pos = appendStr(buf, pos, max_len, "cpu");
        pos = appendDec(buf, pos, max_len, c);
        pos = appendStr(buf, pos, max_len, ": enq=");
        pos = appendDec(buf, pos, max_len, stats.local_enqueues);
        pos = appendStr(buf, pos, max_len, " deq=");
        pos = appendDec(buf, pos, max_len, stats.local_dequeues);
        pos = appendStr(buf, pos, max_len, " steal_try=");
        pos = appendDec(buf, pos, max_len, stats.steal_attempts);
        pos = appendStr(buf, pos, max_len, " steal_ok=");
        pos = appendDec(buf, pos, max_len, stats.steal_successes);
        pos = appendStr(buf, pos, max_len, " stolen=");
        pos = appendDec(buf, pos, max_len, stats.tasks_stolen);
        pos = appendStr(buf, pos, max_len, " idle=");
        pos = appendDec(buf, pos, max_len, stats.idle_cycles);
        pos = appendStr(buf, pos, max_len, " sched=");
        pos = appendDec(buf, pos, max_len, stats.schedule_calls);
        pos = appendStr(buf, pos, max_len, " avg_depth=");
        const avg: u64 = if (stats.sample_count == 0)
            0
        else
            stats.queue_depth_sum / stats.sample_count;
        pos = appendDec(buf, pos, max_len, avg);
        pos = appendChar(buf, pos, max_len, '\n');
    }
    return pos;
}

// ---------- helpers ----------

fn findTaskByPid(pid: u16) ?*const @import("../proc/task.zig").Task {
    const task_mod = @import("../proc/task.zig");
    const MAX_TASKS = task_mod.MAX_TASKS;
    var i: u32 = 0;
    while (i < MAX_TASKS) : (i += 1) {
        if (task_mod.getTask(i)) |t| {
            if (t.tid == pid) return t;
        }
    }
    return null;
}

fn stateStr(state: @import("../proc/task.zig").TaskState) []const u8 {
    return switch (state) {
        .ready => "S (sleeping)",
        .running => "R (running)",
        .blocked => "S (sleeping)",
        .zombie => "Z (zombie)",
    };
}

fn appendStr(buf: [*]u8, pos: u32, max_len: u32, s: []const u8) u32 {
    var p = pos;
    for (s) |c| {
        if (p >= max_len) break;
        buf[p] = c;
        p += 1;
    }
    return p;
}

fn appendChar(buf: [*]u8, pos: u32, max_len: u32, c: u8) u32 {
    if (pos >= max_len) return pos;
    buf[pos] = c;
    return pos + 1;
}

fn appendDec(buf: [*]u8, pos: u32, max_len: u32, value: u64) u32 {
    if (value == 0) {
        if (pos >= max_len) return pos;
        buf[pos] = '0';
        return pos + 1;
    }
    var tmp: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        tmp[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    var p = pos;
    while (i < 20) {
        if (p >= max_len) break;
        buf[p] = tmp[i];
        p += 1;
        i += 1;
    }
    return p;
}
