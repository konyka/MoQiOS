// hello6.c — Reads from stdin (keyboard) and echoes to stdout

#include <stdint.h>

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

__attribute__((naked)) void _start(void) {
    __asm__ volatile(
        "xor %%ebp, %%ebp\n"
        "mov (%%rsp), %%rdi\n"
        "lea 8(%%rsp), %%rsi\n"
        "call main_body\n"
        "mov %%eax, %%edi\n"
        "mov $2, %%eax\n"
        "syscall\n"
        ::: "memory"
    );
}

static void puts(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(1, 1, (long)s, len);
}

int main_body(int argc, char **argv) {
    (void)argc;
    (void)argv;
    puts("hello6: type something (enter to finish)\n");

    char buf[64];
    while (1) {
        long n = syscall3(10, 0, (long)buf, sizeof(buf));
        if (n <= 0) {
            for (volatile int i = 0; i < 100000; i++) {}
            continue;
        }
        syscall3(1, 1, (long)"echo: ", 6);
        syscall3(1, 1, (long)buf, n);
        syscall3(1, 1, (long)"\n", 1);
        for (long i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                puts("hello6 done\n");
                syscall1(2, 0);
            }
        }
    }
    return 0;
}
