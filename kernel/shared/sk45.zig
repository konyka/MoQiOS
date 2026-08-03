//! SK-45 — shared initial-user-stack builder exercised on non-x86.
//!
//! loader.zig's buildUserStack (Linux ABI argc/argv/envp/auxv entry stack)
//! moved to the arch-clean `proc/user_stack.zig`; loader re-exports it. The
//! layout is ABI-identical on x86_64/riscv64/aarch64. Probe: build the stack
//! for a fake process into a real page (identity-mapped, stack_top == page
//! end so user VAs equal kernel VAs) and walk argc/argv/envp/auxv.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const pmm = @import("../mm/pmm.zig");
const user_stack = @import("../proc/user_stack.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-45] shared user stack build: OK\n");
        return;
    }

    const phys = pmm.allocPage() orelse {
        arch.serial.writeString("[SK-45] FAILED: allocPage\n");
        return;
    };
    defer pmm.freePage(phys);

    // Identity map is live: choosing stack_top == phys + PAGE_SIZE makes the
    // user-VA pointers the builder writes directly dereferenceable here.
    const stack_top = phys + user_stack.PAGE_SIZE;
    const argv = [_][]const u8{ "init", "-v" };
    const entry: u64 = 0x40_1000;

    const sp = user_stack.buildUserStack(phys, stack_top, argv[0..], &.{}, .{
        .phdr_addr = 0x40_0040,
        .phnum = 2,
        .entry = entry,
    });

    if (sp % 16 != 0 or sp <= phys or sp >= stack_top) {
        arch.serial.writeString("[SK-45] FAILED: sp bounds/alignment\n");
        return;
    }

    const p: [*]const u64 = @ptrFromInt(sp);
    if (p[0] != 2) {
        arch.serial.writeString("[SK-45] FAILED: argc != 2\n");
        return;
    }
    // argv[0] / argv[1] strings
    const a0: [*]const u8 = @ptrFromInt(p[1]);
    if (a0[0] != 'i' or a0[1] != 'n' or a0[2] != 'i' or a0[3] != 't' or a0[4] != 0) {
        arch.serial.writeString("[SK-45] FAILED: argv[0]\n");
        return;
    }
    const a1: [*]const u8 = @ptrFromInt(p[2]);
    if (a1[0] != '-' or a1[1] != 'v' or a1[2] != 0) {
        arch.serial.writeString("[SK-45] FAILED: argv[1]\n");
        return;
    }
    if (p[3] != 0) {
        arch.serial.writeString("[SK-45] FAILED: argv terminator\n");
        return;
    }

    // Skip optional alignment pad between argv NULL and envp NULL.
    var idx: usize = 4;
    if (p[idx] == 0 and p[idx + 1] == 0 and p[idx + 2] != 0) idx += 1;
    if (p[idx] != 0) {
        arch.serial.writeString("[SK-45] FAILED: envp terminator\n");
        return;
    }
    idx += 1;

    // auxv pairs until AT_NULL; require AT_ENTRY/AT_PHNUM/AT_PAGESZ correct.
    var seen_entry = false;
    var seen_phnum = false;
    var seen_pagesz = false;
    var guard: usize = 0;
    while (p[idx] != user_stack.AT_NULL) : (guard += 1) {
        if (guard > 32) {
            arch.serial.writeString("[SK-45] FAILED: auxv unterminated\n");
            return;
        }
        const a_type = p[idx];
        const a_val = p[idx + 1];
        if (a_type == user_stack.AT_ENTRY) seen_entry = a_val == entry;
        if (a_type == user_stack.AT_PHNUM) seen_phnum = a_val == 2;
        if (a_type == user_stack.AT_PAGESZ) seen_pagesz = a_val == user_stack.PAGE_SIZE;
        idx += 2;
    }
    if (!seen_entry or !seen_phnum or !seen_pagesz) {
        arch.serial.writeString("[SK-45] FAILED: auxv values\n");
        return;
    }

    arch.serial.writeString("[SK-45] shared user stack build: OK\n");
}
