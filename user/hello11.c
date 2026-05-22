#include <stdint.h>

void _start(void) {
    __asm__ volatile (
        "movq $2, %%rax\n"
        "movq $42, %%rdi\n"
        "syscall\n"
        ::: "rax", "rdi", "rcx", "r11", "memory"
    );
}
