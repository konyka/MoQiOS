/// procfs — virtual filesystem providing process and system information.
///
/// Dynamically generates content for /proc files on each read.
const std = @import("std");

pub const ProcFile = enum(u8) {
    meminfo,
    cpuinfo,
    uptime,
    pid_status,
    pid_maps,
    pid_stat,
    pid_cmdline,
    pid_rss,
    /// /proc/<pid>/comm: the process name and a newline.
    pid_comm,
    version,
    loadavg,
    filesystems,
    stat,
    sched_stats,
    vma_stats,
    irqtime,
    /// Longest interrupt per CPU since the previous read of this file (a read
    /// starts a new window); `irqtime` keeps the boot-wide maxima.
    irqwindow,
    /// Loopback queue counters: frames queued, delivered, dropped (queue full) and the queue's high-water mark.
    lostats,
    /// The /proc directory itself and /proc/<pid> (also reached as /proc/self): directories, listed by getdents64.
    root_dir,
    pid_dir,
    /// A directory that exists only because volumes are mounted below it (for example /mnt for a volume at /mnt/e). It has no storage of
    /// its own; the descriptor keeps its path and getdents64 lists the mount points one level below.
    mount_dir,
    /// /proc/self/fd (or /proc/<pid>/fd): one entry per open descriptor of the process, named by its number.
    fd_dir,
};

pub fn isDir(file: ProcFile) bool {
    return file == .root_dir or file == .pid_dir or file == .mount_dir or file == .fd_dir;
}

/// One directory entry for getdents64: a name and its DT_* type.
pub const DirEntry = struct {
    name: [20]u8 = undefined,
    len: u8 = 0,
    dtype: u8 = 0,

    fn set(self: *DirEntry, text: []const u8, dtype: u8) void {
        @memcpy(self.name[0..text.len], text);
        self.len = @intCast(text.len);
        self.dtype = dtype;
    }
};

const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;
const DT_LNK: u8 = 10;

/// The files /proc lists besides the per-process directories, in listing order.
const root_files = [_][]const u8{ "meminfo", "cpuinfo", "uptime", "version", "loadavg", "filesystems", "stat", "sched_stats", "vma_stats", "irqtime", "irqwindow", "lostats" };
/// What a /proc/<pid> directory lists.
const pid_files = [_][]const u8{ "status", "maps", "stat", "cmdline", "rss", "comm", "fd" };

/// The entry at position `pos` of /proc ("." and "..", the files, self, then one directory per live process), or null past the end. A
/// thread is part of its process and is not listed on its own, as on Linux.
pub fn rootEntryAt(pos: u32) ?DirEntry {
    var e: DirEntry = .{};
    if (pos == 0) {
        e.set(".", DT_DIR);
        return e;
    }
    if (pos == 1) {
        e.set("..", DT_DIR);
        return e;
    }
    const files: u32 = root_files.len;
    if (pos - 2 < files) {
        e.set(root_files[pos - 2], DT_REG);
        return e;
    }
    if (pos - 2 == files) {
        e.set("self", DT_LNK);
        return e;
    }
    var want: u32 = pos - 3 - files;
    const task_mod = @import("../proc/task.zig");
    var i: u32 = 0;
    while (i < task_mod.MAX_TASKS) : (i += 1) {
        const t = task_mod.getTask(i) orelse continue;
        if (t.is_thread) continue;
        if (want > 0) {
            want -= 1;
            continue;
        }
        var digits: [12]u8 = undefined;
        var n: usize = 0;
        var v: u32 = t.tid;
        if (v == 0) {
            digits[0] = '0';
            n = 1;
        }
        while (v > 0) : (v /= 10) {
            digits[n] = '0' + @as(u8, @intCast(v % 10));
            n += 1;
        }
        var out: [12]u8 = undefined;
        for (0..n) |k| out[k] = digits[n - 1 - k];
        e.set(out[0..n], DT_DIR);
        return e;
    }
    return null;
}

/// The entry at position `pos` of /proc/<pid>, or null past the end.
pub fn pidEntryAt(pos: u32) ?DirEntry {
    var e: DirEntry = .{};
    if (pos == 0) {
        e.set(".", DT_DIR);
        return e;
    }
    if (pos == 1) {
        e.set("..", DT_DIR);
        return e;
    }
    if (pos - 2 < pid_files.len) {
        const name = pid_files[pos - 2];
        e.set(name, if (std.mem.eql(u8, name, "fd")) DT_DIR else DT_REG);
        return e;
    }
    return null;
}

/// Files whose content is consumed by generating it (a read starts a new
/// window). vfs.read must generate them only for the first read of a
/// descriptor, otherwise the EOF read would eat the next window.
pub fn consumesOnRead(file: ProcFile) bool {
    return file == .irqwindow;
}

/// Generate proc file content into the provided buffer.
/// Returns the number of bytes written (may exceed max_len, caller must handle offset).
/// For integration with VFS, the caller should generate into a scratch buffer
/// and copy from the current offset.
pub fn procRead(file: ProcFile, pid: u32, buf: [*]u8, max_len: u32) u32 {
    return switch (file) {
        .meminfo => generateMeminfo(buf, max_len),
        .cpuinfo => generateCpuinfo(buf, max_len),
        .uptime => generateUptime(buf, max_len),
        .pid_status => generatePidStatus(pid, buf, max_len),
        .pid_maps => generatePidMaps(pid, buf, max_len),
        .pid_stat => generatePidStat(pid, buf, max_len),
        .pid_cmdline => generatePidCmdline(pid, buf, max_len),
        .pid_rss => generatePidRss(pid, buf, max_len),
        .pid_comm => generatePidComm(pid, buf, max_len),
        .version => generateVersion(buf, max_len),
        .loadavg => generateLoadavg(buf, max_len),
        .filesystems => generateFilesystems(buf, max_len),
        .stat => generateStat(buf, max_len),
        .sched_stats => generateSchedStats(buf, max_len),
        .vma_stats => generateVmaStats(buf, max_len),
        .irqtime => generateIrqTime(buf, max_len),
        .irqwindow => generateIrqWindow(buf, max_len),
        .lostats => generateLoStats(buf, max_len),
        .root_dir, .pid_dir, .mount_dir, .fd_dir => 0,
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
    const cpu_count = smp.configured_cpu_count;

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
    const idt = @import("../arch/arch.zig").interrupts;
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

fn generatePidStatus(pid: u32, buf: [*]u8, max_len: u32) u32 {
    const task_mod = @import("../proc/task.zig");
    const ps = @import("pid_status.zig");
    const cap_abi = @import("../proc/cap_abi.zig");
    const user_space = @import("../mm/user_space.zig");
    var name: [16]u8 = undefined;
    var groups: [@import("../proc/group_policy.zig").NGROUPS_MAX]u32 = undefined;
    var st: ps.Status = undefined;
    // One consistent snapshot under the task lock: the thread count and the leader's parent come from other task slots.
    const flags = task_mod.lockTask();
    var target: ?u32 = null;
    var i: u32 = 0;
    while (i < task_mod.MAX_TASKS) : (i += 1) {
        const t = task_mod.getTask(i) orelse continue;
        if (t.tid == pid) {
            target = i;
            break;
        }
    }
    const t = if (target) |idx| (task_mod.getTask(idx) orelse null) else null;
    if (t == null) {
        task_mod.unlockTask(flags);
        return appendStr(buf, 0, max_len, "Pid: 0\nState: X (dead)\n");
    }
    const tt = t.?;
    const tgid: u32 = if (tt.is_thread and tt.parent_tid != 0) tt.parent_tid else tt.tid;
    var ppid: u32 = tt.parent_tid;
    var threads: u32 = 0;
    var j: u32 = 0;
    while (j < task_mod.MAX_TASKS) : (j += 1) {
        const m = task_mod.getTask(j) orelse continue;
        const member_of = if (m.is_thread and m.parent_tid != 0) m.parent_tid else m.tid;
        if (member_of == tgid and m.state != .zombie) threads += 1;
        if (tt.is_thread and m.tid == tgid and !m.is_thread) ppid = m.parent_tid;
    }
    const root = tt.page_table_phys;
    if (root != 0) user_space.retainUserSpace(root);
    // The program image (up to the initial break) plus what the address space has been charged for since: heap, mappings and demand-faulted stack.
    const image: u64 = if (tt.mm) |m| (if (m.brk_start > user_space.USER_CODE_BASE) m.brk_start - user_space.USER_CODE_BASE else 0) else 0;
    const charged: u64 = if (tt.mm) |m| @atomicLoad(u64, &m.as_used, .monotonic) else 0;
    const data_charged: u64 = if (tt.mm) |m| @atomicLoad(u64, &m.data_used, .monotonic) else 0;
    @memcpy(&name, &tt.comm);
    const ng: usize = @min(@as(usize, tt.ngroups), groups.len);
    @memcpy(groups[0..ng], tt.groups[0..ng]);
    st = .{
        .name = "",
        .state = ps.stateOf(tt.state == .zombie, tt.stopped, tt.state == .blocked),
        .tgid = tgid,
        .pid = tt.tid,
        .ppid = ppid,
        .umask = tt.fsctx().umask,
        .uid = .{ tt.uid, tt.euid, tt.suid, tt.euid },
        .gid = .{ tt.gid, tt.egid, tt.sgid, tt.egid },
        .fd_size = @import("vfs.zig").MAX_FDS,
        .groups = groups[0..ng],
        .threads = threads,
        .no_new_privs = tt.no_new_privs,
        .cap_inh = cap_abi.encode(tt.inheritable_caps),
        .cap_prm = cap_abi.encode(tt.permitted_caps),
        .cap_eff = cap_abi.encode(tt.effective_caps),
        .cap_bnd = cap_abi.BOUNDING,
    };
    task_mod.unlockTask(flags);
    defer if (root != 0) user_space.destroyUserSpace(root);
    if (root != 0 and comptime @import("builtin").cpu.arch == .x86_64) {
        st.vm_rss_kb = @import("../arch/x86_64/paging.zig").residentUserPages(root) * 4;
        st.vm_size_kb = (image + charged) / 1024;
        st.vm_data_kb = data_charged / 1024;
    }
    st.name = name[0..@import("../proc/comm_policy.zig").textLen(&name)];
    return ps.render(buf, max_len, st);
}

/// The process name of `t` as text (its comm up to the first NUL).
fn commText(t: *const @import("../proc/task.zig").Task) []const u8 {
    const cp = @import("../proc/comm_policy.zig");
    return t.comm[0..cp.textLen(&t.comm)];
}

fn generatePidComm(pid: u32, buf: [*]u8, max_len: u32) u32 {
    const t = findTaskByPid(pid) orelse return 0;
    return appendChar(buf, appendStr(buf, 0, max_len, commText(t)), max_len, '\n');
}

fn generatePidMaps(pid: u32, buf: [*]u8, max_len: u32) u32 {
    const task_mod = @import("../proc/task.zig");
    const user_space = @import("../mm/user_space.zig");
    const paging_mod = @import("../arch/arch.zig").paging;
    // Pin the target's address space before walking it: the target may exit
    // (and its page tables be freed and reused) while this reader runs.
    const flags = task_mod.lockTask();
    const idx = task_mod.findTaskByTidLocked(pid) orelse {
        task_mod.unlockTask(flags);
        return appendStr(buf, 0, max_len, "# no such process\n");
    };
    const root = (task_mod.getTask(idx) orelse unreachable).page_table_phys;
    if (root != 0) user_space.retainUserSpace(root);
    task_mod.unlockTask(flags);
    if (root == 0) return appendStr(buf, 0, max_len, "# kernel thread\n");
    defer user_space.destroyUserSpace(root);
    var vmas: [32]paging_mod.VMAEntry = undefined;
    const count = paging_mod.enumerateVMAs(root, &vmas);
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

fn generatePidRss(pid: u32, buf: [*]u8, max_len: u32) u32 {
    const task_mod = @import("../proc/task.zig");
    const user_space = @import("../mm/user_space.zig");
    const flags = task_mod.lockTask();
    const idx = task_mod.findTaskByTidLocked(pid) orelse {
        task_mod.unlockTask(flags);
        return appendStr(buf, 0, max_len, "VmRSS:\t0 kB\n");
    };
    const task = task_mod.getTask(idx) orelse unreachable;
    const root = task.page_table_phys;
    if (root != 0) user_space.retainUserSpace(root);
    task_mod.unlockTask(flags);
    defer if (root != 0) user_space.destroyUserSpace(root);
    if (root == 0) return appendStr(buf, 0, max_len, "VmRSS:\t0 kB\n");
    if (comptime @import("builtin").cpu.arch != .x86_64) {
        return appendStr(buf, 0, max_len, "VmRSS:\t0 kB\n# observation unavailable\n");
    }
    const pages = @import("../arch/x86_64/paging.zig").residentUserPages(root);
    var pos: u32 = 0;
    pos = appendStr(buf, pos, max_len, "VmRSS:\t");
    pos = appendDec(buf, pos, max_len, pages * 4);
    return appendStr(buf, pos, max_len, " kB\n");
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
fn generatePidStat(pid: u32, buf: [*]u8, max_len: u32) u32 {
    const t = findTaskByPid(pid) orelse {
        return appendStr(buf, 0, max_len, "0 (none) Z 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n");
    };
    var pos: u32 = 0;
    pos = appendDec(buf, pos, max_len, @intCast(pid));
    pos = appendStr(buf, pos, max_len, " (");
    pos = appendStr(buf, pos, max_len, commText(t));
    pos = appendStr(buf, pos, max_len, ") ");
    // State character
    pos = appendChar(buf, pos, max_len, @import("pid_status.zig").stateOf(t.state == .zombie, t.stopped, t.state == .blocked).letter());
    pos = appendStr(buf, pos, max_len, " ");
    pos = appendDec(buf, pos, max_len, @intCast(t.parent_tid));
    pos = appendStr(buf, pos, max_len, " 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n");
    return pos;
}

/// Generate /proc/PID/cmdline
fn generatePidCmdline(pid: u32, buf: [*]u8, max_len: u32) u32 {
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
    const idt = @import("../arch/arch.zig").interrupts;
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
    const cpu_count: u32 = smp.configured_cpu_count;
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
    var ncpus: u32 = smp.configured_cpu_count;
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

/// One line per configured CPU: `cpu<N> total_us=<t> max_us=<m> count=<c>` —
/// time spent in the interrupt dispatcher (x86_64; elsewhere all zero).
fn generateIrqTime(buf: [*]u8, max_len: u32) u32 {
    var pos: u32 = 0;
    if (comptime @import("builtin").cpu.arch != .x86_64) return pos;
    const idt = @import("../arch/x86_64/idt.zig");
    const p = @import("../arch/x86_64/irq_time_policy.zig");
    const mhz = @import("../arch/x86_64/tsc.zig").tsc_freq_mhz;
    const ncpu = @min(@import("../smp.zig").configured_cpu_count, idt.irq_acc.len);
    var c: u32 = 0;
    while (c < ncpu) : (c += 1) {
        const a = idt.irq_acc[c];
        pos = appendStr(buf, pos, max_len, "cpu");
        pos = appendDec(buf, pos, max_len, c);
        pos = appendStr(buf, pos, max_len, " total_us=");
        pos = appendDec(buf, pos, max_len, p.cyclesToUs(a.total_cycles, mhz));
        pos = appendStr(buf, pos, max_len, " max_us=");
        pos = appendDec(buf, pos, max_len, p.cyclesToUs(a.max_cycles, mhz));
        pos = appendStr(buf, pos, max_len, " count=");
        pos = appendDec(buf, pos, max_len, a.count);
        pos = appendStr(buf, pos, max_len, " depth=");
        pos = appendDec(buf, pos, max_len, a.depth);
        pos = appendStr(buf, pos, max_len, " max_vec=");
        pos = appendDec(buf, pos, max_len, a.max_vector);
        pos = appendStr(buf, pos, max_len, " max_at_ms=");
        pos = appendDec(buf, pos, max_len, p.cyclesToUs(a.max_start_tsc, mhz) / 1000);
        pos = appendStr(buf, pos, max_len, "\n");
    }
    return pos;
}

fn generateIrqWindow(buf: [*]u8, max_len: u32) u32 {
    var pos: u32 = 0;
    if (comptime @import("builtin").cpu.arch != .x86_64) return pos;
    const idt = @import("../arch/x86_64/idt.zig");
    const p = @import("../arch/x86_64/irq_time_policy.zig");
    const mhz = @import("../arch/x86_64/tsc.zig").tsc_freq_mhz;
    const ncpu = @min(@import("../smp.zig").configured_cpu_count, idt.irq_acc.len);
    var c: u32 = 0;
    while (c < ncpu) : (c += 1) {
        // Each slot is written only by its own CPU; the reset below races with
        // at most one interrupt exit, which can only drop that one sample.
        const w = idt.irq_acc[c].takeWindow();
        pos = appendStr(buf, pos, max_len, "cpu");
        pos = appendDec(buf, pos, max_len, c);
        pos = appendStr(buf, pos, max_len, " win_max_us=");
        pos = appendDec(buf, pos, max_len, p.cyclesToUs(w.cycles, mhz));
        pos = appendStr(buf, pos, max_len, " win_vec=");
        pos = appendDec(buf, pos, max_len, w.vector);
        pos = appendStr(buf, pos, max_len, " win_at_ms=");
        pos = appendDec(buf, pos, max_len, p.cyclesToUs(w.start_tsc, mhz) / 1000);
        pos = appendStr(buf, pos, max_len, "\n");
    }
    return pos;
}

fn generateLoStats(buf: [*]u8, max_len: u32) u32 {
    const lo = @import("../net/lo.zig");
    return @intCast(lo.formatStats(lo.snapshot(), buf[0..max_len]));
}

fn generateVmaStats(buf: [*]u8, max_len: u32) u32 {
    const stats = @import("../mm/vma_runtime_stats.zig").snapshot();
    var pos: u32 = 0;
    pos = appendStr(buf, pos, max_len, "events=");
    pos = appendDec(buf, pos, max_len, stats.scans);
    pos = appendStr(buf, pos, max_len, " modeled_slots=");
    pos = appendDec(buf, pos, max_len, stats.slots);
    pos = appendStr(buf, pos, max_len, " avg_modeled_slots=");
    pos = appendDec(buf, pos, max_len, @import("../mm/vma_stats.zig").avgCost(stats.scans, stats.slots));
    pos = appendStr(buf, pos, max_len, " visited_slots=");
    pos = appendDec(buf, pos, max_len, stats.visited_slots);
    pos = appendStr(buf, pos, max_len, " avg_visited_slots=");
    pos = appendDec(buf, pos, max_len, @import("../mm/vma_stats.zig").avgCost(stats.scans, stats.visited_slots));
    return appendChar(buf, pos, max_len, '\n');
}

// ---------- helpers ----------

fn findTaskByPid(pid: u32) ?*const @import("../proc/task.zig").Task {
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
