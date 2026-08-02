//! zig_crt — minimal Zig CRT for MoQiOS freestanding user programs (x86_64).
//!
//! Link this file into a Zig user program that exports
//!     export fn main() i32 { ... }
//! and it provides `_start`: align the stack, call main, exit via the
//! MoQiOS exit syscall (#2, rax=number, rdi=code — see
//! lib/moqi_libc/include/moqi_syscalls.h).
//!
//! This is a start stub only, not a libc: C users want lib/moqi_libc.

/// Provided by the user program being linked.
extern fn main() i32;

export fn _start() callconv(.naked) noreturn {
    // and: kernel enters with an arbitrary rsp alignment; align before the
    // call so main sees the SysV-mandated rsp%16==8 after the return address.
    // syscall #2 = exit, status in rdi.
    asm volatile (
        \\andq $-16, %rsp
        \\call main
        \\movl %eax, %edi
        \\movl $2, %eax
        \\syscall
        \\1: hlt
        \\jmp 1b
    );
}
