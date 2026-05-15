/// User mode switch — jump from kernel ring0 to user ring3 via iretq.
///
/// The caller MUST set up the following BEFORE calling this function:
///   - TSS RSP0 via gdt.setRsp0(kernel_rsp0)
///   - PerCpu.kernel_rsp via syscall_entry.getPerCpu().kernel_rsp = kernel_rsp0
///   - User CR3 loaded
///   - User data segments (DS, ES, FS = 0x23)
///   - Interrupts disabled (cli)
///
/// This function only builds the iretq frame and jumps. All inputs are consumed
/// via pushq BEFORE any register clobbering (xor), so no input operand clobber
/// is possible.

const syscall_entry = @import("syscall_entry.zig");

/// Jump to user mode with the given entry point and stack pointer.
/// This function does not return — it transfers control to ring3.
pub fn jumpToUser(entry_point: u64, user_rsp: u64) callconv(.naked) void {
    _ = entry_point;
    _ = user_rsp;

    // Arguments: rdi = entry_point, rsi = user_rsp
    // We use these directly in pushq — consumed before any xor.
    // No "r" input operands that could clobber registers.
    asm volatile (
        \\// Push iretq frame. Arguments are in RDI (entry) and RSI (user_rsp).
        \\// These are consumed by pushq BEFORE any register clobbering.
        \\pushq $0x23            // SS (user data segment)
        \\pushq %%rsi            // RSP (user stack pointer)
        \\pushq $0x202           // RFLAGS: IF=1 + reserved bit 1
        \\pushq $0x1B            // CS (user code segment | RPL 3)
        \\pushq %%rdi            // RIP (entry point)
        \\
        \\// Clear general registers for clean user state
        \\xorq %%rax, %%rax
        \\xorq %%rbx, %%rbx
        \\xorq %%rcx, %%rcx
        \\xorq %%rdx, %%rdx
        \\xorq %%rsi, %%rsi
        \\xorq %%rdi, %%rdi
        \\xorq %%rbp, %%rbp
        \\xorq %%r8, %%r8
        \\xorq %%r9, %%r9
        \\xorq %%r10, %%r10
        \\xorq %%r11, %%r11
        \\xorq %%r12, %%r12
        \\xorq %%r13, %%r13
        \\xorq %%r14, %%r14
        \\xorq %%r15, %%r15
        \\
        \\iretq
    ::: .{ .memory = true });
}
