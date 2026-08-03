//! SK-45 — shared initial-user-stack builder (Linux ABI argc/argv/envp/auxv).
//!
//! The portable core of `loader.zig`'s buildUserStack: writes the ELF ABI
//! process-entry stack into a physical page (via hhdm.physToVirt — identity
//! on non-x86 where the HHDM offset is 0) and returns the user SP. The
//! layout (argc at SP, argv/envp pointer arrays, auxv pairs, 16-byte final
//! alignment) is identical across x86_64 / riscv64 / aarch64 Linux ABIs.

const hhdm = @import("../mm/hhdm.zig");

pub const PAGE_SIZE: u64 = 4096;

// Auxiliary vector types (Linux ABI)
pub const AT_NULL: u64 = 0;
pub const AT_PHDR: u64 = 3;
pub const AT_PHNUM: u64 = 5;
pub const AT_PAGESZ: u64 = 6;
pub const AT_BASE: u64 = 7; // base address of interpreter
pub const AT_FLAGS: u64 = 8;
pub const AT_ENTRY: u64 = 9;
pub const AT_UID: u64 = 11;
pub const AT_EUID: u64 = 12;
pub const AT_GID: u64 = 13;
pub const AT_EGID: u64 = 14;
pub const AT_HWCAP: u64 = 16;
pub const AT_CLKTCK: u64 = 17;
pub const AT_SECURE: u64 = 23;
pub const AT_RANDOM: u64 = 25; // address of 16 random bytes

/// Information needed to build the initial user stack.
pub const StackInfo = struct {
    /// ELF program header table virtual address (0 for flat binaries).
    phdr_addr: u64 = 0,
    /// Number of program headers (0 for flat binaries).
    phnum: u64 = 0,
    /// Entry point virtual address.
    entry: u64 = 0,
    /// Dynamic linker base address (0 if no interpreter).
    interp_base: u64 = 0,
};

/// Build the initial user stack with argc/argv/envp/auxv per the Linux ABI.
/// Writes directly to the physical stack page via HHDM (identity on
/// non-x86). Returns the new SP value for the user process.
///
/// Stack layout (high address to low, SP points at argc):
///   [string area: argv strings, env strings]  ← bottom of stack page
///   AT_NULL entry (16 bytes)
///   auxv entries (16 bytes each)
///   ... alignment pad (0 or 1 slot, keeps SP 16-byte aligned) ...
///   NULL (envp terminator, 8 bytes)
///   envp pointers (8 bytes each)
///   NULL (argv terminator, 8 bytes)
///   argv[0..argc-1] pointers (8 bytes each)
///   argc (8 bytes)                             ← SP
///
/// argv and envp are contiguous from SP: envp == &argv[argc + 1]. The
/// alignment pad (when needed) sits between the envp terminator and the
/// auxv, never between argv and envp, so user-space crt0 can parse both
/// arrays unconditionally.
pub fn buildUserStack(
    stack_phys: u64,
    stack_top: u64,
    argv: []const []const u8,
    envp: []const []const u8,
    info: StackInfo,
) u64 {
    // Access the stack page via HHDM
    const page_base: [*]u8 = @ptrFromInt(hhdm.physToVirt(stack_phys));
    const page_size: u64 = PAGE_SIZE;

    // Phase 1: Write string data at the bottom of the stack page.
    var str_offset: u64 = 0;
    var argv_offsets: [16]u64 = @splat(0);
    var envp_offsets: [16]u64 = @splat(0);

    for (argv, 0..) |arg, i| {
        if (i >= 16) break;
        argv_offsets[i] = str_offset;
        @memcpy(page_base[str_offset .. str_offset + arg.len], arg);
        str_offset += arg.len;
        page_base[str_offset] = 0;
        str_offset += 1;
    }
    const argc = @min(argv.len, @as(usize, 16));

    for (envp, 0..) |env, i| {
        if (i >= 16) break;
        envp_offsets[i] = str_offset;
        @memcpy(page_base[str_offset .. str_offset + env.len], env);
        str_offset += env.len;
        page_base[str_offset] = 0;
        str_offset += 1;
    }
    const nenv = @min(envp.len, @as(usize, 16));

    // Phase 2: Build the structure from the top of the page downward.
    // We'll compute offsets relative to the start of the page, then
    // convert to user-virtual addresses at the end.
    var pos: u64 = page_size;

    // Helper: push a u64 value (decrement pos by 8, write value)
    const push64 = struct {
        fn f(p: *u64, base: [*]u8, val: u64) void {
            p.* -= 8;
            @atomicStore(u64, @as(*u64, @ptrFromInt(@intFromPtr(base + p.*))), val, .monotonic);
        }
    }.f;

    // AT_NULL entry (auxv terminator)
    push64(&pos, page_base, 0); // a_val = 0
    push64(&pos, page_base, AT_NULL); // a_type = AT_NULL

    // auxv entries (pushed in reverse order)
    // AT_EGID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_EGID);
    // AT_GID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_GID);
    // AT_EUID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_EUID);
    // AT_UID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_UID);
    // AT_SECURE
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_SECURE);
    // AT_HWCAP (basic: FPU + SSE)
    push64(&pos, page_base, 0x1 | 0x200);
    push64(&pos, page_base, AT_HWCAP);
    // AT_CLKTCK
    push64(&pos, page_base, 100);
    push64(&pos, page_base, AT_CLKTCK);
    // AT_FLAGS
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_FLAGS);
    // AT_BASE (dynamic linker base, 0 = no interpreter loaded)
    push64(&pos, page_base, info.interp_base);
    push64(&pos, page_base, AT_BASE);
    // AT_ENTRY
    push64(&pos, page_base, info.entry);
    push64(&pos, page_base, AT_ENTRY);
    // AT_PAGESZ
    push64(&pos, page_base, page_size);
    push64(&pos, page_base, AT_PAGESZ);
    // AT_PHNUM
    if (info.phnum > 0) {
        push64(&pos, page_base, info.phnum);
        push64(&pos, page_base, AT_PHNUM);
    }
    // AT_PHDR
    if (info.phdr_addr != 0) {
        push64(&pos, page_base, info.phdr_addr);
        push64(&pos, page_base, AT_PHDR);
    }

    // Pad to ensure 16-byte alignment of final SP. The pad sits between
    // the envp terminator and the auxv so argc/argv/envp stay contiguous
    // from SP upwards.
    {
        const remaining_pushes: u64 = argc + 2 + nenv + 1;
        const final_pos = pos - remaining_pushes * 8;
        if (final_pos % 16 != 0) {
            push64(&pos, page_base, 0);
        }
    }

    // envp terminator
    push64(&pos, page_base, 0);

    // envp pointers (in reverse order)
    var ei: usize = nenv;
    while (ei > 0) {
        ei -= 1;
        const env_user_addr: u64 = stack_top - page_size + envp_offsets[ei];
        push64(&pos, page_base, env_user_addr);
    }

    // argv terminator
    push64(&pos, page_base, 0);

    // argv pointers (in reverse order)
    var ai: usize = argc;
    while (ai > 0) {
        ai -= 1;
        const arg_user_addr: u64 = stack_top - page_size + argv_offsets[ai];
        push64(&pos, page_base, arg_user_addr);
    }

    // argc
    push64(&pos, page_base, argc);

    const user_sp: u64 = stack_top - page_size + pos;
    return user_sp;
}
