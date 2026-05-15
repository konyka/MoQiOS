const pmm = @import("../mm/pmm.zig");
const slab = @import("../mm/slab.zig");
const task = @import("../proc/task.zig");
const sched = @import("../proc/sched.zig");
const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const paging = @import("../arch/x86_64/paging.zig");

pub fn dumpMemory() void {
    serial.writeString("\n=== Memory Diagnostics ===\n");

    serial.writeString("[PMM] Total: ");
    serial.writeString(fmtU64(pmm.getTotalPages()));
    serial.writeString(" pages, Free: ");
    serial.writeString(fmtU64(pmm.getFreePages()));
    serial.writeString(" pages (");
    serial.writeString(fmtU64(pmm.getFreePages() * 4096 / 1024));
    serial.writeString(" KB), Used: ");
    serial.writeString(fmtU64(pmm.getTotalPages() - pmm.getFreePages()));
    serial.writeString(" pages\n");

    const pct = if (pmm.getTotalPages() > 0) (pmm.getTotalPages() - pmm.getFreePages()) * 100 / pmm.getTotalPages() else 0;
    serial.writeString("[PMM] Utilization: ");
    serial.writeString(fmtU64(pct));
    serial.writeString("%\n");
}

pub fn dumpTasks() void {
    serial.writeString("\n=== Task Diagnostics ===\n");
    serial.writeString("[TASK] Count: ");
    serial.writeString(fmtU64(task.getTaskCount()));
    serial.writeString(" / ");
    serial.writeString(fmtU64(task.MAX_TASKS));
    serial.writeString("\n");

    serial.writeString("[SCHED] Current: ");
    if (sched.currentTaskIndex()) |idx| {
        serial.writeString(fmtU64(idx));
    } else {
        serial.writeString("none");
    }
    serial.writeString(", Tick: ");
    serial.writeString(fmtU64(idt.getTickCount()));
    serial.writeString("\n");

    serial.writeString("  TID  STATE     PRIO  TYPE       PT             KSTACK\n");
    for (0..task.MAX_TASKS) |i| {
        const t = task.getTask(@intCast(i)) orelse continue;
        serial.writeString("  ");
        serial.writeString(fmtU64(t.tid));
        serial.writeString("  ");
        serial.writeString(@tagName(t.state));
        padTo(10, @tagName(t.state).len);
        serial.writeString(fmtU64(t.priority));
        serial.writeString("  ");
        if (t.is_user) {
            serial.writeString("user     ");
        } else {
            serial.writeString("kernel   ");
        }
        serial.writeString("0x");
        serial.writeString(fmtHex(t.page_table_phys));
        serial.writeString("  ");
        serial.writeString("0x");
        serial.writeString(fmtHex(t.kernel_stack_top));
        serial.writeString("\n");
    }
}

pub fn dumpScheduler() void {
    serial.writeString("\n=== Scheduler Diagnostics ===\n");
    serial.writeString("[SCHED] Tick count: ");
    serial.writeString(fmtU64(idt.getTickCount()));
    serial.writeString("\n");

    var ready_count: u32 = 0;
    var running_count: u32 = 0;
    var blocked_count: u32 = 0;
    var zombie_count: u32 = 0;
    for (0..task.MAX_TASKS) |i| {
        const t = task.getTask(@intCast(i)) orelse continue;
        switch (t.state) {
            .ready => ready_count += 1,
            .running => running_count += 1,
            .blocked => blocked_count += 1,
            .zombie => zombie_count += 1,
        }
    }
    serial.writeString("  Ready: ");
    serial.writeString(fmtU64(ready_count));
    serial.writeString(", Running: ");
    serial.writeString(fmtU64(running_count));
    serial.writeString(", Blocked: ");
    serial.writeString(fmtU64(blocked_count));
    serial.writeString(", Zombie: ");
    serial.writeString(fmtU64(zombie_count));
    serial.writeString("\n");
}

pub fn dumpFull() void {
    dumpMemory();
    dumpTasks();
    dumpScheduler();
    serial.writeString("===========================\n\n");
}

fn padTo(target: usize, current: usize) void {
    var i: usize = current;
    while (i < target) : (i += 1) {
        serial.writeByte(' ');
    }
}

var fmt_buf: [4][20]u8 = [_][20]u8{[_]u8{0} ** 20} ** 4;
var fmt_buf_idx: usize = 0;

fn nextBuf() []u8 {
    const idx = fmt_buf_idx % fmt_buf.len;
    fmt_buf_idx += 1;
    return &fmt_buf[idx];
}

fn fmtU64(value: u64) []const u8 {
    const buf = nextBuf();
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}

fn fmtHex(value: u64) []const u8 {
    const buf = nextBuf();
    const hex = "0123456789abcdef";
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    return buf[0..16];
}
