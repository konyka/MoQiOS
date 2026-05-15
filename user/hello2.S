.section .text
.global _start

_start:
    # Write "Hello from hello2!\n"
    movq $1, %rax
    movq $1, %rdi
    leaq msg(%rip), %rsi
    movq $19, %rdx
    syscall

    # Exit with code 42
    movq $2, %rax
    movq $42, %rdi
    syscall

1:  pause
    jmp 1b

msg:
    .ascii "Hello from hello2!\n"
