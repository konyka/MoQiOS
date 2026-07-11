//! Minimal preemptive kernel-thread scheduler for aarch64 M9-7.
//!
//! Two EL1 threads on private stacks; CNTV PPI IRQs switch between them.
//! Local to the aarch64 skeleton — full `proc/sched.zig` stays x86-only until
//! shared-kernel reuse.

const uart = @import("uart.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");

pub const FRAME_BYTES: usize = 192;

/// Must match `irq_el1h_entry` layout in vectors.S.
pub const TrapFrame = extern struct {
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x29: u64,
    x30: u64,
    _pad: u64 = 0,
    elr: u64,
    spsr: u64,
};

comptime {
    if (@sizeOf(TrapFrame) != FRAME_BYTES) @compileError("TrapFrame size mismatch");
}

const STACK_SIZE: usize = 16 * 1024;

const Task = struct {
    stack: [STACK_SIZE]u8 align(16) = undefined,
    frame_ptr: usize = 0,
    entries: u64 = 0,
    id: u8 = 0,
};

var tasks: [2]Task = .{ .{ .id = 0 }, .{ .id = 1 } };
var current: u8 = 0;
var enabled: bool = false;
var switches: u64 = 0;
var m97_done: bool = false;

fn putStr(s: []const u8) void {
    uart.writeString(s);
}

fn putDec(v: u64) void {
    if (v == 0) {
        uart.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (n += 1) {
        buf[n] = @intCast('0' + (x % 10));
        x /= 10;
    }
    while (n > 0) {
        n -= 1;
        uart.writeByte(buf[n]);
    }
}

fn buildInitialFrame(t: *Task, entry: *const fn () callconv(.c) noreturn) void {
    const top = @intFromPtr(&t.stack) + STACK_SIZE;
    const frame_addr = (top - FRAME_BYTES) & ~@as(usize, 15);
    const frame: *TrapFrame = @ptrFromInt(frame_addr);
    const bytes: [*]u8 = @ptrCast(frame);
    @memset(bytes[0..FRAME_BYTES], 0);

    frame.elr = @intFromPtr(entry);
    // EL1h (M=0b0101), DAIF clear → IRQ enabled after eret.
    frame.spsr = 0x5;
    t.frame_ptr = frame_addr;
}

fn thread0() callconv(.c) noreturn {
    tasks[0].entries +%= 1;
    putStr("  [sched] thread0 start\n");
    while (!m97_done) {
        asm volatile ("wfi");
    }
    putStr("  [sched] thread0 exits (M9-7 done)\n");
    while (true) asm volatile ("wfi");
}

fn thread1() callconv(.c) noreturn {
    tasks[1].entries +%= 1;
    putStr("  [sched] thread1 start\n");
    while (!m97_done) {
        asm volatile ("wfi");
    }
    putStr("  [sched] thread1 exits (M9-7 done)\n");
    while (true) asm volatile ("wfi");
}

pub fn init() void {
    buildInitialFrame(&tasks[0], &thread0);
    buildInitialFrame(&tasks[1], &thread1);
    current = 0;
    switches = 0;
    m97_done = false;
    enabled = false;
}

/// Timer IRQ hook: save current frame, pick the other task, return its frame.
pub fn onTimer(frame: *TrapFrame) *TrapFrame {
    if (!enabled or m97_done) return frame;

    tasks[current].frame_ptr = @intFromPtr(frame);
    current ^= 1;
    switches +%= 1;

    if (switches >= 8 and tasks[0].entries >= 1 and tasks[1].entries >= 1) {
        m97_done = true;
        putStr("  [sched] preemptive switches=");
        putDec(switches);
        putStr(" t0_entries=");
        putDec(tasks[0].entries);
        putStr(" t1_entries=");
        putDec(tasks[1].entries);
        putStr("\n");
        putStr("[aarch64] M9-7 complete\n");
        gic.disableCpuIrq();
        while (true) asm volatile ("wfi");
    }

    return @ptrFromInt(tasks[current].frame_ptr);
}

pub fn isEnabled() bool {
    return enabled;
}

/// Enable scheduling and `eret` into thread0 (noreturn).
pub fn start() noreturn {
    putStr("MoQiOS aarch64: M9-7 (timer + sched)\n");
    enabled = true;
    timer.init(0);
    gic.enableCpuIrq();

    const frame: *TrapFrame = @ptrFromInt(tasks[0].frame_ptr);
    asm volatile (
        \\mov sp, %[f]
        \\ldp x1, x2, [sp, #176]
        \\msr elr_el1, x1
        \\msr spsr_el1, x2
        \\ldr x30, [sp, #160]
        \\ldp x18, x29, [sp, #144]
        \\ldp x16, x17, [sp, #128]
        \\ldp x14, x15, [sp, #112]
        \\ldp x12, x13, [sp, #96]
        \\ldp x10, x11, [sp, #80]
        \\ldp x8, x9, [sp, #64]
        \\ldp x6, x7, [sp, #48]
        \\ldp x4, x5, [sp, #32]
        \\ldp x2, x3, [sp, #16]
        \\ldp x0, x1, [sp, #0]
        \\add sp, sp, #192
        \\isb
        \\eret
        :
        : [f] "r" (frame),
        : .{ .memory = true });
    while (true) asm volatile ("wfi");
}
