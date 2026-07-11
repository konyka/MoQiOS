//! Minimal preemptive kernel-thread scheduler for riscv64 M5.
//!
//! Two threads on private stacks; the supervisor timer interrupt switches
//! between them. This is intentionally local to the riscv64 skeleton — the
//! full `proc/sched.zig` path stays x86-only until a later milestone shares it
//! behind the arch facade.

const trap = @import("trap.zig");
const uart = @import("uart.zig");

const STACK_SIZE: usize = 16 * 1024;
const FRAME_SIZE: usize = trap.FRAME_BYTES;

const Task = struct {
    stack: [STACK_SIZE]u8 align(16) = undefined,
    /// Physical address of the saved TrapFrame (on this task's stack).
    frame_ptr: usize = 0,
    entries: u64 = 0,
    id: u8 = 0,
};

var tasks: [2]Task = .{ .{ .id = 0 }, .{ .id = 1 } };
var current: u8 = 0;
var enabled: bool = false;
var switches: u64 = 0;
var m5_done: bool = false;

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
    const frame_addr = (top - FRAME_SIZE) & ~@as(usize, 15);
    const frame: *trap.TrapFrame = @ptrFromInt(frame_addr);
    const bytes: [*]u8 = @ptrCast(frame);
    @memset(bytes[0..FRAME_SIZE], 0);

    frame.sepc = @intFromPtr(entry);
    // SPP=1 (S-mode), SPIE=1 (enable IE after sret).
    frame.sstatus = (1 << 8) | (1 << 5);
    frame.sp = frame_addr; // unused by sret path but keep consistent
    t.frame_ptr = frame_addr;
}

fn thread0() callconv(.c) noreturn {
    tasks[0].entries +%= 1;
    putStr("  [sched] thread0 start\n");
    while (!m5_done) {
        asm volatile ("wfi");
    }
    putStr("  [sched] thread0 exits (M5 done)\n");
    // Park; thread1 or timer path may already be shutting down.
    while (true) asm volatile ("wfi");
}

fn thread1() callconv(.c) noreturn {
    tasks[1].entries +%= 1;
    putStr("  [sched] thread1 start\n");
    while (!m5_done) {
        asm volatile ("wfi");
    }
    putStr("  [sched] thread1 exits (M5 done)\n");
    while (true) asm volatile ("wfi");
}

/// Prepare both threads. Does not enable interrupts or switch yet.
pub fn init() void {
    buildInitialFrame(&tasks[0], &thread0);
    buildInitialFrame(&tasks[1], &thread1);
    current = 0;
    switches = 0;
    m5_done = false;
    enabled = false;
}

/// Timer hook: save current frame, pick the other task, return its frame.
pub fn onTimer(frame: *trap.TrapFrame) *trap.TrapFrame {
    if (!enabled or m5_done) return frame;

    tasks[current].frame_ptr = @intFromPtr(frame);
    current ^= 1;
    switches +%= 1;

    // Enough cross-switches and both threads have entered at least once.
    if (switches >= 8 and tasks[0].entries >= 1 and tasks[1].entries >= 1) {
        m5_done = true;
        putStr("  [sched] preemptive switches=");
        putDec(switches);
        putStr(" t0_entries=");
        putDec(tasks[0].entries);
        putStr(" t1_entries=");
        putDec(tasks[1].entries);
        putStr("\n");
        putStr("[riscv64] M5 complete; shutting down\n");
        // SBI SRST shutdown
        asm volatile ("ecall"
            :
            : [eid] "{a7}" (@as(usize, 0x53525354)),
              [fid] "{a6}" (@as(usize, 0)),
              [a0] "{a0}" (@as(usize, 0)),
              [a1] "{a1}" (@as(usize, 0)),
            : .{ .memory = true });
        while (true) asm volatile ("wfi");
    }

    return @ptrFromInt(tasks[current].frame_ptr);
}

pub fn isDone() bool {
    return m5_done;
}

pub fn switchCount() u64 {
    return switches;
}

/// Enable scheduling and `sret` into thread0 (noreturn).
pub fn start() noreturn {
    enabled = true;
    const frame: *trap.TrapFrame = @ptrFromInt(tasks[0].frame_ptr);

    // Switch to thread0's stack frame and sret into it with IE enabled.
    asm volatile (
        \\mv sp, %[f]
        \\ld t0, 248(sp)
        \\csrw sepc, t0
        \\ld t0, 272(sp)
        \\csrw sstatus, t0
        \\ld ra,   0(sp)
        \\ld gp,  16(sp)
        \\ld tp,  24(sp)
        \\ld t0,  32(sp)
        \\ld t1,  40(sp)
        \\ld t2,  48(sp)
        \\ld s0,  56(sp)
        \\ld s1,  64(sp)
        \\ld a0,  72(sp)
        \\ld a1,  80(sp)
        \\ld a2,  88(sp)
        \\ld a3,  96(sp)
        \\ld a4, 104(sp)
        \\ld a5, 112(sp)
        \\ld a6, 120(sp)
        \\ld a7, 128(sp)
        \\ld s2, 136(sp)
        \\ld s3, 144(sp)
        \\ld s4, 152(sp)
        \\ld s5, 160(sp)
        \\ld s6, 168(sp)
        \\ld s7, 176(sp)
        \\ld s8, 184(sp)
        \\ld s9, 192(sp)
        \\ld s10,200(sp)
        \\ld s11,208(sp)
        \\ld t3, 216(sp)
        \\ld t4, 224(sp)
        \\ld t5, 232(sp)
        \\ld t6, 240(sp)
        \\addi sp, sp, 288
        \\sret
        :
        : [f] "r" (frame),
        : .{ .memory = true });
    while (true) asm volatile ("wfi");
}
