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

    # Wait for child to exit via syscall #6: waitpid(-1, &status, 0)
    subq $8, %rsp
    movq $6, %rax
    movq $-1, %rdi
    movq %rsp, %rsi           # status_ptr on stack
    xorq %rdx, %rdx
    syscall

    # Write "child exited\n"
    movq $1, %rax
    movq $1, %rdi
    leaq wait_msg(%rip), %rsi
    movq $13, %rdx
    syscall

    # Spawn hello3 via syscall #5
    movq $5, %rax
    leaq hello3_name(%rip), %rdi
    syscall

    # Write "spawned hello3\n"
    movq $1, %rax
    movq $1, %rdi
    leaq spawn3_msg(%rip), %rsi
    movq $15, %rdx
    syscall

    # Wait for hello3
    movq $6, %rax
    movq $-1, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall

    # Write "hello3 done\n"
    movq $1, %rax
    movq $1, %rdi
    leaq done3_msg(%rip), %rsi
    movq $12, %rdx
    syscall

    # Spawn hello4 via syscall #5
    movq $5, %rax
    leaq hello4_name(%rip), %rdi
    syscall

    # Write "spawned hello4\n"
    movq $1, %rax
    movq $1, %rdi
    leaq spawn4_msg(%rip), %rsi
    movq $15, %rdx
    syscall

    # Wait for hello4
    movq $6, %rax
    movq $-1, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall

    # Write "hello4 done\n"
    movq $1, %rax
    movq $1, %rdi
    leaq done4_msg(%rip), %rsi
    movq $12, %rdx
    syscall

    # Spawn hello5 via syscall #5
    movq $5, %rax
    leaq hello5_name(%rip), %rdi
    syscall

    # Write "spawned hello5\n"
    movq $1, %rax
    movq $1, %rdi
    leaq spawn5_msg(%rip), %rsi
    movq $15, %rdx
    syscall

    # Wait for hello5
    movq $6, %rax
    movq $-1, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall

    # Write "hello5 done\n"
    movq $1, %rax
    movq $1, %rdi
    leaq done5_msg(%rip), %rsi
    movq $12, %rdx
    syscall

    # Spawn hello7 via syscall #5 (skip hello6 which blocks on keyboard)
    movq $5, %rax
    leaq hello7_name(%rip), %rdi
    syscall

    # Write "spawned hello7\n"
    movq $1, %rax
    movq $1, %rdi
    leaq spawn7_msg(%rip), %rsi
    movq $15, %rdx
    syscall

    # Wait for hello7
    movq $6, %rax
    movq $-1, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall

    # Write "hello7 done\n"
    movq $1, %rax
    movq $1, %rdi
    leaq done7_msg(%rip), %rsi
    movq $12, %rdx
    syscall

    # Spawn hello8 (pipe test)
    movq $5, %rax
    leaq hello8_name(%rip), %rdi
    syscall

    movq $1, %rax
    movq $1, %rdi
    leaq spawn8_msg(%rip), %rsi
    movq $15, %rdx
    syscall

    # Wait for hello8
    movq $6, %rax
    movq $-1, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall

    movq $1, %rax
    movq $1, %rdi
    leaq done8_msg(%rip), %rsi
    movq $12, %rdx
    syscall

    # Spawn hello9 (fork test)
    movq $5, %rax
    leaq hello9_name(%rip), %rdi
    syscall

    movq $1, %rax
    movq $1, %rdi
    leaq spawn9_msg(%rip), %rsi
    movq $15, %rdx
    syscall

    movq $6, %rax
    movq $-1, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall

    movq $1, %rax
    movq $1, %rdi
    leaq done9_msg(%rip), %rsi
    movq $12, %rdx
    syscall

    # Spawn shell (interactive, runs forever)
    movq $5, %rax
    leaq sh_name(%rip), %rdi
    syscall

    # If shell fails to spawn, just exit
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
wait_msg:
    .ascii "child exited\n"
hello3_name:
    .ascii "hello3"
    .byte 0
spawn3_msg:
    .ascii "spawned hello3\n"
done3_msg:
    .ascii "hello3 done\n"
hello4_name:
    .ascii "hello4"
    .byte 0
spawn4_msg:
    .ascii "spawned hello4\n"
done4_msg:
    .ascii "hello4 done\n"
hello5_name:
    .ascii "hello5"
    .byte 0
spawn5_msg:
    .ascii "spawned hello5\n"
done5_msg:
    .ascii "hello5 done\n"
hello6_name:
    .ascii "hello6"
    .byte 0
spawn6_msg:
    .ascii "spawned hello6\n"
done6_msg:
    .ascii "hello6 done\n"
hello7_name:
    .ascii "hello7"
    .byte 0
spawn7_msg:
    .ascii "spawned hello7\n"
done7_msg:
    .ascii "hello7 done\n"
hello8_name:
    .ascii "hello8"
    .byte 0
spawn8_msg:
    .ascii "spawned hello8\n"
done8_msg:
    .ascii "hello8 done\n"
hello9_name:
    .ascii "hello9"
    .byte 0
spawn9_msg:
    .ascii "spawned hello9\n"
done9_msg:
    .ascii "hello9 done\n"
sh_name:
    .ascii "sh"
    .byte 0
