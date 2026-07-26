//! Bulk copies to and from user memory that survive a fault mid-copy.
//!
//! `copy_from_user.zig` walks the page tables before every copy to prove the
//! range is present, then does the copy. Nothing keeps the mapping still in
//! between: a second thread in the same address space can `munmap` the range in
//! that gap, and a plain `@memcpy` then faults in kernel mode with nowhere to
//! go, taking the machine down. `user/hello36.c` does exactly that.
//!
//! The copy is therefore a single `rep movsb` at a known address. When the page
//! fault handler sees a supervisor fault whose RIP is that instruction, it
//! moves RIP to a fixup that returns the byte count actually transferred —
//! `rep movsb` leaves the untransferred remainder in RCX, and the interrupt
//! frame restores RCX on the way out, so the count survives the fault.
//!
//! Keeping the page-table pre-check as well is deliberate. Callers that dequeue
//! irreversible data (pipes, sockets) decide *whether to consume* based on it;
//! this recovery is the backstop for the window the check cannot cover, not a
//! replacement for it.

comptime {
    asm (
        \\.section .text
        \\.global moqi_user_copy
        \\.global moqi_user_copy_insn
        \\.global moqi_user_copy_fixup
        \\.type moqi_user_copy, @function
        \\
        \\// usize moqi_user_copy(dst: rdi, src: rsi, len: rdx) -> rax
        \\moqi_user_copy:
        \\    cld
        \\    movq %rdx, %rcx
        \\moqi_user_copy_insn:
        \\    rep movsb
        \\    movq %rdx, %rax
        \\    ret
        \\moqi_user_copy_fixup:
        \\    // RCX = bytes rep movsb had left when it faulted.
        \\    movq %rdx, %rax
        \\    subq %rcx, %rax
        \\    ret
        \\.size moqi_user_copy, . - moqi_user_copy
    );
}

extern fn moqi_user_copy(dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) usize;
extern const moqi_user_copy_insn: u8;
extern const moqi_user_copy_fixup: u8;

/// Copy `len` bytes, returning how many made it across. A short return means
/// the mapping went away mid-copy; the caller decides what that means.
pub fn copyBytes(dst: [*]u8, src: [*]const u8, len: usize) usize {
    return moqi_user_copy(dst, src, len);
}

/// Fixup address for a supervisor fault taken inside the copy, or null when the
/// fault came from anywhere else and must stay fatal.
pub fn faultFixup(rip: u64) ?u64 {
    if (rip != @intFromPtr(&moqi_user_copy_insn)) return null;
    return @intFromPtr(&moqi_user_copy_fixup);
}
