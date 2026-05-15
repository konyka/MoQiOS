.section .text
.global _start

_start:
    # Get PID via syscall #4
    movq $4, %rax
    syscall
    # rax now contains our PID (tid)

    # Convert PID to decimal ASCII on stack
    # We'll build the number string backwards on the stack
    movq %rax, %rcx          # rcx = PID
    movq $10, %r8            # divisor
    xorq %r9, %r9            # digit count
    subq $32, %rsp           # reserve space for digit buffer

    test %rcx, %rcx
    jnz .convert_digits
    # PID is 0 — write "0"
    movb $'0', 0(%rsp)
    movq $1, %r9
    jmp .print_pid

.convert_digits:
    # Convert PID to decimal digits (reversed) on stack
    movq %rsp, %r10          # r10 = buffer base
    xorq %r9, %r9
.cvt_loop:
    xorq %rdx, %rdx
    movq %rcx, %rax
    divq %r8                 # rax = quotient, rdx = remainder
    addb $'0', %dl
    movb %dl, (%r10, %r9, 1)
    incq %r9
    movq %rax, %rcx
    test %rcx, %rcx
    jnz .cvt_loop

    # Reverse the digits in-place
    movq %r9, %rcx           # length
    test %rcx, %rcx
    jle .print_pid
    xorq %rsi, %rsi          # left = 0
    leaq -1(%r9), %rdi       # right = len-1
.rev_loop:
    cmpq %rdi, %rsi
    jge .print_pid
    movb (%rsp, %rsi), %al
    movb (%rsp, %rdi), %cl
    movb %cl, (%rsp, %rsi)
    movb %al, (%rsp, %rdi)
    incq %rsi
    decq %rdi
    jmp .rev_loop

.print_pid:
    # Write "init (pid " prefix
    movq $1, %rax
    movq $1, %rdi
    leaq prefix(%rip), %rsi
    movq $10, %rdx
    syscall

    # Write the PID digits
    movq $1, %rax
    movq $1, %rdi
    movq %rsp, %rsi
    movq %r9, %rdx
    syscall

    # Write ") started\n" suffix
    movq $1, %rax
    movq $1, %rdi
    leaq suffix(%rip), %rsi
    movq $10, %rdx
    syscall

    addq $32, %rsp           # clean up digit buffer

    # Write "Hello from init!\n"
    movq $1, %rax
    movq $1, %rdi
    leaq msg(%rip), %rsi
    movq $17, %rdx
    syscall

    # Spawn hello2 via syscall #5
    movq $5, %rax
    leaq hello2_name(%rip), %rdi
    syscall

    # Write "spawned hello2\n" regardless of spawn result
    movq $1, %rax
    movq $1, %rdi
    leaq spawn_msg(%rip), %rsi
    movq $15, %rdx
    syscall

    # Exit with code 0
    movq $2, %rax
    xorq %rdi, %rdi
    syscall

1:  pause
    jmp 1b

prefix:
    .ascii "init (pid "
suffix:
    .ascii ") started\n"
msg:
    .ascii "Hello from init!\n"
hello2_name:
    .ascii "hello2"
    .byte 0
spawn_msg:
    .ascii "spawned hello2\n"
