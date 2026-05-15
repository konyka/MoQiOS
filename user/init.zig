export fn _start() callconv(.c) noreturn {
    _ = syscall_write(1, msg_ptr, msg_len);
    syscall_exit(0);
}

const msg = "Hello from init!\n";
const msg_ptr: [*]const u8 = &msg;
const msg_len: u64 = msg.len;

noinline fn syscall_write(fd: u64, buf: [*]const u8, len: u64) u64 {
    _ = fd;
    _ = buf;
    _ = len;
    return asm volatile (
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq %[buf](%%rip), %%rsi
        \\movq %[len], %%rdx
        \\syscall
        : [ret] "={rax}" (-> u64),
        : [buf] "r" (@intFromPtr(buf)),
          [len] "r" (len),
    );
}

noinline fn syscall_exit(status: u64) noreturn {
    _ = status;
    asm volatile (
        \\movq $2, %%rax
        \\movq %[status], %%rdi
        \\syscall
        :
        : [status] "r" (status),
    );
    unreachable;
}
