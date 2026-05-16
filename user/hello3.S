/// hello3.S — Test program that opens and reads a file from ramdisk.
/// Syscalls: write(1), exit(2), open(9), read(10), close(11)

.section .text
.globl _start
_start:
    # ---- Print "hello3: opening hello2\n" ----
    mov $1, %rdi            # fd = stdout
    leaq msg_open(%rip), %rsi
    mov $23, %rdx
    mov $1, %rax            # SYS_WRITE
    syscall

    # ---- open("hello2", 0, 0) ----
    leaq filename(%rip), %rdi
    xor %rsi, %rsi          # flags = O_RDONLY
    xor %rdx, %rdx          # mode = 0
    mov $9, %rax            # SYS_OPEN
    syscall

    # Save fd
    mov %rax, %r12

    # ---- Print "hello3: got fd=X\n" ----
    mov $1, %rdi
    leaq msg_fd(%rip), %rsi
    mov $14, %rdx
    mov $1, %rax
    syscall

    # Print fd digit (assume fd < 10)
    mov %r12, %rax
    add $'0', %rax
    movb %al, fd_char(%rip)
    mov $1, %rdi
    leaq fd_str(%rip), %rsi
    mov $1, %rdx
    mov $1, %rax
    syscall

    # newline
    mov $1, %rdi
    leaq nl(%rip), %rsi
    mov $1, %rdx
    mov $1, %rax
    syscall

    # ---- read(fd, buf, 64) ----
    mov %r12, %rdi           # fd
    leaq buf(%rip), %rsi     # buffer
    mov $64, %rdx            # count
    mov $10, %rax            # SYS_READ
    syscall

    # Save bytes read
    mov %rax, %r13

    # ---- Print "hello3: read bytes:\n" ----
    mov $1, %rdi
    leaq msg_read(%rip), %rsi
    mov $19, %rdx
    mov $1, %rax
    syscall

    # ---- Print the content read from file ----
    mov $1, %rdi
    leaq buf(%rip), %rsi
    mov %r13, %rdx
    mov $1, %rax
    syscall

    # ---- close(fd) ----
    mov %r12, %rdi
    mov $11, %rax           # SYS_CLOSE
    syscall

    # ---- Print "hello3: done!\n" ----
    mov $1, %rdi
    leaq msg_done(%rip), %rsi
    mov $14, %rdx
    mov $1, %rax
    syscall

    # ---- exit(0) ----
    xor %rdi, %rdi
    mov $2, %rax
    syscall

    # Halt loop (should never reach here)
1:  pause
    jmp 1b

.section .data
msg_open:   .ascii "hello3: opening hello2\n"
msg_fd:     .ascii "hello3: got fd="
fd_str:     .byte '0'
fd_char     = fd_str
nl:         .ascii "\n"
msg_read:   .ascii "hello3: read bytes:\n"
msg_done:   .ascii "hello3: done!\n"
filename:   .asciz "hello2"

.section .bss
buf:        .skip 256

