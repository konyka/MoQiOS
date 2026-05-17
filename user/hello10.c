#include <stdint.h>

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(1, 1, (long)s, len);
}

static void print_num(long n) {
    if (n < 0) { print("-"); n = -n; }
    if (n == 0) { print("0"); return; }
    char buf[20];
    int i = 0;
    while (n > 0) { buf[i++] = '0' + (n % 10); n /= 10; }
    char out[20];
    for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
    out[i] = '\0';
    print(out);
}

void _start(void) {
    print("hello10: fork test\n");

    long pid = syscall1(57, 0);
    if (pid < 0) {
        print("hello10: fork failed\n");
        syscall1(2, 1);
    }

    if (pid == 0) {
        print("hello10: I am child\n");
        syscall1(2, 0);
    }

    print("hello10: parent, child=");
    print_num(pid);
    print("\n");

    int status;
    syscall3(6, -1, (long)&status, 0);
    print("hello10 done\n");
    syscall1(2, 0);
}
