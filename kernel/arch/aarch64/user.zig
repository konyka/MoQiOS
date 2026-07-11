//! EL0 entry + SVC syscalls for the aarch64 skeleton (Milestone 9-6).

const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const uart = @import("uart.zig");

pub const SYS_EXIT: u64 = 0;
pub const SYS_WRITE: u64 = 1;

const USER_TEXT_VA: usize = 0x00010000;
const USER_STACK_VA: usize = 0x00020000;
const USER_STACK_TOP: usize = USER_STACK_VA + paging.PAGE_SIZE;
const MSG_OFF: usize = 0x40;

/// Saved register frame laid out by `sync_el0_entry` (must match vectors.S).
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
};

var user_text_pa: usize = 0;

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
    var i: usize = 0;
    while (i < paging.PAGE_SIZE) : (i += 1) page[i] = 0;
    const msg = "hello from U\n";
    var j: usize = 0;
    while (j < msg.len) : (j += 1) page[MSG_OFF + j] = msg[j];

    writeU32(page, 0x00, 0xD2800028); // movz x8, #1  SYS_WRITE
    writeU32(page, 0x04, 0xD2800020); // movz x0, #1  fd
    writeU32(page, 0x08, 0xD2800801); // movz x1, #0x40
    writeU32(page, 0x0c, 0xF2A00021); // movk x1, #1, lsl #16 => 0x10040
    writeU32(page, 0x10, 0xD28001A2); // movz x2, #13
    writeU32(page, 0x14, 0xD4000001); // svc #0
    writeU32(page, 0x18, 0xD2800008); // movz x8, #0  SYS_EXIT
    writeU32(page, 0x1c, 0xD2800000); // movz x0, #0
    writeU32(page, 0x20, 0xD4000001); // svc #0
}

fn handleWrite(frame: *TrapFrame) void {
    const ptr = frame.x1;
    const len = frame.x2;
    if (ptr < USER_TEXT_VA or ptr + len > USER_TEXT_VA + paging.PAGE_SIZE or len > 256) {
        frame.x0 = @bitCast(@as(i64, -1));
        return;
    }
    const phys = user_text_pa + (ptr - USER_TEXT_VA);
    const bytes: [*]const u8 = @ptrFromInt(phys);
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        uart.writeByte(bytes[@intCast(i)]);
    }
    frame.x0 = len;
}

/// Returns 0 → eret to EL0. SYS_EXIT continues into M9-7 sched (noreturn).
pub fn handleSvc(frame: *TrapFrame) u64 {
    // AArch64 SVC already sets ELR to the following instruction — do not +4.
    switch (frame.x8) {
        SYS_WRITE => {
            handleWrite(frame);
            return 0;
        },
        SYS_EXIT => {
            putStr("  user sys_exit: OK\n");
            putStr("[aarch64] M9-6 complete\n");
            // Continue into M9-7 preemptive sched (noreturn).
            const sched = @import("sched.zig");
            sched.init();
            sched.start();
        },
        else => {
            putStr("  unknown syscall\n");
            frame.x0 = @bitCast(@as(i64, -1));
            return 0;
        },
    }
}

pub fn enter() void {
    putStr("MoQiOS aarch64: M9-6 (EL0 + SVC)\n");

    user_text_pa = pmm.allocPage();
    if (user_text_pa == 0) {
        putStr("  M9-6 FAILED: text page\n");
        return;
    }
    const user_stack_pa = pmm.allocPage();
    if (user_stack_pa == 0) {
        putStr("  M9-6 FAILED: stack page\n");
        return;
    }
    buildUserImage(@ptrFromInt(user_text_pa));

    if (!paging.mapPage(USER_TEXT_VA, user_text_pa, paging.F_EXEC | paging.F_USER) or
        !paging.mapPage(USER_STACK_VA, user_stack_pa, paging.F_WRITE | paging.F_USER))
    {
        putStr("  M9-6 FAILED: map user pages\n");
        return;
    }
    putStr("  user text/stack mapped (EL0)\n");

    asm volatile ("msr sp_el0, %[s]"
        :
        : [s] "r" (USER_STACK_TOP),
    );
    asm volatile ("msr elr_el1, %[p]"
        :
        : [p] "r" (USER_TEXT_VA),
    );
    // EL0t + DAIF masked so timer IRQs cannot preempt the tiny user prog.
    const spsr: u64 = 0x3c0;
    asm volatile ("msr spsr_el1, %[s]"
        :
        : [s] "r" (spsr),
    );
    asm volatile ("isb");

    @import("gic.zig").disableCpuIrq();
    putStr("  eret -> EL0\n");
    asm volatile ("eret");
    // Not reached: SYS_EXIT halts in the SVC handler.
}
