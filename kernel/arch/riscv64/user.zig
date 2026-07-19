//! U-mode entry + ecall syscalls for the riscv64 skeleton (Milestone 6).

const pmm = @import("pmm.zig");
const sv39 = @import("sv39.zig");
const trap = @import("trap.zig");
const uart = @import("uart.zig");
const copy = @import("../../mm/copy_from_user.zig");

pub const SYS_EXIT: u64 = 0;
pub const SYS_WRITE: u64 = 1;

const USER_TEXT_VA: usize = 0x00010000;
const USER_STACK_VA: usize = 0x00020000;
const USER_STACK_TOP: usize = USER_STACK_VA + sv39.PAGE_SIZE;
const MSG_OFF: usize = 0x40;

var user_text_pa: usize = 0;
var user_stack_pa: usize = 0;
var ran_ok: bool = false;

fn putStr(s: []const u8) void {
    uart.writeString(s);
}

fn writeU32(page: [*]u8, off: usize, word: u32) void {
    page[off] = @truncate(word);
    page[off + 1] = @truncate(word >> 8);
    page[off + 2] = @truncate(word >> 16);
    page[off + 3] = @truncate(word >> 24);
}

fn buildUserImage(page: [*]u8) void {
    @memset(page[0..sv39.PAGE_SIZE], 0);
    const msg = "hello from U\n";
    @memcpy(page[MSG_OFF..][0..msg.len], msg);
    writeU32(page, 0x00, 0x00100893); // li a7, 1
    writeU32(page, 0x04, 0x00100513); // li a0, 1
    writeU32(page, 0x08, 0x000105b7); // lui a1, 0x10
    writeU32(page, 0x0c, 0x04058593); // addi a1, a1, 0x40
    writeU32(page, 0x10, 0x00d00613); // li a2, 13
    writeU32(page, 0x14, 0x00000073); // ecall
    writeU32(page, 0x18, 0x00000893); // li a7, 0
    writeU32(page, 0x1c, 0x00000513); // li a0, 0
    writeU32(page, 0x20, 0x00000073); // ecall
}

/// SK-41: sys_write reads user memory through the shared copy_from_user
/// guard (range check + Sv39 user-bit walk + sstatus.SUM bracket) instead of
/// hand-rolled bounds + phys aliasing.
fn handleWrite(frame: *trap.TrapFrame) void {
    const len = frame.a2;
    var buf: [256]u8 = undefined;
    if (len > buf.len) {
        frame.a0 = @bitCast(@as(i64, -1));
        return;
    }
    const n = copy.copyFromUser(buf[0..], @ptrFromInt(frame.a1), @intCast(len));
    if (n != len) {
        frame.a0 = @bitCast(@as(i64, -1));
        return;
    }
    for (buf[0..@intCast(n)]) |b| {
        uart.writeByte(b);
    }
    if (!wrote_via_shared) {
        wrote_via_shared = true;
        uart.writeString("[SK-41] user write via shared copy: OK\n");
    }
    frame.a0 = len;
}

var wrote_via_shared: bool = false;

pub fn handleEcall(frame: *trap.TrapFrame) bool {
    frame.sepc += 4;
    switch (frame.a7) {
        SYS_WRITE => {
            handleWrite(frame);
            return true;
        },
        SYS_EXIT => {
            ran_ok = true;
            putStr("  user sys_exit: OK\n");
            putStr("[riscv64] M6 complete\n");
            asm volatile ("csrw sscratch, zero");
            return false;
        },
        else => {
            putStr("  unknown syscall\n");
            frame.a0 = @bitCast(@as(i64, -1));
            return true;
        },
    }
}

pub fn enter() noreturn {
    putStr("MoQiOS riscv64: M6 (U-mode + ecall)\n");

    user_text_pa = pmm.allocPage() orelse {
        putStr("  M6 FAILED: text page\n");
        while (true) asm volatile ("wfi");
    };
    user_stack_pa = pmm.allocPage() orelse {
        putStr("  M6 FAILED: stack page\n");
        while (true) asm volatile ("wfi");
    };
    buildUserImage(@ptrFromInt(user_text_pa));

    if (!sv39.mapPage(USER_TEXT_VA, user_text_pa, .{ .read = true, .write = false, .exec = true, .user = true }) or
        !sv39.mapPage(USER_STACK_VA, user_stack_pa, .{ .read = true, .write = true, .exec = false, .user = true }))
    {
        putStr("  M6 FAILED: map user pages\n");
        while (true) asm volatile ("wfi");
    }
    asm volatile ("sfence.vma" ::: .{ .memory = true });
    putStr("  user text/stack mapped (U bit)\n");

    const ksp = trap.userTrapStackTop();
    if (ksp == 0) {
        putStr("  M6 FAILED: trap stack top unset\n");
        while (true) asm volatile ("wfi");
    }

    const frame_addr = (ksp - trap.FRAME_BYTES) & ~@as(usize, 15);
    const frame: *trap.TrapFrame = @ptrFromInt(frame_addr);
    @memset(@as([*]u8, @ptrCast(frame))[0..trap.FRAME_BYTES], 0);
    frame.sepc = USER_TEXT_VA;
    frame.sp = USER_STACK_TOP;
    frame.sstatus = 1 << 5; // SPIE; SPP=0

    asm volatile ("csrw sscratch, %[s]"
        :
        : [s] "r" (ksp),
        : .{ .memory = true });

    putStr("  sret -> U-mode\n");
    asm volatile (
        \\mv sp, %[f]
        \\ld t0, 248(sp)
        \\csrw sepc, t0
        \\ld t0, 272(sp)
        \\csrw sstatus, t0
        \\ld t0, 8(sp)
        \\csrw sscratch, %[ks]
        \\mv sp, t0
        \\sret
        :
        : [f] "r" (frame),
          [ks] "r" (ksp),
        : .{ .memory = true });
    while (true) asm volatile ("wfi");
}
